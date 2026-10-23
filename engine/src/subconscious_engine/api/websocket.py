"""Camel-case-envelope WebSocket protocol for chat, tools, and approvals."""

import asyncio
import base64
import binascii
from collections.abc import Callable, Collection
from dataclasses import dataclass, field
import json
import re
from threading import RLock
import time
from typing import Any, Protocol
from uuid import uuid4

from pydantic_ai import Tool
from pydantic_ai.messages import BinaryContent, ToolCallPart
from sqlalchemy import func, select
from sqlalchemy.orm import selectinload
from starlette.websockets import WebSocket, WebSocketDisconnect

from subconscious_engine.agents import steering_source
from subconscious_engine.audio.realtime import (
    ASK_AGENT_TOOL, DEFAULT_TRANSCRIPTION_MODEL, RealtimeBridge, WebsocketsUpstream,
    realtime_url,
)
from subconscious_engine.audio.routes import capabilities_for
from subconscious_engine.approval import ApprovalConfig, classify_operation
from subconscious_engine.client_tools import (
    MAX_GROUPS_PER_CONNECTION, ClientToolCatalog, ClientToolDefinition, ClientToolError,
    ClientToolGroup, is_schema_registration, parse_group, tool_enabled,
)
from subconscious_engine.configuration.models import ModelConfig
from subconscious_engine.hive.authz import THIN_CLIENT
from subconscious_engine.locality import is_local_peer
from subconscious_engine.services.configured_tools import NAME_SEPARATOR, unique_name
from subconscious_engine.services.skills import (
    NONE_INDEX as NO_SKILLS_INDEX, SkillService, build_skills_index, read_skill_tool, select_skills,
)
from subconscious_engine.storage.models import ConversationThread, Message, Workspace, utc_now
from subconscious_engine.tools import (
    ContextAttachment,
    ContextFile,
    ToolContext,
    merge_tool_config,
)
import logging
from ..client_identity import (
    ClientIdentity, ClientInfo, build_client_info, is_local_address, parse_identity,
)
from ..connection_log import connection_event, connection_problem
from ..logging_setup import logged_suppress, spawn_logged
_LOG = logging.getLogger(__name__)


_MAX_CONTEXT_FILES = 20
_MAX_ATTACHMENTS = 5
_MAX_ATTACHMENT_BYTES = 2 * 1024 * 1024
_MAX_TOTAL_ATTACHMENT_BYTES = 8 * 1024 * 1024
_BINARY_MEDIA_TYPES = {
    "application/pdf",
    "application/msword",
    "application/vnd.ms-excel",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "text/plain",
    "text/csv",
    "text/html",
    "text/markdown",
    "image/jpeg",
    "image/png",
    "image/gif",
    "image/webp",
    "audio/wav",
    "audio/mpeg",
    "audio/ogg",
    "audio/flac",
    "audio/aiff",
    "audio/aac",
}
_UI_TOOL_NAMES = {
    "set_ui_theme_color",
    "set_ui_lighting_mode",
    "open_ui_workspace_file",
    "navigate_ui",
    "set_workspace_builtin_tool_enabled",
}
_UI_THEME_COLORS = {"device", "neutral", "blue", "purple", "green", "orange", "red"}
_UI_LIGHTING_MODES = {"device", "light", "dark"}
_UI_DESTINATIONS = {
    "workspaces", "threads", "files", "settings", "account",
    "show_chat", "hide_chat", "show_main", "hide_main",
    "show_context", "hide_context",
}
_CLIENT_TOOL_TIMEOUT_SECONDS = 60
_TASK_FRAMES = frozenset({"task.submit", "task.cancel", "thread.subscribe", "thread.unsubscribe"})


def _parse_context_file(value: Any, identifier: str) -> ContextFile | None:
    if not isinstance(value, dict):
        return None
    root_index = value.get("root_index")
    path = value.get("path")
    label = value.get("label")
    if not isinstance(root_index, int) or root_index < 0:
        return None
    if not isinstance(path, str) or not path or len(path) > 1_024:
        return None
    if not isinstance(label, str) or not label.strip():
        label = path
    return ContextFile(identifier, label[:1_024], root_index, path)


def _parse_file_context(
    value: Any,
) -> tuple[ContextFile | None, tuple[ContextFile, ...], tuple[ContextAttachment, ...]]:
    if value is None:
        return None, (), ()
    if not isinstance(value, dict):
        raise ValueError("file_context must be an object.")
    raw_active = value.get("active_file")
    active = _parse_context_file(raw_active, "active")
    if raw_active is not None and active is None:
        raise ValueError("file_context contains an invalid active file.")
    tagged_value = value.get("tagged_files", [])
    if not isinstance(tagged_value, list) or len(tagged_value) > _MAX_CONTEXT_FILES:
        raise ValueError(f"file_context supports at most {_MAX_CONTEXT_FILES} tagged files.")
    tagged: list[ContextFile] = []
    seen: set[tuple[int, str]] = set()
    for index, raw in enumerate(tagged_value, start=1):
        file = _parse_context_file(raw, f"tag-{index}")
        if file is None:
            raise ValueError("file_context contains an invalid tagged file.")
        key = (file.root_index, file.path)
        if key not in seen:
            seen.add(key)
            tagged.append(file)
    attachments_value = value.get("attachments", [])
    if not isinstance(attachments_value, list) or len(attachments_value) > _MAX_ATTACHMENTS:
        raise ValueError(f"file_context supports at most {_MAX_ATTACHMENTS} attachments.")
    attachments: list[ContextAttachment] = []
    total = 0
    for index, raw in enumerate(attachments_value, start=1):
        if not isinstance(raw, dict):
            raise ValueError("file_context contains an invalid attachment.")
        name = raw.get("name")
        media_type = raw.get("media_type")
        encoded = raw.get("data")
        if (not isinstance(name, str) or not name or len(name) > 255
                or "/" in name or "\\" in name or "\x00" in name):
            raise ValueError("Attachment names must be plain file names.")
        if not isinstance(media_type, str) or len(media_type) > 255:
            raise ValueError("Attachment media_type is invalid.")
        if not isinstance(encoded, str):
            raise ValueError("Attachment data must be base64 encoded.")
        try:
            content = base64.b64decode(encoded, validate=True)
        except (ValueError, binascii.Error) as error:
            raise ValueError("Attachment data is not valid base64.") from error
        if len(content) > _MAX_ATTACHMENT_BYTES:
            raise ValueError("An attachment exceeds the 2 MB limit.")
        total += len(content)
        if total > _MAX_TOTAL_ATTACHMENT_BYTES:
            raise ValueError("Attachments exceed the 8 MB total limit.")
        attachments.append(ContextAttachment(
            f"attachment-{index}", name, media_type or "application/octet-stream", content
        ))
    return active, tuple(tagged), tuple(attachments)


def _prompt_with_file_context(content: str, context: ToolContext) -> str:
    lines = ["Workspace context is available through the workspace_files tools."]
    if context.active_file is not None:
        lines.append(
            f"Active file: id=active, path={context.active_file.path!r}, "
            f"rootIndex={context.active_file.root_index}."
        )
    for file in context.context_files:
        lines.append(
            f"Tagged file: id={file.id}, path={file.path!r}, rootIndex={file.root_index}."
        )
    for attachment in context.attachments:
        lines.append(
            f"Attachment: id={attachment.id}, name={attachment.name!r}, "
            f"mediaType={attachment.media_type!r}."
        )
    return f"{content}\n\n<subconscious-file-context>\n" + "\n".join(lines) + "\n</subconscious-file-context>"


class ClientRegistry:
    def __init__(self) -> None:
        self._clients: dict[str, ClientInfo] = {}
        self._sessions: dict[str, Any] = {}
        self._listeners: set[Callable[[tuple[ClientInfo, ...]], None]] = set()
        self._lock = RLock()
    async def acquire(
        self,
        requested: str | None,
        *,
        label: str | None = None,
        identity: ClientIdentity | None = None,
        address: str | None = None,
        is_local: bool | None = None,
        node_name: str | None = None,
    ) -> str | None:
        with self._lock:
            identifier = requested or uuid4().hex
            if identifier in self._clients:
                return None
            self._clients[identifier] = build_client_info(
                identifier,
                identity or ClientIdentity(),
                label=label,
                address=address,
                is_local=address is None if is_local is None else is_local,
                node_name=node_name,
            )
            snapshot = self._snapshot_locked()
        self._notify(snapshot)
        return identifier
    async def release(self, identifier: str | None) -> None:
        if identifier is None:
            return
        with self._lock:
            if self._clients.pop(identifier, None) is None:
                return
            self._sessions.pop(identifier, None)
            snapshot = self._snapshot_locked()
        self._notify(snapshot)

    async def register_session(self, identifier: str, session: Any) -> None:
        with self._lock:
            if identifier in self._clients:
                self._sessions[identifier] = session

    async def broadcast(
        self,
        frame_type: str,
        data: dict[str, Any],
        *,
        exclude_client_id: str | None = None,
        exclude_client_ids: Collection[str] = (),
    ) -> None:
        with self._lock:
            recipients = tuple(
                session
                for identifier, session in self._sessions.items()
                if identifier != exclude_client_id and identifier not in exclude_client_ids
            )
        for session in recipients:
            with logged_suppress(Exception):
                await session._send(frame_type, data)

    async def broadcast_local(self, frame_type: str, data: dict[str, Any]) -> int:
        """Send to clients connected to this engine only (never hive peers).

        Returns how many sessions the frame reached.
        """
        with self._lock:
            recipients = tuple(
                session
                for session in self._sessions.values()
                if getattr(session.socket, "link", None) is None
            )
        delivered = 0
        for session in recipients:
            with logged_suppress(Exception):
                await session._send(frame_type, data)
                delivered += 1
        return delivered

    def subscribe(
        self, listener: Callable[[tuple[ClientInfo, ...]], None]
    ) -> Callable[[], None]:
        with self._lock:
            self._listeners.add(listener)
            snapshot = self._snapshot_locked()
        self._notify_listener(listener, snapshot)
        def unsubscribe() -> None:
            with self._lock:
                self._listeners.discard(listener)
        return unsubscribe
    def snapshot(self) -> tuple[ClientInfo, ...]:
        with self._lock:
            return self._snapshot_locked()
    def _snapshot_locked(self) -> tuple[ClientInfo, ...]:
        return tuple(sorted(
            self._clients.values(),
            key=lambda client: (client.display_name.casefold(), client.connected_at),
        ))
    def _notify(self, snapshot: tuple[ClientInfo, ...]) -> None:
        with self._lock:
            listeners = tuple(self._listeners)
        for listener in listeners:
            self._notify_listener(listener, snapshot)
    @staticmethod
    def _notify_listener(
        listener: Callable[[tuple[ClientInfo, ...]], None], snapshot: tuple[ClientInfo, ...]
    ) -> None:
        with logged_suppress(Exception):
            listener(snapshot)

class SessionTransport(Protocol):
    """What a chat session needs from its transport.

    ``WebSocket`` satisfies this, and so does the hive ``PeerTransport`` that
    carries the same frames over WebRTC data channels. ``receive_json`` raises
    ``WebSocketDisconnect`` when the transport closes.
    """

    app: Any

    async def accept(self) -> None: ...
    async def receive_json(self) -> Any: ...
    async def send_json(self, data: Any) -> None: ...


@dataclass(eq=False)
class _Turn:
    """One running agent turn. Several run at once, at most one per thread."""

    turn_id: str
    thread_uuid: str | None = None
    task: "asyncio.Task[None] | None" = None
    # Messages sent mid-turn: (frame id, message uuid, text), consumed by the agent.
    steering: list[tuple[str, str, str]] = field(default_factory=list)


@dataclass(eq=False)
class _RealtimeState:
    """A live realtime voice session and the thread its agent calls land in."""

    bridge: "RealtimeBridge"
    frame_id: str
    thread_uuid: str | None
    workspace_uuid: str | None
    agent_model_id: str | None


class WebSocketSession:
    def __init__(self, socket: SessionTransport) -> None:
        self.socket = socket
        self.app = socket.app
        self.client_id: str | None = None
        # Every running chat turn on this connection; threads run independently.
        self.turns: list[_Turn] = []
        self.realtime: _RealtimeState | None = None
        self.pending: dict[str, tuple[str, asyncio.Future[bool]]] = {}
        self.pending_client_tools: dict[
            str, tuple[str, asyncio.Future[dict[str, Any]]]
        ] = {}
        self.send_lock = asyncio.Lock()
        self.client_tools: dict[str, dict[str, Any]] = {}
        # Schema-bearing client tool groups registered on this connection.
        self.client_tool_groups: dict[str, ClientToolGroup] = {}
        # Model-visible client tool name -> declared operation (for approval requests).
        self.client_tool_operations: dict[str, str] = {}
        self.client_name: str | None = None

    def _transport_label(self) -> str:
        link = getattr(self.socket, "link", None)
        if link is None:
            return "websocket"
        return f"peer-{getattr(link, 'tier', 'link')}"

    def _remote_label(self) -> str | None:
        peer = getattr(self.socket, "client", None)
        host = getattr(peer, "host", None)
        port = getattr(peer, "port", None)
        if isinstance(host, str) and isinstance(port, int):
            return f"{host}:{port}"
        return host if isinstance(host, str) else None

    async def run(self) -> None:
        started = time.monotonic()
        await self.socket.accept()
        # Why the session ended, for the connection log. Normal closes are INFO;
        # anything else is a WARNING so a drop is never silent.
        outcome = "closed"
        abnormal = False
        try:
            while True:
                frame = await self.socket.receive_json()
                await self._handle(frame)
        except WebSocketDisconnect as error:
            code = getattr(error, "code", None)
            _LOG.debug("api.websocket.WebSocketSession.run: transport closed (code=%s)", code)
            outcome = f"disconnect code={code}"
            abnormal = code not in (None, 1000, 1001)
        except (json.JSONDecodeError, ValueError) as error:
            outcome = f"bad frame ({type(error).__name__}: {error})"
            abnormal = True
            _LOG.warning("api.websocket.WebSocketSession.run: handled (json.JSONDecodeError, ValueError); continuing with fallback", exc_info=True)
        except asyncio.CancelledError:
            outcome = "cancelled (session stopped or engine shutting down)"
            abnormal = True
            raise
        except Exception as error:
            outcome = f"error ({type(error).__name__}: {error})"
            abnormal = True
            _LOG.exception("api.websocket.WebSocketSession.run: unexpected error ending the session")
            raise
        finally:
            fields = {
                "client_id": self.client_id,
                "transport": self._transport_label(),
                "remote": self._remote_label(),
                "duration_s": f"{time.monotonic() - started:.1f}",
                "reason": outcome,
            }
            if abnormal:
                connection_problem("client.dropped", **fields)
            else:
                connection_event("client.disconnected", **fields)
            await self._stop_realtime()
            await self._stop_active_turn()
            for _, future in self.pending.values():
                future.cancel()
            for _, future in self.pending_client_tools.values():
                future.cancel()
            self.client_tool_groups.clear()
            catalog = self._client_catalog()
            if catalog is not None:
                catalog.disconnect(self)
            manager = self._tasks()
            if manager is not None:
                manager.session_closed(self)
            await self.app.state.client_registry.release(self.client_id)

    async def _handle(self, frame: Any) -> None:
        if not isinstance(frame, dict) or not isinstance(frame.get("type"), str):
            await self._error("Missing 'type' field")
            return
        frame_type = frame["type"]
        raw_data = frame.get("data")
        data: dict[str, Any] = raw_data if isinstance(raw_data, dict) else {}
        turn_id = frame.get("id") if isinstance(frame.get("id"), str) else None
        if frame_type == "client.hello":
            await self._hello(data)
        elif frame_type == "ping":
            await self._send("pong", None)
        elif frame_type == "chat.send":
            await self._start_turn(turn_id or uuid4().hex, data)
        elif frame_type == "realtime.start":
            await self._realtime_start(turn_id or uuid4().hex, data)
        elif frame_type == "realtime.audio":
            if self.realtime is not None and isinstance(data.get("audio"), str):
                await self.realtime.bridge.send_audio(data["audio"])
        elif frame_type == "realtime.interrupt":
            if self.realtime is not None:
                await self.realtime.bridge.interrupt()
        elif frame_type == "realtime.stop":
            await self._stop_realtime()
        elif frame_type == "chat.notification":
            await self._create_notification(turn_id or uuid4().hex, data)
        elif frame_type == "chat.cancel":
            await self._cancel(turn_id or data.get("turn_id"), data.get("thread_uuid"))
        elif frame_type == "tool.approval.response":
            await self._approval(turn_id, data)
        elif frame_type == "tool.register":
            await self._register_tools(data)
        elif frame_type == "tool.unregister":
            group = data.get("group")
            identifier = data.get("id")
            if isinstance(group, str):
                self._remove_group(group)
            elif isinstance(identifier, str):
                self.client_tools.pop(identifier, None)
        elif frame_type == "client.tool.result":
            await self._client_tool_result(turn_id, data)
        elif frame_type in {"profile.set", "tool.result"}:
            return
        elif frame_type in _TASK_FRAMES and self._tasks() is not None:
            await self._tasks().handle_frame(self, frame_type, data, turn_id)
        else:
            await self._error(f"Unknown frame type: {frame_type}")

    async def _hello(self, data: dict[str, Any]) -> None:
        requested = data.get("clientId") if isinstance(data.get("clientId"), str) else None
        if requested is not None and requested == self.client_id:
            # The same session greeted again (a client reconnecting over a link that is
            # still up). The identity is already ours, so acknowledge instead of
            # rejecting it as "already in use" by ourselves.
            await self._send(
                "client.hello.ack", {"clientId": requested, "local": is_local_peer(self.socket)}
            )
            return
        client_name = data.get("clientName") if isinstance(data.get("clientName"), str) else None
        peer = getattr(self.socket, "client", None)
        peer_host = getattr(peer, "host", None)
        peer_port = getattr(peer, "port", None)
        peer_label = (
            f"{peer_host}:{peer_port}"
            if isinstance(peer_host, str) and isinstance(peer_port, int)
            else peer_host if isinstance(peer_host, str) else None
        )
        # Identity comes from the connection itself, never from X-Forwarded-For.
        identity = parse_identity(getattr(self.socket, "query_params", None), data)
        is_peer = getattr(self.socket, "link", None) is not None
        host = peer_host if isinstance(peer_host, str) else None
        identifier = await self.app.state.client_registry.acquire(
            requested,
            label=client_name or requested or peer_label,
            identity=identity,
            address=None if is_peer else host,
            is_local=False if is_peer else is_local_address(host),
            node_name=(getattr(self.socket, "display_name", "") or client_name) if is_peer else None,
        )
        if identifier is None:
            connection_problem(
                "client.rejected",
                reason="Client_ID already in use by an active connection",
                requested_id=requested,
                name=client_name,
                transport=self._transport_label(),
                remote=self._remote_label(),
            )
            await self._send("client.hello.reject", {"reason": "Client_ID already in use by an active connection."})
            return
        await self.app.state.client_registry.release(self.client_id)
        self.client_id = identifier
        self.client_name = client_name or identifier
        connection_event(
            "client.connected",
            client_id=identifier,
            name=client_name,
            transport=self._transport_label(),
            remote=peer_label,
            local=False if is_peer else is_local_address(host),
        )
        await self.app.state.client_registry.register_session(identifier, self)
        await self._send(
            "client.hello.ack", {"clientId": identifier, "local": is_local_peer(self.socket)}
        )

    @property
    def active_turn(self) -> "asyncio.Task[None] | None":
        """Most recently started turn that is still running (compatibility view)."""
        running = [t for t in self.turns if t.task is not None and not t.task.done()]
        return running[-1].task if running else None

    @property
    def active_turn_id(self) -> str | None:
        running = [t for t in self.turns if t.task is not None and not t.task.done()]
        return running[-1].turn_id if running else None

    def _turn_for_id(self, turn_id: str) -> "_Turn | None":
        return next((t for t in self.turns if t.turn_id == turn_id), None)

    def _turn_for_thread(self, thread_uuid: str) -> "_Turn | None":
        return next((t for t in self.turns if t.thread_uuid == thread_uuid
                     and t.task is not None and not t.task.done()), None)

    async def _start_turn(self, turn_id: str, data: dict[str, Any]) -> None:
        thread = data.get("thread_uuid")
        content = data.get("content")
        if self._turn_for_id(turn_id) is not None:
            await self._error("A chat turn with this id is already running.")
            return
        if isinstance(thread, str):
            running = self._turn_for_thread(thread)
            if running is not None:
                # The thread is busy: guide the running agent instead of starting another.
                if isinstance(content, str) and content.strip():
                    await self._steer(running, turn_id, thread, content)
                else:
                    await self._error("chat.send requires content")
                return
        turn = _Turn(turn_id, thread if isinstance(thread, str) else None)
        self.turns.append(turn)
        turn.task = spawn_logged(self._turn_loop(turn, data))

    async def _steer(self, turn: _Turn, frame_id: str, thread_uuid: str, content: str) -> None:
        """Accept a message while the agent is working: store it and queue it for the run."""
        async with self.app.state.database.session() as session:
            thread = await session.scalar(select(ConversationThread).where(
                ConversationThread.uuid == thread_uuid, ConversationThread.deleted_at.is_(None)))
            if thread is None:
                await self._send("chat.error", {"thread_uuid": thread_uuid,
                                                "error": f"Thread '{thread_uuid}' not found."}, frame_id)
                return
            message = Message(uuid=str(uuid4()), thread_id=thread.id, role="user", content=content)
            thread.updated_at = utc_now()
            session.add(message)
            await session.commit()
        await self._publish_message(message, thread_uuid)
        turn.steering.append((frame_id, message.uuid, content))
        await self._send("chat.steered", {"thread_uuid": thread_uuid, "message_uuid": message.uuid}, frame_id)

    async def _drain_steering(self, turn: _Turn) -> list[str]:
        """Called before each model request; each consumed message gets its terminal frame."""
        taken, turn.steering = turn.steering, []
        for frame_id, _, _ in taken:
            await self._send("chat.done", {"thread_uuid": turn.thread_uuid, "steered": True}, frame_id)
        return [text for _, _, text in taken]

    async def _turn_loop(self, turn: _Turn, data: dict[str, Any]) -> None:
        """Run a turn, then a follow-up turn for messages that arrived too late to steer it."""
        token = steering_source.set(lambda: self._drain_steering(turn))
        message_uuid: str | None = None
        try:
            while True:
                extra = {"client_msg_uuid": message_uuid} if message_uuid else {}
                outcome, error = await self._run_turn(turn.turn_id, data, **extra)
                leftovers, turn.steering = turn.steering, []
                if not leftovers:
                    return
                thread_uuid = turn.thread_uuid
                if outcome != "done":
                    for frame_id, _, _ in leftovers:
                        if outcome == "cancelled":
                            await self._send("chat.cancelled", {"thread_uuid": thread_uuid}, frame_id)
                        else:
                            await self._send("chat.error", {"thread_uuid": thread_uuid,
                                                            "error": error or "Turn failed."}, frame_id)
                    return
                for frame_id, _, _ in leftovers[:-1]:
                    await self._send("chat.done", {"thread_uuid": thread_uuid, "steered": True}, frame_id)
                turn.turn_id, message_uuid, text = leftovers[-1]
                data = {k: v for k, v in data.items() if k not in {"workspace_uuid", "file_context"}}
                data.update(thread_uuid=thread_uuid, content=text)
        finally:
            steering_source.reset(token)
            if turn in self.turns:
                self.turns.remove(turn)

    async def _cancel(self, turn_id: Any, thread_uuid: Any = None) -> None:
        turn = self._turn_for_id(turn_id) if isinstance(turn_id, str) else None
        if turn is None and isinstance(thread_uuid, str):
            turn = self._turn_for_thread(thread_uuid)
        if turn is not None:
            await self._stop_turn(turn)
        elif isinstance(turn_id, str) and self._tasks() is not None:
            await self._tasks().handle_frame(self, "task.cancel", {"task_id": turn_id}, turn_id)

    def _tasks(self) -> Any:
        return getattr(self.app.state, "task_manager", None)

    async def _realtime_start(self, frame_id: str, data: dict[str, Any]) -> None:
        """Open a realtime voice session whose agent calls run through the normal graph."""
        await self._stop_realtime()
        model_id = data.get("model_id")
        thread = data.get("thread_uuid") if isinstance(data.get("thread_uuid"), str) else None
        workspace = data.get("workspace_uuid") if isinstance(data.get("workspace_uuid"), str) else None
        agent_model = data.get("agent_model_id") if isinstance(data.get("agent_model_id"), str) else None

        async def fail(message: str) -> None:
            await self._send("realtime.error", {"error": message}, frame_id)

        if not isinstance(model_id, str) or (thread is None) == (workspace is None):
            await fail("realtime.start requires model_id and exactly one of thread_uuid or workspace_uuid")
            return
        store = self.app.state.model_configuration_store
        config = await store.resolve(model_id)
        if config is None:
            await fail(f"Model configuration '{model_id}' was not found.")
            return
        if not (await capabilities_for(self.app, config)).supports("realtime"):
            await fail(f"Model '{model_id}' is not marked as supporting realtime speech.")
            return
        if config.provider.casefold().replace("_", "-") not in {"openai", "openai-compatible", "azure-openai"}:
            await fail(f"Realtime speech is not available for the '{config.provider}' provider yet.")
            return
        connector = getattr(self.app.state, "realtime_connector", None)
        try:
            if connector is not None:
                upstream = await connector(config)
            else:
                upstream = await WebsocketsUpstream.connect(
                    realtime_url(config.base_url, config.model), config.api_key
                )
        except Exception as error:
            _LOG.exception("api.websocket.WebSocketSession._realtime_start: handled Exception; continuing with fallback")
            await fail(f"Could not connect to the realtime service: {error}")
            return
        extra = config.extra or {}
        voice = extra.get("voice") if isinstance(extra.get("voice"), str) else "marin"
        configured_transcription = extra.get("transcription_model")
        # User transcripts need a transcription model; only assume one on OpenAI itself.
        transcription_model: str | None = (
            configured_transcription if isinstance(configured_transcription, str) and configured_transcription
            else DEFAULT_TRANSCRIPTION_MODEL
            if not config.base_url or "api.openai.com" in config.base_url
            else None
        )

        async def emit(frame_type: str, payload: dict[str, Any]) -> None:
            await self._send(frame_type, payload, frame_id)
            if frame_type == "realtime.stopped" and self.realtime is not None \
                    and self.realtime.frame_id == frame_id:
                self.realtime = None

        state = _RealtimeState(None, frame_id, thread, workspace, agent_model)  # type: ignore[arg-type]

        async def call_function(name: str, arguments: dict[str, Any]) -> str:
            if name != ASK_AGENT_TOOL["name"]:
                raise ValueError(f"Unknown function '{name}'.")
            request = arguments.get("request")
            if not isinstance(request, str) or not request.strip():
                raise ValueError("ask_agent needs a request.")
            return await self._realtime_ask_agent(state, request.strip())

        state.bridge = RealtimeBridge(
            upstream, emit, call_function, model=config.model, voice=voice,
            transcription_model=transcription_model,
        )
        self.realtime = state
        await state.bridge.start()
        await self._send("realtime.started", {
            "model": config.model, "thread_uuid": thread, "sample_rate": 24000,
        }, frame_id)

    async def _realtime_ask_agent(self, state: _RealtimeState, request: str) -> str:
        """Run one agent turn for the voice session and return the answer text."""
        if state.thread_uuid is not None:
            running = self._turn_for_thread(state.thread_uuid)
            if running is not None:
                await self._steer(running, uuid4().hex, state.thread_uuid, request)
                return "I passed that to the agent, which is already working on this."
        turn = _Turn(uuid4().hex, state.thread_uuid, asyncio.current_task())
        self.turns.append(turn)
        payload: dict[str, Any] = {"content": request}
        if state.thread_uuid is not None:
            payload["thread_uuid"] = state.thread_uuid
        else:
            payload["workspace_uuid"] = state.workspace_uuid
        if state.agent_model_id is not None:
            payload["model_id"] = state.agent_model_id
        token = steering_source.set(lambda: self._drain_steering(turn))
        try:
            outcome, error = await self._run_turn(turn.turn_id, payload)
        finally:
            steering_source.reset(token)
            if turn in self.turns:
                self.turns.remove(turn)
        if outcome != "done":
            raise RuntimeError(error or "The agent could not finish that request.")
        if state.thread_uuid is None and turn.thread_uuid is not None:
            state.thread_uuid = turn.thread_uuid
            await self._send("realtime.thread", {"thread_uuid": turn.thread_uuid}, state.frame_id)
        return await self._last_assistant_text(state.thread_uuid) or "Done."

    async def _last_assistant_text(self, thread_uuid: str | None) -> str:
        if thread_uuid is None:
            return ""
        async with self.app.state.database.session() as session:
            thread = await session.scalar(
                select(ConversationThread).where(ConversationThread.uuid == thread_uuid))
            if thread is None:
                return ""
            message = await session.scalar(select(Message).where(
                Message.thread_id == thread.id, Message.role == "assistant",
                Message.deleted_at.is_(None),
            ).order_by(Message.hlc.desc(), Message.created_at.desc()).limit(1))
            return message.content if message is not None else ""

    async def _stop_realtime(self) -> None:
        state, self.realtime = self.realtime, None
        if state is not None:
            await state.bridge.stop()

    async def _stop_turn(self, turn: _Turn) -> None:
        task = turn.task
        if task is not None:
            if not task.done():
                task.cancel()
            with logged_suppress(asyncio.CancelledError, Exception):
                await task
        if turn in self.turns:
            self.turns.remove(turn)

    async def _stop_active_turn(self) -> None:
        for turn in list(self.turns):
            await self._stop_turn(turn)

    async def _create_notification(
        self, notification_id: str, data: dict[str, Any]
    ) -> None:
        content = data.get("content")
        thread_uuid = data.get("thread_uuid")
        if (
            not isinstance(content, str)
            or not content.strip()
            or not isinstance(thread_uuid, str)
            or not thread_uuid
        ):
            await self._send(
                "chat.notification.error",
                {"error": "chat.notification requires non-empty content and thread_uuid."},
                notification_id,
            )
            return
        try:
            async with self.app.state.database.session() as session:
                thread = await session.scalar(
                    select(ConversationThread).where(
                        ConversationThread.uuid == thread_uuid
                    )
                )
                if thread is None:
                    await self._send(
                        "chat.notification.error",
                        {"error": f"Thread '{thread_uuid}' not found."},
                        notification_id,
                    )
                    return
                message = Message(
                    uuid=str(uuid4()),
                    thread_id=thread.id,
                    role="system",
                    content=content,
                )
                thread.updated_at = utc_now()
                session.add(message)
                await session.commit()
            await self._publish_message(message, thread_uuid)
            await self._send(
                "chat.notification.done",
                {"thread_uuid": thread_uuid, "message_uuid": message.uuid},
                notification_id,
            )
        except Exception as error:
            _LOG.exception("api.websocket.WebSocketSession._create_notification: handled Exception; continuing with fallback")
            await self._send(
                "chat.notification.error", {"error": str(error)}, notification_id
            )

    async def _approval(self, turn_id: str | None, data: dict[str, Any]) -> None:
        approval_id = data.get("approval_id")
        decision = data.get("decision")
        if not isinstance(approval_id, str) or not isinstance(decision, str):
            await self._error("tool.approval.response requires approval_id and decision.")
            return
        pending = self.pending.get(approval_id)
        if pending is None:
            remote = getattr(self.app.state, "remote_tools", None)
            # A hive peer must never answer the prompt for its own remote tool call.
            if (
                remote is not None
                and getattr(self.socket, "link", None) is None
                and remote.handle_approval(approval_id, decision)
            ):
                return
            manager = self._tasks()
            if manager is not None and await manager.handle_approval(self, turn_id, approval_id, decision):
                return
            await self._error("Approval request was not found or has already completed.")
        elif turn_id is not None and turn_id != pending[0]:
            await self._error("Approval response does not belong to this chat turn.")
        elif not pending[1].done():
            pending[1].set_result(decision.casefold() == "approve")

    def _client_catalog(self) -> ClientToolCatalog | None:
        catalog = getattr(self.app.state, "client_tool_catalog", None)
        return catalog if isinstance(catalog, ClientToolCatalog) else None

    def _builtin_catalog(self) -> dict[str, list[dict[str, str]]]:
        """Built-in groups plus remembered client groups (what the tools settings can toggle)."""
        registry = getattr(self.app.state, "tool_registry", None)
        merged: dict[str, list[dict[str, str]]] = dict(registry.catalog()) if registry is not None else {}
        client = self._client_catalog()
        if client is not None:
            for name, items in client.catalog().items():
                merged.setdefault(name, items)
        return merged

    async def _register_tools(self, data: dict[str, Any]) -> None:
        if not is_schema_registration(data):
            tools = data.get("tools", [])
            for tool in tools if isinstance(tools, list) else []:
                if (isinstance(tool, dict)
                        and isinstance(tool.get("id"), str)
                        and tool["id"] in _UI_TOOL_NAMES):
                    self.client_tools[tool["id"]] = {"id": tool["id"]}
            return
        link = getattr(self.socket, "link", None)
        # Engine nodes (HIVE_PEER) never register tools. A thin client link is the user's own
        # device (browser extension): its tools still need approval and only it answers them.
        if link is not None and getattr(link, "role", None) != THIN_CLIENT:
            await self._error("Hive peers cannot register client tools with schemas.")
            return
        registry = getattr(self.app.state, "tool_registry", None)
        reserved = {spec.slug for spec in getattr(registry, "specs", ())}
        try:
            group = parse_group(data, reserved=reserved)
            if group.tools and group.group not in self.client_tool_groups \
                    and len(self.client_tool_groups) >= MAX_GROUPS_PER_CONNECTION:
                raise ClientToolError(
                    f"a connection can register at most {MAX_GROUPS_PER_CONNECTION} tool groups.")
        except ClientToolError as error:
            _LOG.warning("api.websocket._register_tools: rejected client tool registration: %s", error)
            await self._error(f"tool.register rejected: {error}")
            return
        if not group.tools:
            self._remove_group(group.group)
            return
        self.client_tool_groups[group.group] = group
        catalog = self._client_catalog()
        if catalog is not None:
            catalog.register(self, group)

    def _remove_group(self, name: str) -> None:
        self.client_tool_groups.pop(name, None)
        catalog = self._client_catalog()
        if catalog is not None:
            catalog.unregister(self, name)

    def _client_group_tools(
        self, turn_id: str, tools_raw: str | None, approval: ApprovalConfig,
        reserved: Collection[str],
    ) -> list[Tool[Any]]:
        """Model tools for the registered client groups, honouring ``tools_config`` and approval."""
        try:
            parsed = json.loads(tools_raw) if tools_raw else {}
        except json.JSONDecodeError:
            _LOG.warning("api.websocket._client_group_tools: invalid tools_config ignored", exc_info=True)
            parsed = {}
        config: dict[str, Any] = parsed if isinstance(parsed, dict) else {}
        used = set(reserved) | set(self.client_tools)
        operations: dict[str, str] = {}
        tools: list[Tool[Any]] = []
        client = self.client_name or "client"
        for group in self.client_tool_groups.values():
            for definition in group.tools:
                if not tool_enabled(config, group.group, definition.id):
                    continue
                base = re.sub(r"[^A-Za-z0-9_]", "_", f"{group.group}{NAME_SEPARATOR}{definition.id}")
                name = unique_name(base, used)
                tool: Tool[Any] = Tool.from_schema(
                    self._client_tool_function(turn_id, group.group, definition),
                    name=name,
                    description=f"[{group.title} via {client}] {definition.description}".strip(),
                    json_schema=definition.input_schema,
                )
                tool.requires_approval = approval.requires_operation(definition.approval_operation)
                operations[name] = definition.operation
                tools.append(tool)
        self.client_tool_operations = operations
        return tools

    def _client_tool_function(
        self, turn_id: str, group: str, definition: ClientToolDefinition
    ) -> Callable[..., Any]:
        async def call(**arguments: Any) -> Any:
            try:
                return await self._request_client_tool(
                    turn_id, definition.id, arguments, group=group,
                    timeout=definition.timeout_seconds,
                )
            except asyncio.TimeoutError:
                raise RuntimeError(
                    f"The client did not answer tool '{definition.id}' in time."
                ) from None

        return call

    async def _client_tool_result(
        self, turn_id: str | None, data: dict[str, Any]
    ) -> None:
        request_id = data.get("request_id")
        ok = data.get("ok")
        if not isinstance(request_id, str) or not isinstance(ok, bool):
            await self._error("client.tool.result requires request_id and boolean ok.")
            return
        pending = self.pending_client_tools.get(request_id)
        if pending is None:
            await self._error("Client tool request was not found or has already completed.")
            return
        if turn_id is None or turn_id != pending[0]:
            await self._error("Client tool result does not belong to this chat turn.")
            return
        if not pending[1].done():
            pending[1].set_result(data)

    async def _request_client_tool(
        self, turn_id: str, tool_name: str, arguments: dict[str, Any], *,
        group: str | None = None, timeout: float | None = None,
    ) -> Any:
        request_id = uuid4().hex
        future: asyncio.Future[dict[str, Any]] = \
            asyncio.get_running_loop().create_future()
        self.pending_client_tools[request_id] = (turn_id, future)
        try:
            payload: dict[str, Any] = {
                "request_id": request_id,
                "tool_name": tool_name,
                "arguments": arguments,
            }
            if group is not None:
                payload["group"] = group
            await self._send("client.tool.request", payload, turn_id)
            response = await asyncio.wait_for(
                future, timeout=timeout or _CLIENT_TOOL_TIMEOUT_SECONDS
            )
            if response.get("ok") is not True:
                error = response.get("error")
                raise RuntimeError(
                    error if isinstance(error, str) else "The UI tool failed."
                )
            return response.get("result")
        finally:
            self.pending_client_tools.pop(request_id, None)

    def _ui_tools(self, turn_id: str) -> list[Tool[Any]]:
        async def set_ui_theme_color(color: str) -> Any:
            normalized = color.strip().casefold()
            if normalized not in _UI_THEME_COLORS:
                raise ValueError(
                    "color must be device, neutral, blue, purple, green, orange, or red."
                )
            return await self._request_client_tool(
                turn_id, "set_ui_theme_color", {"color": normalized}
            )

        async def set_ui_lighting_mode(mode: str) -> Any:
            normalized = mode.strip().casefold()
            if normalized not in _UI_LIGHTING_MODES:
                raise ValueError("mode must be device, light, or dark.")
            return await self._request_client_tool(
                turn_id, "set_ui_lighting_mode", {"mode": normalized}
            )

        async def open_ui_workspace_file(root_index: int, path: str) -> Any:
            if root_index < 0 or not path or len(path) > 1_024:
                raise ValueError("A non-negative root_index and relative path are required.")
            return await self._request_client_tool(
                turn_id,
                "open_ui_workspace_file",
                {"root_index": root_index, "path": path},
            )

        async def navigate_ui(destination: str) -> Any:
            normalized = destination.strip().casefold()
            if normalized not in _UI_DESTINATIONS:
                raise ValueError(
                    "destination must be a sidebar section or a show/hide panel action."
                )
            return await self._request_client_tool(
                turn_id, "navigate_ui", {"destination": normalized}
            )

        async def set_workspace_builtin_tool_enabled(
            group: str, enabled: bool, tool: str = ""
        ) -> Any:
            normalized_group = group.strip()
            normalized_tool = tool.strip()
            catalog = self._builtin_catalog()
            if normalized_group not in catalog:
                raise ValueError("group is not a registered built-in tool group.")
            if normalized_tool and normalized_tool not in {
                item["name"] for item in catalog[normalized_group]
            }:
                raise ValueError("tool is not registered in the selected group.")
            return await self._request_client_tool(
                turn_id,
                "set_workspace_builtin_tool_enabled",
                {
                    "group": normalized_group,
                    "enabled": enabled,
                    "tool": normalized_tool,
                },
            )

        definitions = {
            "set_ui_theme_color": (
                set_ui_theme_color,
                "Change the application's accent theme color.",
            ),
            "set_ui_lighting_mode": (
                set_ui_lighting_mode,
                "Change the application lighting mode.",
            ),
            "open_ui_workspace_file": (
                open_ui_workspace_file,
                "Open a workspace-relative file in the file previewer.",
            ),
            "navigate_ui": (
                navigate_ui,
                "Navigate to a sidebar section or show/hide a dashboard panel.",
            ),
            "set_workspace_builtin_tool_enabled": (
                set_workspace_builtin_tool_enabled,
                "Enable or disable a catalog-known built-in tool group or tool for the active workspace.",
            ),
        }
        return [
            Tool(
                definitions[name][0],
                name=name,
                description=definitions[name][1],
                requires_approval=True,
            )
            for name in definitions
            if name in self.client_tools
        ]

    async def _run_turn(
        self,
        turn_id: str,
        data: dict[str, Any],
        *,
        client_msg_uuid: str | None = None,
        thread_uuid_hint: str | None = None,
    ) -> tuple[str, str | None]:
        """Run one chat turn. Returns ``(outcome, error)`` for task bookkeeping.

        ``client_msg_uuid`` makes the user message idempotent (a task retried after a
        reconnect never duplicates it); ``thread_uuid_hint`` is the uuid a new thread
        must take so a task can name its thread before the executor creates it.
        """
        thread_uuid = ""
        oauth_broker = getattr(self.app.state, "oauth_broker", None)
        if oauth_broker is not None:
            async def oauth_notify(frame_type: str, payload: dict[str, Any]) -> None:
                # A sign-in card (or its resolution) for this chat; thread_uuid is filled in once known.
                if frame_type == "oauth.request":
                    payload = {**payload, "thread_uuid": thread_uuid}
                await self._send(frame_type, payload, turn_id)

            server = (getattr(self.socket, "scope", None) or {}).get("server")
            if server and server[1]:
                oauth_broker.set_port(server[1], overwrite=False)  # loopback redirect fallback
            oauth_broker.attach(turn_id, oauth_notify, self.client_id)
        try:
            created_thread = False
            content = data.get("content")
            requested_thread = data.get("thread_uuid")
            requested_workspace = data.get("workspace_uuid")
            model_id = data.get("model_id")
            active_file, tagged_files, attachments = _parse_file_context(
                data.get("file_context")
            )
            if not isinstance(content, str) or (isinstance(requested_thread, str) == isinstance(requested_workspace, str)):
                message = "chat.send requires content and exactly one of thread_uuid or workspace_uuid"
                await self._error(message)
                return "failed", message
            async with self.app.state.database.session() as session:
                if isinstance(requested_thread, str):
                    thread = await session.scalar(select(ConversationThread).options(
                        selectinload(ConversationThread.workspace)).where(
                        ConversationThread.uuid == requested_thread, ConversationThread.deleted_at.is_(None)))
                    if thread is None:
                        message = f"Thread '{requested_thread}' not found."
                        await self._send("chat.error", {"thread_uuid": requested_thread, "error": message}, turn_id)
                        return "failed", message
                    workspace = thread.workspace
                else:
                    workspace = await session.scalar(select(Workspace).where(
                        Workspace.uuid == requested_workspace, Workspace.deleted_at.is_(None)))
                    if workspace is None:
                        message = f"Workspace '{requested_workspace}' not found."
                        await self._send("chat.error", {"thread_uuid": "", "error": message}, turn_id)
                        return "failed", message
                    thread = None
                    if thread_uuid_hint:  # a retried task reuses the thread it already created
                        thread = await session.scalar(select(ConversationThread).where(
                            ConversationThread.uuid == thread_uuid_hint,
                            ConversationThread.workspace_id == workspace.id,
                            ConversationThread.deleted_at.is_(None)))
                    if thread is None:
                        now = utc_now()
                        thread = ConversationThread(uuid=thread_uuid_hint or str(uuid4()), workspace_id=workspace.id,
                            title=self._title(content), default_model_id=None, created_at=now, updated_at=now)
                        session.add(thread)
                        await session.flush()
                        created_thread = True
                thread_uuid = thread.uuid
                running = self._turn_for_id(turn_id)
                if running is not None:
                    running.thread_uuid = thread_uuid
                # Echo is a dev-only test model: production never defaults to it or serves it.
                dev_models = getattr(self.app.state, "dev_models", False) is True

                def usable(candidate: object) -> str | None:
                    if not isinstance(candidate, str) or not candidate:
                        return None
                    return candidate if dev_models or candidate.casefold() != "echo" else None

                selected_model = model_id if isinstance(model_id, str) else (
                    usable(thread.default_model_id) or usable(workspace.default_model_id)
                    or ("echo" if dev_models else None))
                if selected_model is None:
                    message = "No model is configured. Add a model in Settings, then try again."
                    await self._send("chat.error", {"thread_uuid": thread_uuid, "error": message}, turn_id)
                    return "failed", message
                config = ModelConfig(id="echo", provider="subconscious", model="echo") \
                    if dev_models and selected_model.casefold() == "echo" \
                    else await self.app.state.model_configuration_store.resolve(selected_model)
                if config is None:
                    message = f"Model configuration '{selected_model}' was not found."
                    await self._send("chat.error", {"thread_uuid": thread_uuid, "error": message}, turn_id)
                    return "failed", message
                history_query = select(Message).where(Message.thread_id == thread.id, Message.deleted_at.is_(None))
                if client_msg_uuid:
                    history_query = history_query.where(Message.uuid != client_msg_uuid)
                prior = (await session.scalars(history_query.order_by(
                    Message.hlc, func.coalesce(Message.origin_node_id, ""), Message.uuid))).all()
                history = [(message.role, message.content) for message in prior
                           if message.role in {"user", "assistant", "system"}]
                thread.default_model_id = config.id
                if not thread.title:
                    thread.title = self._title(content)
                thread.updated_at = utc_now()
                user_message = await session.scalar(select(Message).where(Message.uuid == client_msg_uuid)) \
                    if client_msg_uuid else None
                publish_user_message = user_message is None
                if user_message is None:
                    user_message = Message(uuid=client_msg_uuid or str(uuid4()), thread_id=thread.id,
                                           role="user", content=content)
                    session.add(user_message)
                await session.commit()
                if created_thread:
                    await self._publish_thread_created(thread, workspace)
                if publish_user_message:
                    await self._publish_message(user_message, thread_uuid)
                tools_enabled = data.get("tools_enabled", True) is not False
                tools = []
                # The skills index goes into the prompt as a non-empty string; the full text is
                # fetched on demand by the read_skill tool (only offered when skills exist).
                skills_index = NO_SKILLS_INDEX
                tool_context = ToolContext(
                    self.app.state.rag_service,
                    self.app.state.database,
                    workspace.uuid,
                    thread.id,
                    tagged_files,
                    active_file,
                    attachments,
                )
                if tools_enabled:
                    tools_raw = merge_tool_config(workspace.tools_config, thread.tools_config)
                    approval = ApprovalConfig.from_json(
                        thread.approval_config or workspace.approval_config
                    )
                    tools = self.app.state.tool_registry.tools_for_config(
                        tools_raw,
                        tool_context,
                        approval,
                    )
                    remote_toolset = getattr(self.app.state, "remote_toolset", None)
                    if remote_toolset is not None:
                        # Opt-in per workspace/thread (tools_config "remote"); empty otherwise.
                        tools.extend(await remote_toolset.tools_for_turn(
                            tools_raw, task_id=turn_id, workspace_uuid=workspace.uuid,
                            approval=approval))
                    configured_tools = getattr(self.app.state, "configured_tools", None)
                    if configured_tools is not None:
                        # User-configured MCP servers and CLI tools; a broken one is skipped.
                        try:
                            tools.extend(await configured_tools.tools_for_turn(
                                approval, reserved={tool.name for tool in tools}))
                        except Exception:
                            _LOG.exception("api.websocket._run_turn: configured tools unavailable this turn")
                    management = getattr(self.app.state, "tool_management", None)
                    if management is not None:
                        # The assistant can configure its own tools/skills; approval is forced on.
                        tools.extend(management.tools(approval, reserved={tool.name for tool in tools}))
                    try:
                        selected_skills = select_skills(
                            await SkillService(session).snapshots(),
                            thread.skills_config, workspace.skills_config)
                    except Exception:
                        _LOG.exception("api.websocket._run_turn: skills unavailable this turn")
                        selected_skills = []
                    skills_index = build_skills_index(selected_skills)
                    skill_tool = read_skill_tool(selected_skills, approval)
                    if skill_tool is not None:
                        tools.append(skill_tool)
                    tools.extend(self._client_group_tools(
                        turn_id, tools_raw, approval, {tool.name for tool in tools}))
                tools.extend(self._ui_tools(turn_id))
                agent_content: str | list[Any] = content
                if (active_file is not None or tagged_files or attachments) and \
                        config.id.casefold() != "echo" and \
                        config.provider.casefold() != "subconscious":
                    context_prompt = _prompt_with_file_context(content, tool_context)
                    binary_parts = [
                        BinaryContent(
                            attachment.content,
                            media_type=attachment.media_type,
                            identifier=attachment.name,
                        )
                        for attachment in attachments
                        if attachment.media_type in _BINARY_MEDIA_TYPES
                    ]
                    agent_content = [context_prompt, *binary_parts] \
                        if binary_parts else context_prompt
                streamed: list[str] = []
                turn_started = time.perf_counter()

                async def stream_delta(delta: Any) -> None:
                    # Real per-token streaming: model.delta -> chat.delta, in arrival order.
                    if isinstance(delta, str) and delta:
                        streamed.append(delta)
                        await self._send("chat.delta", {"thread_uuid": thread_uuid, "delta": delta}, turn_id)

                graph_engine = getattr(self.app.state, "graph_engine", None)
                if graph_engine is None:
                    async def agent_event(event: dict[str, Any]) -> None:
                        if event.get("type") == "model.delta":
                            await stream_delta(event.get("delta"))

                    extra: dict[str, Any] = {}
                    if skills_index != NO_SKILLS_INDEX:
                        extra["system_prompt"] = "\n\n".join(part for part in (
                            config.system_prompt,
                            f"Active skills (call read_skill with a name to load one):\n{skills_index}",
                        ) if part)
                    result = await self.app.state.agent_manager.execute(
                        config, agent_content, history, tools,
                        lambda call: self._request_approval(turn_id, thread_uuid, call),
                        event_sink=agent_event,
                        **extra,
                    )
                else:
                    async def graph_event(event: dict[str, Any]) -> None:
                        await self._send(
                            "agui.event",
                            {"thread_uuid": thread_uuid, **event},
                            turn_id,
                        )
                        await self.app.state.event_bus.publish(
                            "graph.execution", {"thread_uuid": thread_uuid, **event}
                        )
                        if event.get("type") == "model.delta":
                            await stream_delta(event.get("delta"))

                    result = await graph_engine.run_conscious(
                        config,
                        agent_content,
                        history,
                        tools,
                        lambda call: self._request_approval(turn_id, thread_uuid, call),
                        state={"active_skills": skills_index},
                        event_sink=graph_event,
                    )
                for record in result.tool_records:
                    message = Message(uuid=str(uuid4()), thread_id=thread.id, role="tool",
                                      content=json.dumps(record, default=str, separators=(",", ":")))
                    session.add(message)
                    await session.commit()
                    await self._publish_message(message, thread_uuid)
                assistant = Message(uuid=str(uuid4()), thread_id=thread.id, role="assistant", content=result.text)
                thread.updated_at = utc_now()
                session.add(assistant)
                await session.commit()
                await self._publish_message(assistant, thread_uuid)
            # Whatever streaming did not already deliver (nothing, or the tail) goes out
            # now so clients that accumulate chat.delta always end with the final text.
            already = "".join(streamed)
            if result.text and result.text != already:
                if not already:
                    await self._send("chat.delta", {"thread_uuid": thread_uuid, "delta": result.text}, turn_id)
                elif result.text.startswith(already):
                    await self._send("chat.delta", {"thread_uuid": thread_uuid,
                                                    "delta": result.text[len(already):]}, turn_id)
            prompt_tokens = int(getattr(result, "prompt_tokens", 0) or 0)
            completion_tokens = int(getattr(result, "completion_tokens", 0) or 0)
            await self._send("chat.done", {
                "thread_uuid": thread_uuid,
                "elapsed_ms": int((time.perf_counter() - turn_started) * 1000),
                "usage": {
                    "input_tokens": prompt_tokens,
                    "output_tokens": completion_tokens,
                    "total_tokens": prompt_tokens + completion_tokens,
                },
            }, turn_id)
            return "done", None
        except asyncio.CancelledError:
            _LOG.debug("api.websocket.WebSocketSession._run_turn: handled asyncio.CancelledError; continuing with fallback", exc_info=True)
            await self._send("chat.cancelled", {"thread_uuid": thread_uuid}, turn_id)
            return "cancelled", None
        except Exception as error:
            _LOG.exception("api.websocket.WebSocketSession._run_turn: handled Exception; continuing with fallback")
            await self._send("chat.error", {"thread_uuid": thread_uuid, "error": str(error)}, turn_id)
            return "failed", str(error) or error.__class__.__name__
        finally:
            if oauth_broker is not None:
                oauth_broker.detach(turn_id)
            for approval_id, (pending_turn, future) in tuple(self.pending.items()):
                if pending_turn == turn_id:
                    self.pending.pop(approval_id, None)
                    if not future.done():
                        future.cancel()
            for request_id, (pending_turn, future) in tuple(
                self.pending_client_tools.items()
            ):
                if pending_turn == turn_id:
                    self.pending_client_tools.pop(request_id, None)
                    if not future.done():
                        future.cancel()

    async def _request_approval(self, turn_id: str, thread_uuid: str, call: ToolCallPart) -> bool:
        approval_id = uuid4().hex
        future: asyncio.Future[bool] = asyncio.get_running_loop().create_future()
        self.pending[approval_id] = (turn_id, future)
        try:
            await self._send("tool.approval.request", {"approval_id": approval_id,
                "thread_uuid": thread_uuid, "tool_name": call.tool_name,
                "arguments": call.args_as_dict(), "operation": self.client_tool_operations.get(call.tool_name) or classify_operation(call.tool_name)}, turn_id)
            return await future
        finally:
            self.pending.pop(approval_id, None)

    async def _publish_thread_created(
        self, thread: ConversationThread, workspace: Workspace
    ) -> None:
        data = {
            "threadId": thread.uuid,
            "workspaceId": workspace.uuid,
            "title": thread.title or "",
        }
        await self.app.state.event_bus.publish("thread.created", data)
        await self.app.state.client_registry.broadcast(
            "thread.created", data, exclude_client_id=self.client_id
        )

    async def _publish_message(self, message: Message, thread_uuid: str) -> None:
        data = {
            "messageId": message.uuid,
            "threadId": thread_uuid,
            "role": message.role,
            "content": message.content,
        }
        await self.app.state.event_bus.publish("message.created", data)
        await self.app.state.client_registry.broadcast(
            "message.created", data, exclude_client_id=self.client_id
        )

    async def _error(self, message: str) -> None:
        await self._send("error", {"error": message})

    async def _send(self, frame_type: str, data: Any, identifier: str | None = None) -> None:
        frame = {"v": 1, "type": frame_type}
        if identifier is not None:
            frame["id"] = identifier
        frame["data"] = data
        async with self.send_lock:
            await self.socket.send_json(frame)

    @staticmethod
    def _title(content: str) -> str:
        normalized = " ".join(content.split())
        if not normalized:
            return "New conversation"
        return normalized if len(normalized) <= 60 else normalized[:57] + "…"


async def websocket_endpoint(socket: WebSocket) -> None:
    await WebSocketSession(socket).run()
