"""PeerSession: reuse ``WebSocketSession`` over an authenticated peer link."""

from __future__ import annotations

import asyncio
import logging
from types import SimpleNamespace
from typing import Any

from starlette.websockets import WebSocketDisconnect

from subconscious_engine.api.websocket import WebSocketSession

from . import PROTOCOL_VERSION
from .authz import authorize_frame
from .channels import ChannelError, Envelope
from .peers import PeerLink
from ..logging_setup import logged_suppress, spawn_logged

_LOGGER = logging.getLogger("uvicorn.error")
INBOX_LIMIT = 256
_CLOSED = object()
# Streaming-style frames use the low latency channel; the rest use control.
_EVENT_FRAMES = frozenset({"chat.delta", "chat.tool_call", "agui.event", "message.created", "thread.created"})


class PeerSocket:
    """Quacks like the WebSocket ``WebSocketSession`` expects (``SessionTransport``)."""

    def __init__(self, app: Any, link: PeerLink, display_name: str = "") -> None:
        self.app = app
        self.link = link
        self.display_name = display_name
        self.client = SimpleNamespace(host=f"peer:{link.node_id}", port=None)
        self._inbox: asyncio.Queue[Any] = asyncio.Queue(INBOX_LIMIT)

    async def accept(self) -> None:
        return None

    async def receive_json(self) -> Any:
        item = await self._inbox.get()
        if item is _CLOSED:
            raise WebSocketDisconnect(code=1001)
        return item

    async def send_json(self, data: Any) -> None:
        frame_type = data.get("type") if isinstance(data, dict) else None
        if not isinstance(frame_type, str):
            return
        channel = "events" if frame_type in _EVENT_FRAMES else "control"
        identifier = data.get("id") if isinstance(data.get("id"), str) else None
        try:
            await self.link.send(channel, Envelope(frame_type, data.get("data"), identifier))
        except ChannelError:
            self.close()
            raise WebSocketDisconnect(code=1006) from None

    def feed(self, envelope: Envelope) -> None:
        """Authorise one inbound frame and queue it for the session."""
        if not authorize_frame(self.link.role, envelope.type):
            self._reject(envelope)
            return
        data = envelope.data
        if envelope.type == "client.hello":
            # Peers cannot choose (or collide with) local client identifiers.
            data = dict(data) if isinstance(data, dict) else {}
            data["clientId"] = f"peer:{self.link.node_id}"
            data["clientName"] = self.display_name or self.link.node_id
        frame: dict[str, Any] = {"v": PROTOCOL_VERSION, "type": envelope.type, "data": data}
        if envelope.id is not None:
            frame["id"] = envelope.id
        try:
            self._inbox.put_nowait(frame)
        except asyncio.QueueFull:
            _LOGGER.warning("Peer session inbox overflow; closing.")
            self.close()

    def _reject(self, envelope: Envelope) -> None:
        async def notify() -> None:
            with logged_suppress(Exception):
                await self.link.send(
                    "control",
                    Envelope("error", {"error": "Frame not permitted for this node."}, envelope.id),
                )

        spawn_logged(notify())

    def close(self) -> None:
        with logged_suppress(asyncio.QueueFull):
            self._inbox.put_nowait(_CLOSED)
        if self._inbox.full():  # make room so the close marker is always seen
            with logged_suppress(asyncio.QueueEmpty):
                self._inbox.get_nowait()
            with logged_suppress(asyncio.QueueFull):
                self._inbox.put_nowait(_CLOSED)


class PeerSession:
    """One chat session per authenticated peer link."""

    def __init__(self, app: Any, link: PeerLink, display_name: str = "") -> None:
        self.socket = PeerSocket(app, link, display_name)
        self._session = WebSocketSession(self.socket)
        self._task: asyncio.Task[None] | None = None

    @property
    def session(self) -> WebSocketSession:
        return self._session

    def start(self) -> None:
        if self._task is None:
            self._task = spawn_logged(self._session.run())

    def feed(self, envelope: Envelope) -> None:
        self.socket.feed(envelope)

    async def stop(self) -> None:
        self.socket.close()
        task, self._task = self._task, None
        if task is not None:
            with logged_suppress(asyncio.CancelledError, Exception):
                await asyncio.wait_for(task, 5)
