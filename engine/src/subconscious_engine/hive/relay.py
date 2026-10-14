"""Socket relay fallback (webrtc.md Appendix B).

Used only when a direct WebRTC link cannot be established. Records ride on the
signalling socket's ``relay {sid, to, payload}`` frames; the server sees opaque
ciphertext. A SIGMA style handshake (X25519 + Ed25519 signatures over the pinned
directory keys + HKDF-SHA256) is followed by ChaCha20-Poly1305 records.

* :class:`RelaySession` has the same surface as ``PeerLink`` (``send``,
  ``send_frame``, ``close``, ``handler``, ``closed``, ``tier`` ...), so sessions,
  tunnel, sync and tasks do not care which transport is active.
* :class:`RelayManager` owns the sessions keyed by ``(peer, sid)``, routes incoming
  ``relay`` frames and enforces one attempt per peer pair and sid.
* :class:`RateLimiter` keeps a node under the server's per-socket relay budgets
  (``signal_relay_bytes_per_second`` and the message rate bucket).

Only primitives from the pinned ``cryptography`` package are used.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import secrets
import time
from collections.abc import Awaitable, Callable
from contextlib import suppress
from dataclasses import dataclass
from typing import Any, Protocol

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from .authz import role_for_kind
from .channels import (
    CHANNEL_IDS,
    ChannelError,
    Envelope,
    Reassembler,
    decode_message,
    encode_envelope,
    split_message,
)
from .directory import Directory, DirectoryNode
from .identity import (
    IdentityError,
    NodeIdentity,
    b64u_decode,
    b64u_encode,
    node_ids_equal,
    verify_signature,
)
from .switchable import RELAY_TIER

_LOGGER = logging.getLogger("uvicorn.error")

MSG_M1 = 0x01
MSG_M2 = 0x02
MSG_M3 = 0x03
MSG_DATA = 0x10
MSG_CLOSE = 0x20
RAW_LIMIT = 24 * 1024  # raw bytes per message so the base64url payload fits the 32 KiB cap
TAG_BYTES = 16
MAX_COUNTER = 2**32 - 1  # counters are limited to 2^32 per key
MAX_AUTH_FAILURES = 5
HANDSHAKE_TIMEOUT_SECONDS = 10.0
MAX_PENDING_RESPONDERS = 8
SEEN_SID_LIMIT = 512
MAX_SID_CHARS = 64
MAX_PAYLOAD_CHARS = 40 * 1024
CLOSE_SEND_TIMEOUT_SECONDS = 3.0
# Server budgets (subconscious-server/app/config.py): signal_relay_bytes_per_second = 262144
# counted on the base64url payload, and a shared bucket of 30 messages per 10 s window.
DEFAULT_BYTES_PER_SECOND = 200_000
DEFAULT_MESSAGES_PER_SECOND = 2.5
DEFAULT_MESSAGE_BURST = 20


class RelayError(ConnectionError):
    """A relay handshake or session failure."""


# --- cryptography -----------------------------------------------------------


def relay_transcript(
    sid: str,
    initiator_id: str,
    responder_id: str,
    eph_i: bytes,
    nonce_i: bytes,
    eph_r: bytes,
    nonce_r: bytes,
) -> bytes:
    """``T = "sc-relay-v1\\n" sid "\\n" I "\\n" R "\\n" eph_i nonce_i eph_r nonce_r``."""
    head = f"sc-relay-v1\n{sid}\n{initiator_id}\n{responder_id}\n".encode()
    return head + eph_i + nonce_i + eph_r + nonce_r


def responder_signed_bytes(transcript: bytes) -> bytes:
    return b"sc-relay-resp-v1\n" + transcript


def initiator_signed_bytes(transcript: bytes) -> bytes:
    return b"sc-relay-init-v1\n" + transcript


@dataclass(frozen=True, slots=True)
class RelayKeys:
    initiator_to_responder: bytes
    responder_to_initiator: bytes
    aad: bytes  # SHA-256(T): HKDF salt and AEAD associated data


def derive_relay_keys(shared: bytes, transcript: bytes) -> RelayKeys:
    """``okm = HKDF-SHA256(ikm = shared, salt = SHA-256(T), info, 64)``."""
    salt = hashlib.sha256(transcript).digest()
    okm = HKDF(
        algorithm=hashes.SHA256(), length=64, salt=salt, info=b"sc-relay-keys-v1"
    ).derive(shared)
    return RelayKeys(okm[:32], okm[32:], salt)


def seal_record(
    key: bytes, counter: int, aad: bytes, plaintext: bytes, kind: int = MSG_DATA
) -> bytes:
    """``kind | counter(8, BE) | ciphertext | tag`` with nonce ``0000 | counter``."""
    if not 0 <= counter <= MAX_COUNTER:
        raise RelayError("The relay counter is exhausted.")
    counter_bytes = counter.to_bytes(8, "big")
    sealed = ChaCha20Poly1305(key).encrypt(b"\x00\x00\x00\x00" + counter_bytes, plaintext, aad)
    return bytes([kind]) + counter_bytes + sealed


def open_record(key: bytes, record: bytes, aad: bytes) -> bytes | None:
    """Decrypt the body of a record; ``None`` on an authentication failure."""
    if len(record) < 1 + 8 + TAG_BYTES:
        return None
    try:
        return ChaCha20Poly1305(key).decrypt(b"\x00\x00\x00\x00" + record[1:9], record[9:], aad)
    except InvalidTag:
        return None


def parse_counter(counter_bytes: bytes) -> int | None:
    """The counter, or ``None`` when it is outside ``0 .. 2^32 - 1``."""
    if len(counter_bytes) != 8 or counter_bytes[:4] != b"\x00\x00\x00\x00":
        return None
    return int.from_bytes(counter_bytes[4:], "big")


def _shared_secret(private: X25519PrivateKey, peer_public: bytes) -> bytes:
    if len(peer_public) != 32:
        raise RelayError("Invalid ephemeral key.")
    try:
        shared = private.exchange(X25519PublicKey.from_public_bytes(peer_public))
    except ValueError as error:  # low-order point
        raise RelayError("Invalid ephemeral key.") from error
    if not any(shared):
        raise RelayError("Invalid ephemeral key.")
    return shared


def _public_bytes(private: X25519PrivateKey) -> bytes:
    return private.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )


def _sign(identity: NodeIdentity, message: bytes) -> bytes:
    return b64u_decode(identity.sign(message))


def _verify(public_key: bytes, signature: bytes, message: bytes) -> bool:
    return verify_signature(public_key, b64u_encode(signature), message)


class RelayInitiator:
    """Initiator half of the handshake (sends M1, verifies M2, produces M3)."""

    def __init__(
        self,
        identity: NodeIdentity,
        remote_id: str,
        remote_public_key: bytes,
        sid: str,
        *,
        ephemeral_seed: bytes | None = None,
        nonce: bytes | None = None,
    ) -> None:
        self._identity = identity
        self._remote_id = remote_id
        self._remote_key = remote_public_key
        self.sid = sid
        self._seed = ephemeral_seed
        self._nonce = nonce if nonce is not None else secrets.token_bytes(16)
        self._ephemeral: X25519PrivateKey | None = None
        self._eph_public = b""

    def start(self) -> bytes:
        """M1 = ``0x01 | eph_i | nonce_i``."""
        seed = self._seed if self._seed is not None else secrets.token_bytes(32)
        self._ephemeral = X25519PrivateKey.from_private_bytes(seed)
        self._eph_public = _public_bytes(self._ephemeral)
        return bytes([MSG_M1]) + self._eph_public + self._nonce

    def receive_m2(self, m2: bytes) -> tuple[bytes, RelayKeys]:
        """Verify M2 against the pinned key; returns ``(M3, keys)``."""
        private = self._ephemeral
        if private is None:
            raise RelayError("The handshake was not started.")
        if len(m2) != 1 + 32 + 16 + 64 or m2[0] != MSG_M2:
            raise RelayError("Malformed M2.")
        eph_r, nonce_r, sig_r = m2[1:33], m2[33:49], m2[49:113]
        transcript = relay_transcript(
            self.sid, self._identity.node_id, self._remote_id,
            self._eph_public, self._nonce, eph_r, nonce_r,
        )
        if not _verify(self._remote_key, sig_r, responder_signed_bytes(transcript)):
            raise RelayError("The responder signature is invalid.")
        keys = derive_relay_keys(_shared_secret(private, eph_r), transcript)
        sig_i = _sign(self._identity, initiator_signed_bytes(transcript))
        self._ephemeral = None  # the ephemeral private key is discarded
        return bytes([MSG_M3]) + sig_i, keys


class RelayResponder:
    """Responder half of the handshake (verifies M1, sends M2, verifies M3)."""

    def __init__(
        self,
        identity: NodeIdentity,
        remote_id: str,
        remote_public_key: bytes,
        sid: str,
        *,
        ephemeral_seed: bytes | None = None,
        nonce: bytes | None = None,
    ) -> None:
        self._identity = identity
        self._remote_id = remote_id
        self._remote_key = remote_public_key
        self.sid = sid
        self._seed = ephemeral_seed
        self._nonce = nonce
        self._transcript: bytes | None = None
        self._keys: RelayKeys | None = None

    def receive_m1(self, m1: bytes) -> bytes:
        """Validate M1 and return M2 = ``0x02 | eph_r | nonce_r | sig_r``."""
        if self._transcript is not None:
            raise RelayError("Duplicate M1.")
        if len(m1) != 1 + 32 + 16 or m1[0] != MSG_M1:
            raise RelayError("Malformed M1.")
        eph_i, nonce_i = m1[1:33], m1[33:49]
        private = X25519PrivateKey.from_private_bytes(
            self._seed if self._seed is not None else secrets.token_bytes(32)
        )
        eph_r = _public_bytes(private)
        nonce_r = self._nonce if self._nonce is not None else secrets.token_bytes(16)
        shared = _shared_secret(private, eph_i)
        transcript = relay_transcript(
            self.sid, self._remote_id, self._identity.node_id, eph_i, nonce_i, eph_r, nonce_r
        )
        sig_r = _sign(self._identity, responder_signed_bytes(transcript))
        self._keys = derive_relay_keys(shared, transcript)
        self._transcript = transcript
        return bytes([MSG_M2]) + eph_r + nonce_r + sig_r

    def receive_m3(self, m3: bytes) -> RelayKeys:
        """Verify M3 against the pinned key; returns the session keys."""
        transcript, keys = self._transcript, self._keys
        if transcript is None or keys is None:
            raise RelayError("M3 arrived before M1.")
        if len(m3) != 1 + 64 or m3[0] != MSG_M3:
            raise RelayError("Malformed M3.")
        if not _verify(self._remote_key, m3[1:], initiator_signed_bytes(transcript)):
            raise RelayError("The initiator signature is invalid.")
        self._keys = None
        return keys


# --- rate limiting ----------------------------------------------------------


class RateLimiter:
    """Token buckets (bytes and messages) shared by every relay session of a node."""

    def __init__(
        self,
        bytes_per_second: float = DEFAULT_BYTES_PER_SECOND,
        messages_per_second: float = DEFAULT_MESSAGES_PER_SECOND,
        message_burst: float = DEFAULT_MESSAGE_BURST,
        *,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    ) -> None:
        self._byte_rate = float(bytes_per_second)
        self._message_rate = float(messages_per_second)
        self._byte_cap = float(bytes_per_second)
        self._message_cap = float(message_burst)
        self._bytes = self._byte_cap
        self._messages = self._message_cap
        self._clock = clock
        self._sleep = sleep
        self._stamp = clock()
        self._lock = asyncio.Lock()

    def _refill(self) -> None:
        now = self._clock()
        elapsed = max(0.0, now - self._stamp)
        self._stamp = now
        self._bytes = min(self._byte_cap, self._bytes + elapsed * self._byte_rate)
        self._messages = min(self._message_cap, self._messages + elapsed * self._message_rate)

    async def acquire(self, nbytes: int) -> None:
        """Wait until one message of ``nbytes`` (base64url payload length) may be sent."""
        needed = min(float(nbytes), self._byte_cap)
        async with self._lock:  # FIFO: concurrent senders are served in order
            while True:
                self._refill()
                if self._messages >= 1.0 and self._bytes >= needed:
                    self._messages -= 1.0
                    self._bytes -= needed
                    return
                wait = max(
                    (1.0 - self._messages) / self._message_rate,
                    (needed - self._bytes) / self._byte_rate,
                    0.001,
                )
                await self._sleep(wait)


# --- session ----------------------------------------------------------------


Transmit = Callable[[bytes], Awaitable[None]]


class RelaySession:
    """An established relay session to one trusted node; duck-types ``PeerLink``."""

    tier = RELAY_TIER

    def __init__(
        self,
        *,
        node_id: str,
        role: str,
        local_id: str,
        sid: str,
        send_key: bytes,
        receive_key: bytes,
        aad: bytes,
        transmit: Transmit,
        on_closed: Callable[["RelaySession"], None] | None = None,
        preamble: bytes | None = None,
    ) -> None:
        self.node_id = node_id
        self.role = role
        self.local_id = local_id
        self.sid = sid
        self.handler: Callable[[Any, str, Envelope], None] | None = None
        self.closed = asyncio.Event()
        self.created = time.time()
        self.on_closed: Callable[[Any], None] | None = None  # set by the owning SwitchableLink
        self._send_key = send_key
        self._receive_key = receive_key
        self._aad = aad
        self._transmit = transmit
        self._manager_closed = on_closed
        self._preamble = preamble
        self._send_counter = 0
        self._last_received = -1
        self._auth_failures = 0
        self._send_lock = asyncio.Lock()
        self._reassemblers: dict[str, Reassembler] = {}
        self._tasks: set[asyncio.Task[Any]] = set()
        if preamble is not None:  # M3 must leave before the first data record
            self._spawn(self._flush_preamble())

    # --- sending ------------------------------------------------------------
    def _spawn(self, coro: Awaitable[Any]) -> None:
        task = asyncio.ensure_future(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _flush_preamble(self) -> None:
        try:
            async with self._send_lock:
                await self._send_preamble()
        except Exception:
            await self.close()

    async def _send_preamble(self) -> None:
        preamble, self._preamble = self._preamble, None
        if preamble is not None:
            await self._transmit(preamble)

    async def send(self, channel: str, envelope: Envelope) -> None:
        if self.closed.is_set():
            raise ChannelError("The peer link is closed.")
        if channel not in CHANNEL_IDS:
            raise ChannelError(f"Unknown channel: {channel}")
        parts = split_message(
            encode_envelope(
                Envelope(envelope.type, envelope.data, envelope.id, self.local_id, self.node_id)
            )
        )
        try:
            async with self._send_lock:
                await self._send_preamble()
                for part in parts:
                    if self.closed.is_set():
                        raise ChannelError("The peer link is closed.")
                    plaintext = f'{{"ch":{json.dumps(channel)},"env":{part}}}'.encode()
                    record = self._seal(plaintext, MSG_DATA)
                    if len(record) > RAW_LIMIT:
                        raise ChannelError("A relay record exceeds 24 KiB.")
                    await self._transmit(record)
        except ChannelError:
            raise
        except RelayError as error:  # counter exhausted: rekey with a new sid
            await self.close()
            raise ChannelError(str(error)) from error
        except Exception as error:
            # A record that did not leave leaves a hole in the stream: end the session so
            # the layers above reconnect instead of waiting for frames that never arrive.
            await self.close()
            raise ChannelError("The relay transmit failed.") from error

    async def send_frame(
        self, channel: str, frame_type: str, data: Any, identifier: str | None = None
    ) -> None:
        await self.send(channel, Envelope(frame_type, data, identifier))

    def _seal(self, plaintext: bytes, kind: int) -> bytes:
        record = seal_record(self._send_key, self._send_counter, self._aad, plaintext, kind)
        self._send_counter += 1
        return record

    # --- receiving ----------------------------------------------------------
    def on_record(self, record: bytes) -> None:
        """Process one received record (strictly in arrival order)."""
        if self.closed.is_set() or not record:
            return
        kind = record[0]
        if kind == MSG_CLOSE:
            # Only an authenticated close ends the session. A bare 0x20 (or any forged
            # close) is ignored, otherwise the relay could be used to kill a link.
            if len(record) == 1:
                return
            if self._accept(record) is not None:
                self._finish()
            return
        if kind != MSG_DATA:
            return
        plaintext = self._accept(record)
        if plaintext is not None:
            self._deliver(plaintext)

    def _accept(self, record: bytes) -> bytes | None:
        """Counter check, then decrypt, then advance the counter."""
        if len(record) < 1 + 8 + TAG_BYTES:
            return None
        counter = parse_counter(record[1:9])
        if counter is None or counter <= self._last_received:
            return None  # replayed or reordered: dropped before any decryption
        clear = open_record(self._receive_key, record, self._aad)
        if clear is None:
            self._auth_failures += 1
            if self._auth_failures >= MAX_AUTH_FAILURES:
                self._spawn(self.close())
            return None
        self._auth_failures = 0
        self._last_received = counter
        return clear

    def _deliver(self, plaintext: bytes) -> None:
        try:
            decoded = json.loads(plaintext.decode("utf-8"))
            channel = decoded.get("ch") if isinstance(decoded, dict) else None
            if not isinstance(channel, str) or channel not in CHANNEL_IDS:
                return
            reassembler = self._reassemblers.setdefault(channel, Reassembler())
            envelope = decode_message(
                reassembler,
                json.dumps(decoded.get("env"), separators=(",", ":"), ensure_ascii=False),
            )
        except (ValueError, ChannelError):
            return  # authenticated but malformed content is dropped
        if envelope is None:
            return
        if envelope.src is not None and not node_ids_equal(envelope.src, self.node_id):
            return
        if envelope.dst is not None and not node_ids_equal(envelope.dst, self.local_id):
            return
        handler = self.handler
        if handler is not None:
            try:
                handler(self, channel, envelope)
            except Exception:
                _LOGGER.debug("A relay envelope handler failed.", exc_info=True)

    # --- closing ------------------------------------------------------------
    async def close(self) -> None:
        """Send an authenticated close record (best effort) and end the session."""
        if self.closed.is_set():
            return
        can_send = self._send_counter <= MAX_COUNTER
        self._finish()
        if not can_send:
            return
        with suppress(Exception):
            async with self._send_lock:
                record = self._seal(b"", MSG_CLOSE)
                await asyncio.wait_for(self._transmit(record), CLOSE_SEND_TIMEOUT_SECONDS)

    def _finish(self) -> None:
        if self.closed.is_set():
            return
        self.closed.set()
        for hook in (self._manager_closed, self.on_closed):
            if hook is not None:
                with suppress(Exception):
                    hook(self)


# --- manager ----------------------------------------------------------------


class RelaySender(Protocol):
    async def send_relay(self, sid: str, to: str, payload: str) -> None: ...


@dataclass(slots=True)
class _Handshake:
    peer: str
    sid: str
    initiator: RelayInitiator | None = None
    responder: RelayResponder | None = None
    timer: asyncio.TimerHandle | None = None

    @property
    def is_initiator(self) -> bool:
        return self.initiator is not None


def new_relay_sid(now: float) -> str:
    return f"{int(now)}.{b64u_encode(secrets.token_bytes(9))}"


class RelayManager:
    """Runs relay handshakes and sessions for one node.

    Feed it every server ``relay`` frame through :meth:`handle_relay`. The peer must be an
    active, verified member of the account (pinned directory key). ``on_session`` receives
    every established session (initiator or responder side) exactly once.
    """

    def __init__(
        self,
        identity: NodeIdentity,
        directory: Directory,
        sender: RelaySender,
        *,
        on_session: Callable[[RelaySession], None] | None = None,
        limiter: RateLimiter | None = None,
        handshake_timeout: float = HANDSHAKE_TIMEOUT_SECONDS,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._identity = identity
        self._directory = directory
        self._sender = sender
        self._on_session = on_session
        self._limiter = limiter or RateLimiter()
        self._handshake_timeout = handshake_timeout
        self._clock = clock
        self._handshakes: dict[tuple[str, str], _Handshake] = {}
        self._sessions: dict[tuple[str, str], RelaySession] = {}
        self._connecting: dict[str, asyncio.Future[RelaySession]] = {}
        self._abandoned: set[str] = set()
        self._seen_sids: dict[tuple[str, str], None] = {}
        self._tasks: set[asyncio.Task[Any]] = set()
        self._closed = False

    # --- public ---------------------------------------------------------------
    @property
    def sessions(self) -> list[RelaySession]:
        return [s for s in self._sessions.values() if not s.closed.is_set()]

    def session_for(self, node_id: str) -> RelaySession | None:
        matches = [s for s in self.sessions if node_ids_equal(s.node_id, node_id)]
        return max(matches, key=lambda s: s.created, default=None)

    async def connect(self, node_id: str) -> RelaySession:
        """Start (or join) a relay attempt as the initiator."""
        if self._closed:
            raise RelayError("The relay manager is closed.")
        existing = self.session_for(node_id)
        if existing is not None:
            return existing
        peer = node_id.lower()
        pending = self._connecting.get(peer)
        if pending is None:
            remote = self._trusted(node_id)
            if remote is None:
                raise RelayError("That node is not a trusted member of this hive.")
            pending = asyncio.get_running_loop().create_future()
            pending.add_done_callback(_mark_retrieved)
            self._connecting[peer] = pending
            self._spawn(self._start_initiator(remote))
        return await asyncio.shield(pending)

    async def handle_relay(self, data: dict[str, Any]) -> None:
        """Entry point for server ``relay`` frames. Never raises; invalid input is dropped."""
        try:
            self._handle(data)
        except asyncio.CancelledError:
            raise
        except Exception:
            _LOGGER.debug("Dropped an invalid relay frame.", exc_info=True)

    async def close_peer(self, node_id: str) -> None:
        peer = node_id.lower()
        for key in [k for k in self._handshakes if k[0] == peer]:
            self._drop(key)
        self._fail_connecting(peer, RelayError("The relay peer went away."))
        for session in [s for s in self._sessions.values() if node_ids_equal(s.node_id, node_id)]:
            await session.close()

    async def close(self) -> None:
        self._closed = True
        for key in list(self._handshakes):
            self._drop(key)
        for peer in list(self._connecting):
            self._fail_connecting(peer, RelayError("The relay manager is closed."))
        for session in list(self._sessions.values()):
            await session.close()
        for task in list(self._tasks):
            task.cancel()
        for task in list(self._tasks):
            with suppress(asyncio.CancelledError, Exception):
                await task

    # --- internals --------------------------------------------------------------
    def _spawn(self, coro: Awaitable[Any]) -> None:
        task = asyncio.ensure_future(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    def _trusted(self, node_id: str) -> DirectoryNode | None:
        remote = self._directory.trusted_node(node_id)
        if remote is None or role_for_kind(remote.kind) is None:
            return None
        return remote

    async def _transmit(self, peer: str, sid: str, data: bytes) -> None:
        payload = b64u_encode(data)
        await self._limiter.acquire(len(payload))
        await self._sender.send_relay(sid, peer, payload)

    def _arm(self, handshake: _Handshake) -> None:
        key = (handshake.peer.lower(), handshake.sid)
        self._handshakes[key] = handshake
        loop = asyncio.get_running_loop()

        def expire() -> None:
            if self._handshakes.get(key) is handshake:
                self._drop(key)
                self._fail_connecting(
                    key[0],
                    RelayError("The relay handshake timed out."),
                    only_if_abandoned=not handshake.is_initiator,
                )

        handshake.timer = loop.call_later(self._handshake_timeout, expire)

    def _drop(self, key: tuple[str, str]) -> None:
        handshake = self._handshakes.pop(key, None)
        if handshake is not None and handshake.timer is not None:
            handshake.timer.cancel()

    def _fail_connecting(
        self, peer: str, error: Exception, *, only_if_abandoned: bool = False
    ) -> None:
        pending = self._connecting.get(peer)
        if pending is None or (only_if_abandoned and peer not in self._abandoned):
            return
        del self._connecting[peer]
        self._abandoned.discard(peer)
        if not pending.done():
            pending.set_exception(error)

    async def _start_initiator(self, remote: DirectoryNode) -> None:
        sid = new_relay_sid(self._clock())
        initiator = RelayInitiator(self._identity, remote.id, remote.public_key, sid)
        handshake = _Handshake(remote.id, sid, initiator=initiator)
        key = (remote.id.lower(), sid)
        self._arm(handshake)
        try:
            await self._transmit(remote.id, sid, initiator.start())
        except Exception:
            self._drop(key)
            self._fail_connecting(key[0], RelayError("The relay handshake could not start."))

    def _handle(self, data: dict[str, Any]) -> None:
        if self._closed:
            return
        sender, sid, payload = data.get("from"), data.get("sid"), data.get("payload")
        if not isinstance(sender, str) or not isinstance(sid, str) or not isinstance(payload, str):
            return
        if not 0 < len(sid) <= MAX_SID_CHARS or len(payload) > MAX_PAYLOAD_CHARS:
            return
        if node_ids_equal(sender, self._identity.node_id):
            return
        remote = self._trusted(sender)
        if remote is None:
            return
        try:
            raw = b64u_decode(payload)
        except IdentityError:
            return
        if not raw or len(raw) > RAW_LIMIT:
            return
        key = (remote.id.lower(), sid)
        session = self._sessions.get(key)
        if session is not None:
            session.on_record(raw)
            return
        handshake = self._handshakes.get(key)
        if handshake is not None:
            if handshake.is_initiator and raw[0] == MSG_M2:
                self._finish_initiator(handshake, remote, raw)
            elif not handshake.is_initiator and raw[0] == MSG_M3:
                self._finish_responder(handshake, remote, raw)
            return
        if raw[0] == MSG_M1:
            self._start_responder(remote, sid, raw)

    def _start_responder(self, remote: DirectoryNode, sid: str, m1: bytes) -> None:
        peer = remote.id.lower()
        key = (peer, sid)
        own = next(
            (h for h in self._handshakes.values() if h.is_initiator and h.peer.lower() == peer),
            None,
        )
        if own is not None:
            # Both sides started at once: the lower node id keeps its attempt as initiator.
            if self._identity.node_id.lower() < peer:
                return
            self._drop((peer, own.sid))
            if peer in self._connecting:
                self._abandoned.add(peer)
        # At most one attempt per peer pair and sid; one pending responder per peer.
        if key in self._seen_sids:
            return
        responders = [h for h in self._handshakes.values() if not h.is_initiator]
        if any(h.peer.lower() == peer for h in responders) or len(responders) >= MAX_PENDING_RESPONDERS:
            return
        if len(self._seen_sids) >= SEEN_SID_LIMIT:
            del self._seen_sids[next(iter(self._seen_sids))]
        self._seen_sids[key] = None
        responder = RelayResponder(self._identity, remote.id, remote.public_key, sid)
        try:
            m2 = responder.receive_m1(m1)
        except RelayError:
            return
        self._arm(_Handshake(remote.id, sid, responder=responder))
        self._spawn(self._send_m2(peer, remote.id, sid, m2))

    async def _send_m2(self, peer: str, node_id: str, sid: str, m2: bytes) -> None:
        try:
            await self._transmit(node_id, sid, m2)
        except Exception:
            self._drop((peer, sid))
            self._fail_connecting(peer, RelayError("The relay handshake failed."), only_if_abandoned=True)

    def _finish_initiator(self, handshake: _Handshake, remote: DirectoryNode, m2: bytes) -> None:
        key = (remote.id.lower(), handshake.sid)
        assert handshake.initiator is not None
        try:
            m3, keys = handshake.initiator.receive_m2(m2)
        except RelayError:
            self._drop(key)  # a bad or forged M2 drops the attempt silently
            self._fail_connecting(key[0], RelayError("The relay handshake failed."))
            return
        self._drop(key)
        self._establish(
            remote, handshake.sid, keys.initiator_to_responder, keys.responder_to_initiator,
            keys.aad, preamble=m3,
        )

    def _finish_responder(self, handshake: _Handshake, remote: DirectoryNode, m3: bytes) -> None:
        key = (remote.id.lower(), handshake.sid)
        assert handshake.responder is not None
        try:
            keys = handshake.responder.receive_m3(m3)
        except RelayError:
            self._drop(key)
            self._fail_connecting(key[0], RelayError("The relay handshake failed."), only_if_abandoned=True)
            return
        self._drop(key)
        self._establish(
            remote, handshake.sid, keys.responder_to_initiator, keys.initiator_to_responder, keys.aad
        )

    def _establish(
        self,
        remote: DirectoryNode,
        sid: str,
        send_key: bytes,
        receive_key: bytes,
        aad: bytes,
        *,
        preamble: bytes | None = None,
    ) -> None:
        role = role_for_kind(remote.kind)
        if role is None:
            return
        peer = remote.id
        key = (peer.lower(), sid)
        session = RelaySession(
            node_id=peer, role=role, local_id=self._identity.node_id, sid=sid,
            send_key=send_key, receive_key=receive_key, aad=aad,
            transmit=lambda record: self._transmit(peer, sid, record),
            on_closed=lambda s, k=key: self._sessions.pop(k, None) if self._sessions.get(k) is s else None,
            preamble=preamble,
        )
        self._sessions[key] = session
        if self._on_session is not None:
            try:
                self._on_session(session)
            except Exception:
                _LOGGER.debug("The relay session callback failed.", exc_info=True)
        pending = self._connecting.pop(key[0], None)
        self._abandoned.discard(key[0])
        if pending is not None and not pending.done():
            pending.set_result(session)


def _mark_retrieved(future: "asyncio.Future[Any]") -> None:
    if not future.cancelled():
        future.exception()
