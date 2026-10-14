"""Data channel layout, envelope codec, chunking and backpressure (webrtc.md 6.2)."""

from __future__ import annotations

import asyncio
import base64
import binascii
import json
import secrets
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any, Protocol

from . import PROTOCOL_VERSION

# Negotiated channels with fixed ids so both sides agree without in-band setup.
CHANNEL_IDS: dict[str, int] = {"control": 0, "rpc": 1, "sync": 2, "events": 3}
CHANNEL_NAMES = tuple(CHANNEL_IDS)

MAX_MESSAGE_BYTES = 16 * 1024  # interoperable data channel message size
CHUNK_BYTES = 11_000  # raw bytes per chunk; base64 + envelope stays < 16 KiB
MAX_REASSEMBLED_BYTES = 8 * 1024 * 1024
MAX_CONCURRENT_STREAMS = 16
REASSEMBLY_TIMEOUT_SECONDS = 30.0
BUFFER_HIGH_WATER = 1024 * 1024
BUFFER_LOW_WATER = 256 * 1024
SEND_STALL_TIMEOUT_SECONDS = 30.0


class ChannelError(Exception):
    """A malformed, oversized or otherwise unacceptable channel message."""


@dataclass(frozen=True, slots=True)
class Envelope:
    type: str
    data: Any = None
    id: str | None = None
    src: str | None = None
    dst: str | None = None

    def to_wire(self) -> dict[str, Any]:
        wire: dict[str, Any] = {"v": PROTOCOL_VERSION, "type": self.type}
        if self.id is not None:
            wire["id"] = self.id
        wire["data"] = self.data
        if self.src is not None:
            wire["src"] = self.src
        if self.dst is not None:
            wire["dst"] = self.dst
        return wire

    @classmethod
    def from_wire(cls, value: Any) -> "Envelope":
        if not isinstance(value, dict):
            raise ChannelError("Envelope must be an object.")
        if value.get("v") != PROTOCOL_VERSION:
            raise ChannelError("Unsupported envelope version.")
        frame_type = value.get("type")
        if not isinstance(frame_type, str) or not frame_type:
            raise ChannelError("Envelope type is missing.")
        identifier = value.get("id")
        src, dst = value.get("src"), value.get("dst")
        if identifier is not None and not isinstance(identifier, str):
            raise ChannelError("Envelope id must be a string.")
        if (src is not None and not isinstance(src, str)) or (
            dst is not None and not isinstance(dst, str)
        ):
            raise ChannelError("Envelope src/dst must be strings.")
        return cls(frame_type, value.get("data"), identifier, src, dst)


def encode_envelope(envelope: Envelope) -> str:
    return json.dumps(envelope.to_wire(), separators=(",", ":"))


def split_message(text: str) -> list[str]:
    """Return wire messages (each <= 16 KiB) for one serialised envelope."""
    raw = text.encode("utf-8")
    if len(raw) <= MAX_MESSAGE_BYTES:
        return [text]
    pieces = [raw[i : i + CHUNK_BYTES] for i in range(0, len(raw), CHUNK_BYTES)]
    if len(raw) > MAX_REASSEMBLED_BYTES:
        raise ChannelError("Message exceeds the maximum size.")
    stream = secrets.token_urlsafe(9)
    total = len(pieces)
    return [
        json.dumps(
            {
                "v": PROTOCOL_VERSION,
                "type": "chunk",
                "stream": stream,
                "index": index,
                "total": total,
                "data": base64.b64encode(piece).decode("ascii"),
            },
            separators=(",", ":"),
        )
        for index, piece in enumerate(pieces)
    ]


@dataclass(slots=True)
class _Stream:
    total: int
    started: float
    pieces: dict[int, bytes] = field(default_factory=dict)
    size: int = 0


class Reassembler:
    """Bounded chunk reassembly: size cap, stream cap and a per-stream timeout."""

    def __init__(
        self,
        max_bytes: int = MAX_REASSEMBLED_BYTES,
        timeout: float = REASSEMBLY_TIMEOUT_SECONDS,
        max_streams: int = MAX_CONCURRENT_STREAMS,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._max_bytes = max_bytes
        self._timeout = timeout
        self._max_streams = max_streams
        self._clock = clock
        self._streams: dict[str, _Stream] = {}

    @property
    def open_streams(self) -> int:
        return len(self._streams)

    def expire(self) -> int:
        now = self._clock()
        stale = [k for k, s in self._streams.items() if now - s.started > self._timeout]
        for key in stale:
            del self._streams[key]
        return len(stale)

    def feed(self, chunk: dict[str, Any]) -> str | None:
        """Add one chunk; return the full text when the stream completes."""
        self.expire()
        stream_id, index, total, data = (
            chunk.get("stream"),
            chunk.get("index"),
            chunk.get("total"),
            chunk.get("data"),
        )
        if (
            not isinstance(stream_id, str)
            or not 0 < len(stream_id) <= 64
            or not isinstance(index, int)
            or isinstance(index, bool)
            or not isinstance(total, int)
            or isinstance(total, bool)
            or not isinstance(data, str)
            or total < 2
            or not 0 <= index < total
        ):
            raise ChannelError("Malformed chunk.")
        if total * CHUNK_BYTES > self._max_bytes + CHUNK_BYTES:
            raise ChannelError("Chunked message exceeds the maximum size.")
        stream = self._streams.get(stream_id)
        if stream is None:
            if len(self._streams) >= self._max_streams:
                raise ChannelError("Too many concurrent chunk streams.")
            stream = self._streams[stream_id] = _Stream(total, self._clock())
        elif stream.total != total:
            del self._streams[stream_id]
            raise ChannelError("Chunk stream metadata changed.")
        try:
            piece = base64.b64decode(data, validate=True)
        except (binascii.Error, ValueError) as error:
            del self._streams[stream_id]
            raise ChannelError("Chunk payload is not valid base64.") from error
        if len(piece) > CHUNK_BYTES or index in stream.pieces:
            del self._streams[stream_id]
            raise ChannelError("Invalid or duplicate chunk.")
        stream.pieces[index] = piece
        stream.size += len(piece)
        if stream.size > self._max_bytes:
            del self._streams[stream_id]
            raise ChannelError("Reassembled message exceeds the maximum size.")
        if len(stream.pieces) < stream.total:
            return None
        del self._streams[stream_id]
        try:
            return b"".join(stream.pieces[i] for i in range(total)).decode("utf-8")
        except UnicodeDecodeError as error:
            raise ChannelError("Reassembled message is not UTF-8.") from error


def decode_message(reassembler: Reassembler, text: Any) -> Envelope | None:
    """Parse one wire message; returns ``None`` while a chunked stream is incomplete."""
    if not isinstance(text, str):
        raise ChannelError("Binary data channel messages are not supported.")
    if len(text.encode("utf-8")) > MAX_MESSAGE_BYTES:
        raise ChannelError("Data channel message exceeds 16 KiB.")
    try:
        value = json.loads(text)
    except ValueError as error:
        raise ChannelError("Message is not valid JSON.") from error
    if isinstance(value, dict) and value.get("type") == "chunk":
        full = reassembler.feed(value)
        if full is None:
            return None
        try:
            value = json.loads(full)
        except ValueError as error:
            raise ChannelError("Reassembled message is not valid JSON.") from error
        if isinstance(value, dict) and value.get("type") == "chunk":
            raise ChannelError("Nested chunks are not allowed.")
    return Envelope.from_wire(value)


class DataChannelLike(Protocol):
    """The slice of ``RTCDataChannel`` used here (also implemented by test fakes)."""

    readyState: str
    bufferedAmount: int
    bufferedAmountLowThreshold: int

    def send(self, data: str) -> None: ...
    def on(self, event: str, f: Callable[..., Any] | None = None) -> Any: ...
    def close(self) -> None: ...


class ChannelEndpoint:
    """One data channel: envelope send with chunking + backpressure, and receive."""

    def __init__(
        self,
        name: str,
        channel: DataChannelLike,
        on_envelope: Callable[[str, Envelope], None],
        on_error: Callable[[str, ChannelError], None] | None = None,
    ) -> None:
        self.name = name
        self.channel = channel
        self._on_envelope = on_envelope
        self._on_error = on_error
        self._reassembler = Reassembler()
        self._drained = asyncio.Event()
        self._drained.set()
        self._send_lock = asyncio.Lock()
        channel.bufferedAmountLowThreshold = BUFFER_LOW_WATER
        channel.on("message", self._handle_message)
        channel.on("bufferedamountlow", self._handle_low)

    def _handle_low(self) -> None:
        self._drained.set()

    def _handle_message(self, message: Any) -> None:
        try:
            envelope = decode_message(self._reassembler, message)
        except ChannelError as error:
            if self._on_error is not None:
                self._on_error(self.name, error)
            return
        if envelope is not None:
            self._on_envelope(self.name, envelope)

    @property
    def is_open(self) -> bool:
        return self.channel.readyState == "open"

    async def send(self, envelope: Envelope) -> None:
        messages = split_message(encode_envelope(envelope))
        async with self._send_lock:  # keep chunks of one message contiguous
            for message in messages:
                await self._wait_for_room()
                if not self.is_open:
                    raise ChannelError("The data channel is closed.")
                self.channel.send(message)

    async def _wait_for_room(self) -> None:
        while self.channel.bufferedAmount > BUFFER_HIGH_WATER:
            self._drained.clear()
            try:
                await asyncio.wait_for(self._drained.wait(), SEND_STALL_TIMEOUT_SECONDS)
            except asyncio.TimeoutError as error:
                raise ChannelError("The data channel is stalled.") from error
            if not self.is_open:
                raise ChannelError("The data channel is closed.")

    def sweep(self) -> None:
        self._reassembler.expire()
