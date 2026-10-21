"""Signalling client: ticket fetch, authenticated WebSocket, backoff and dispatch.

Never logs tickets, challenges, SDP or tokens.
"""

from __future__ import annotations

import asyncio
import json
import logging
import random
from collections.abc import Awaitable, Callable
from typing import Any, Protocol
from urllib.parse import urlsplit, urlunsplit

from . import PROTOCOL_VERSION
from .directory import HiveApi, HiveApiError
from .identity import NodeIdentity, signal_auth_message
from ..logging_setup import logged_suppress, spawn_logged
from ..tls import ssl_for_url

_LOGGER = logging.getLogger("uvicorn.error")
MAX_FRAME_BYTES = 64 * 1024
AUTH_TIMEOUT_SECONDS = 10.0
BACKOFF_BASE_SECONDS = 1.0
BACKOFF_MAX_SECONDS = 60.0
STABLE_AFTER_SECONDS = 30.0
# Access tokens live 15 minutes; refresh the ticket well before the server closes.
DEFAULT_REFRESH_INTERVAL_SECONDS = 12 * 60.0
# The server closes a socket that sends nothing for 60 s (webrtc.md 4.3), and WebSocket
# protocol pings are invisible to its handler, so an application level ping is required.
HEARTBEAT_SECONDS = 25.0
# A persistent failure with an unchanged cause is logged at WARNING once per this many attempts.
FAILURE_LOG_EVERY = 10


class SignalSocket(Protocol):
    """The slice of a websockets connection used here."""

    async def send(self, message: str) -> None: ...
    async def recv(self) -> str | bytes: ...
    async def close(self, code: int = 1000, reason: str = "") -> None: ...


ConnectFactory = Callable[[str], Awaitable[SignalSocket]]
FrameHandler = Callable[[dict[str, Any]], Awaitable[None]]


def signal_url(base_url: str) -> str:
    parts = urlsplit(base_url)
    scheme = "wss" if parts.scheme == "https" else "ws"
    return urlunsplit((scheme, parts.netloc, parts.path.rstrip("/") + "/signal", "", ""))


async def default_connect(url: str) -> SignalSocket:
    from websockets.asyncio.client import connect

    return await connect(  # type: ignore[return-value]
        url, max_size=MAX_FRAME_BYTES, open_timeout=15, ssl=ssl_for_url(url)
    )


def backoff_delay(
    attempt: int,
    *,
    base: float = BACKOFF_BASE_SECONDS,
    cap: float = BACKOFF_MAX_SECONDS,
    rng: Callable[[], float] = random.random,
) -> float:
    """Exponential backoff with full jitter, always in ``[base/2, cap]``."""
    ceiling = min(cap, base * (2 ** max(0, attempt)))
    return max(base / 2, rng() * ceiling)


class SignalingClient:
    def __init__(
        self,
        api: HiveApi,
        identity: NodeIdentity,
        *,
        connect: ConnectFactory = default_connect,
        refresh_interval: float = DEFAULT_REFRESH_INTERVAL_SECONDS,
        heartbeat_interval: float = HEARTBEAT_SECONDS,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
        rng: Callable[[], float] = random.random,
        on_connected: Callable[[], Awaitable[None]] | None = None,
    ) -> None:
        self.on_connected = on_connected
        self._api = api
        self._identity = identity
        self._connect = connect
        self._refresh_interval = refresh_interval
        self._heartbeat_interval = heartbeat_interval
        self._sleep = sleep
        self._rng = rng
        self._handlers: dict[str, FrameHandler] = {}
        self._socket: SignalSocket | None = None
        self._task: asyncio.Task[None] | None = None
        self._send_lock = asyncio.Lock()
        self._connected = asyncio.Event()
        self._presence: dict[str, Any] = {"clients": [], "capabilities": {}}
        self.hive_id: str | None = None
        self.failures = 0
        self.last_error: str | None = None
        self.last_error_detail: str | None = None
        self._last_reported: tuple[str, str] | None = None
        self._wake = asyncio.Event()

    # --- public -----------------------------------------------------------
    def on(self, frame_type: str, handler: FrameHandler) -> None:
        self._handlers[frame_type] = handler

    @property
    def connected(self) -> bool:
        return self._connected.is_set()

    async def wait_connected(self, timeout: float) -> None:
        await asyncio.wait_for(self._connected.wait(), timeout)

    def start(self) -> None:
        if self._task is None:
            self._task = spawn_logged(self._run(), name="hive-signaling")

    async def stop(self) -> None:
        task, self._task = self._task, None
        if task is not None:
            task.cancel()
            with logged_suppress(asyncio.CancelledError, Exception):
                await task
        await self._close_socket()

    async def send(self, frame_type: str, data: dict[str, Any]) -> None:
        socket = self._socket
        if socket is None or not self._connected.is_set():
            raise ConnectionError("Signalling is not connected.")
        text = json.dumps(
            {"v": PROTOCOL_VERSION, "type": frame_type, "data": data},
            separators=(",", ":"),
        )
        if len(text.encode("utf-8")) > MAX_FRAME_BYTES:
            raise ValueError("Signalling frame is too large.")
        async with self._send_lock:
            await socket.send(text)

    async def send_signal(
        self, sid: str, to: str, kind: str, body: dict[str, Any], sig: str | None
    ) -> None:
        data: dict[str, Any] = {"sid": sid, "to": to, "kind": kind, "body": body}
        if sig is not None:
            data["sig"] = sig
        await self.send("signal", data)

    async def send_relay(self, sid: str, to: str, payload: str) -> None:
        """Send one opaque ``relay`` frame (Appendix B); the server forwards it unread."""
        await self.send("relay", {"sid": sid, "to": to, "payload": payload})

    async def set_presence(self, clients: list[str], capabilities: dict[str, Any]) -> None:
        self._presence = {"clients": clients, "capabilities": capabilities}
        if self.connected:
            await self.send("presence.set", self._presence)

    # --- connection loop ----------------------------------------------------
    async def _run(self) -> None:
        loop = asyncio.get_running_loop()
        while True:
            started = loop.time()
            reason = "closed"
            try:
                await self._session()
            except asyncio.CancelledError:
                raise
            except HiveApiError as error:
                reason = f"HiveApiError:{error.status_code}"
                self.last_error = reason
                self.last_error_detail = error.message
            except Exception as error:  # reconnect on anything transient
                reason = type(error).__name__
                self.last_error = reason
                self.last_error_detail = str(error)[:300] or reason
                _LOGGER.debug("Signalling disconnected (%s).", reason, exc_info=True)
            finally:
                self._connected.clear()
                await self._close_socket()
            if loop.time() - started >= STABLE_AFTER_SECONDS:
                self.failures = 0
            delay = backoff_delay(self.failures, rng=self._rng)
            self.failures += 1
            self._report_failure(reason, delay)
            await self._backoff(delay)

    def wake(self) -> None:
        """Skip the current reconnect backoff (a user asked to refresh now)."""
        self._wake.set()

    async def _backoff(self, delay: float) -> None:
        """Sleep ``delay`` unless :meth:`wake` is called first."""
        self._wake.clear()
        sleeper = asyncio.ensure_future(self._sleep(delay))
        waker = asyncio.ensure_future(self._wake.wait())
        try:
            await asyncio.wait({sleeper, waker}, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for task in (sleeper, waker):
                task.cancel()
                with logged_suppress(asyncio.CancelledError, Exception):
                    await task
        if waker.done() and not waker.cancelled():
            _LOGGER.warning("Signalling retry requested; reconnecting now.")

    def _report_failure(self, reason: str, delay: float) -> None:
        """Every failed signalling session reaches the production log (WARNING).

        While signalling is down this node is offline for every other device, so a
        failure here is never silent. Repeats of the same cause are condensed to one
        line per ``FAILURE_LOG_EVERY`` attempts to keep the log readable.
        """
        detail = self.last_error_detail or reason
        changed = (reason, detail) != self._last_reported
        if changed or self.failures % FAILURE_LOG_EVERY == 1:
            self._last_reported = (reason, detail)
            _LOGGER.warning(
                "Signalling to %s failed (%s: %s); this node shows offline. "
                "Attempt %d, retry in %.0fs.",
                signal_url(self._api.base_url),
                reason,
                detail,
                self.failures,
                delay,
            )
        else:
            _LOGGER.info("Signalling closed (%s) retry in %.0fs", reason, delay)

    async def _session(self) -> None:
        ticket = await self._api.signal_ticket(self._identity.node_id)
        socket = await self._connect(signal_url(self._api.base_url))
        self._socket = socket
        await self._send_auth(socket, ticket, "auth")
        reply = await asyncio.wait_for(self._receive(socket), AUTH_TIMEOUT_SECONDS)
        if reply.get("type") != "auth.ok":
            raise ConnectionError("Signalling authentication was rejected.")
        data = reply.get("data")
        if isinstance(data, dict):
            hive = data.get("hive_id")
            self.hive_id = hive if isinstance(hive, str) else None
        self._connected.set()
        self.last_error = None
        self.last_error_detail = None
        if self._last_reported is not None:
            # Pair the earlier failure warnings with their recovery in the production log.
            _LOGGER.warning(
                "Signalling recovered node_id=%s after %d failed attempts.",
                self._identity.node_id,
                self.failures,
            )
            self._last_reported = None
        else:
            _LOGGER.info("Signalling connected node_id=%s", self._identity.node_id)
        await self.send("presence.set", self._presence)
        if self.on_connected is not None:
            try:
                await self.on_connected()
            except asyncio.CancelledError:
                raise
            except Exception:
                _LOGGER.warning("Signalling on_connected callback failed.", exc_info=True)
        background = [
            spawn_logged(self._refresh_loop()),
            spawn_logged(self._heartbeat_loop()),
        ]
        try:
            while True:
                frame = await self._receive(socket)
                await self._dispatch(frame)
        finally:
            for task in background:
                task.cancel()
            for task in background:
                with logged_suppress(asyncio.CancelledError, Exception):
                    await task

    async def _send_auth(
        self, socket: SignalSocket, ticket: dict[str, Any], frame_type: str
    ) -> None:
        value, challenge = ticket.get("ticket"), ticket.get("challenge")
        if not isinstance(value, str) or not isinstance(challenge, str):
            raise HiveApiError("The hive server returned an invalid ticket.")
        sig = self._identity.sign(
            signal_auth_message(challenge, value, self._identity.node_id)
        )
        data: dict[str, Any] = {"ticket": value, "sig": sig}
        if frame_type == "auth":
            data["node_id"] = self._identity.node_id
        async with self._send_lock:
            await socket.send(
                json.dumps(
                    {"v": PROTOCOL_VERSION, "type": frame_type, "data": data},
                    separators=(",", ":"),
                )
            )

    async def _refresh_loop(self) -> None:
        while True:
            await self._sleep(self._refresh_interval)
            await self.refresh_auth()

    async def _heartbeat_loop(self) -> None:
        while True:
            await asyncio.sleep(self._heartbeat_interval)  # real time, independent of the injected sleep
            await self.send("ping", {})

    async def refresh_auth(self) -> None:
        socket = self._socket
        if socket is None:
            return
        ticket = await self._api.signal_ticket(self._identity.node_id)
        await self._send_auth(socket, ticket, "auth.refresh")

    async def _receive(self, socket: SignalSocket) -> dict[str, Any]:
        raw = await socket.recv()
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8", errors="replace")
        if len(raw.encode("utf-8")) > MAX_FRAME_BYTES:
            raise ConnectionError("Oversized signalling frame.")
        try:
            frame = json.loads(raw)
        except ValueError as error:
            raise ConnectionError("Invalid signalling frame.") from error
        if not isinstance(frame, dict) or not isinstance(frame.get("type"), str):
            raise ConnectionError("Invalid signalling frame.")
        return frame

    async def _dispatch(self, frame: dict[str, Any]) -> None:
        frame_type = frame["type"]
        if frame_type == "error":
            code = frame.get("data", {}).get("code") if isinstance(frame.get("data"), dict) else None
            _LOGGER.warning(
                "Signalling server error: %s", code if isinstance(code, str) else "unknown"
            )
            return
        handler = self._handlers.get(frame_type)
        if handler is None:
            return
        data = frame.get("data")
        try:
            await handler(data if isinstance(data, dict) else {})
        except asyncio.CancelledError:
            raise
        except Exception:
            _LOGGER.warning("Signalling handler failed for %s.", frame_type, exc_info=True)

    async def _close_socket(self) -> None:
        socket, self._socket = self._socket, None
        if socket is not None:
            with logged_suppress(Exception):
                await socket.close()
