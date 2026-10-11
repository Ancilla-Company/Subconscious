"""Camel-case-envelope WebSocket protocol for chat, tools, and approvals."""

import asyncio
import base64
import binascii
from collections.abc import Callable
from contextlib import suppress
import json
from threading import RLock
from typing import Any
from uuid import uuid4

from pydantic_ai import Tool
from pydantic_ai.messages import BinaryContent, ToolCallPart
from sqlalchemy import select
from sqlalchemy.orm import selectinload
from starlette.websockets import WebSocket, WebSocketDisconnect

from subconscious_engine.approval import ApprovalConfig, classify_operation
from subconscious_engine.configuration.models import ModelConfig
from subconscious_engine.storage.models import ConversationThread, Message, Workspace, utc_now
from subconscious_engine.tools import (
    ContextAttachment,
    ContextFile,
    ToolContext,
    merge_tool_config,
)


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
        self._clients: dict[str, str] = {}
        self._sessions: dict[str, Any] = {}
        self._listeners: set[Callable[[tuple[str, ...]], None]] = set()
        self._lock = RLock()

    async def acquire(
        self, requested: str | None, *, label: str | None = None
    ) -> str | None:
        with self._lock:
            identifier = requested or uuid4().hex
            if identifier in self._clients:
                return None
            display_name = label.strip() if isinstance(label, str) else ""
            self._clients[identifier] = display_name or identifier
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
    ) -> None:
        with self._lock:
            recipients = tuple(
                session
                for identifier, session in self._sessions.items()
                if identifier != exclude_client_id
            )
        for session in recipients:
            with suppress(Exception):
                await session._send(frame_type, data)

    def subscribe(
        self, listener: Callable[[tuple[str, ...]], None]
    ) -> Callable[[], None]:
        with self._lock:
            self._listeners.add(listener)
            snapshot = self._snapshot_locked()
        self._notify_listener(listener, snapshot)

        def unsubscribe() -> None:
            with self._lock:
                self._listeners.discard(listener)

        return unsubscribe

    def snapshot(self) -> tuple[str, ...]:
        with self._lock:
            return self._snapshot_locked()

    def _snapshot_locked(self) -> tuple[str, ...]:
        return tuple(sorted(self._clients.values(), key=str.casefold))

    def _notify(self, snapshot: tuple[str, ...]) -> None:
        with self._lock:
            listeners = tuple(self._listeners)
        for listener in listeners:
            self._notify_listener(listener, snapshot)

    @staticmethod
    def _notify_listener(
        listener: Callable[[tuple[str, ...]], None], snapshot: tuple[str, ...]
    ) -> None:
        with suppress(Exception):
            listener(snapshot)


class WebSocketSession:
    def __init__(self, socket: WebSocket) -> None:
        self.socket = socket
        self.app = socket.app
        self.client_id: str | None = None
        self.active_turn: asyncio.Task[None] | None = None
        self.active_turn_id: str | None = None
        self.pending: dict[str, tuple[str, asyncio.Future[bool]]] = {}
        self.pending_client_tools: dict[
            str, tuple[str, asyncio.Future[dict[str, Any]]]
        ] = {}
        self.send_lock = asyncio.Lock()
        self.client_tools: dict[str, dict[str, Any]] = {}

    async def run(self) -> None:
        await self.socket.accept()
        try:
            while True:
                frame = await self.socket.receive_json()
                await self._handle(frame)
        except (WebSocketDisconnect, json.JSONDecodeError, ValueError):
            pass
        finally:
            await self._stop_active_turn()
            for _, future in self.pending.values():
                future.cancel()
            for _, future in self.pending_client_tools.values():
                future.cancel()
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
        elif frame_type == "chat.notification":
            await self._create_notification(turn_id or uuid4().hex, data)
        elif frame_type == "chat.cancel":
            await self._cancel(turn_id or data.get("turn_id"))
        elif frame_type == "tool.approval.response":
            await self._approval(turn_id, data)
        elif frame_type == "tool.register":
            for tool in data.get("tools", []):
                if (isinstance(tool, dict)
                        and isinstance(tool.get("id"), str)
                        and tool["id"] in _UI_TOOL_NAMES):
                    self.client_tools[tool["id"]] = {"id": tool["id"]}
        elif frame_type == "tool.unregister":
            identifier = data.get("id")
            if isinstance(identifier, str):
                self.client_tools.pop(identifier, None)
        elif frame_type == "client.tool.result":
            await self._client_tool_result(turn_id, data)
        elif frame_type in {"profile.set", "tool.result"}:
            return
        else:
            await self._error(f"Unknown frame type: {frame_type}")

    async def _hello(self, data: dict[str, Any]) -> None:
        requested = data.get("clientId") if isinstance(data.get("clientId"), str) else None
        client_name = data.get("clientName") if isinstance(data.get("clientName"), str) else None
        peer = getattr(self.socket, "client", None)
        peer_host = getattr(peer, "host", None)
        peer_port = getattr(peer, "port", None)
        peer_label = (
            f"{peer_host}:{peer_port}"
            if isinstance(peer_host, str) and isinstance(peer_port, int)
            else peer_host if isinstance(peer_host, str) else None
        )
        identifier = await self.app.state.client_registry.acquire(
            requested, label=client_name or requested or peer_label
        )
        if identifier is None:
            await self._send("client.hello.reject", {"reason": "Client_ID already in use by an active connection."})
            return
        await self.app.state.client_registry.release(self.client_id)
        self.client_id = identifier
        await self.app.state.client_registry.register_session(identifier, self)
        await self._send("client.hello.ack", {"clientId": identifier})

    async def _start_turn(self, turn_id: str, data: dict[str, Any]) -> None:
        if self.active_turn is not None and not self.active_turn.done():
            await self._error("Only one chat turn may run on a connection at a time.")
            return
        self.active_turn_id = turn_id
        self.active_turn = asyncio.create_task(self._run_turn(turn_id, data))

    async def _cancel(self, turn_id: Any) -> None:
        if isinstance(turn_id, str) and turn_id == self.active_turn_id:
            await self._stop_active_turn()

    async def _stop_active_turn(self) -> None:
        task = self.active_turn
        if task is None:
            return
        if not task.done():
            task.cancel()
        with suppress(asyncio.CancelledError, Exception):
            await task
        if self.active_turn is task:
            self.active_turn = None
            self.active_turn_id = None

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
            await self._error("Approval request was not found or has already completed.")
        elif turn_id is not None and turn_id != pending[0]:
            await self._error("Approval response does not belong to this chat turn.")
        elif not pending[1].done():
            pending[1].set_result(decision.casefold() == "approve")

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
        self, turn_id: str, tool_name: str, arguments: dict[str, Any]
    ) -> Any:
        request_id = uuid4().hex
        future: asyncio.Future[dict[str, Any]] = \
            asyncio.get_running_loop().create_future()
        self.pending_client_tools[request_id] = (turn_id, future)
        try:
            await self._send(
                "client.tool.request",
                {
                    "request_id": request_id,
                    "tool_name": tool_name,
                    "arguments": arguments,
                },
                turn_id,
            )
            response = await asyncio.wait_for(
                future, timeout=_CLIENT_TOOL_TIMEOUT_SECONDS
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
            catalog = self.app.state.tool_registry.catalog()
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

    async def _run_turn(self, turn_id: str, data: dict[str, Any]) -> None:
        thread_uuid = ""
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
                await self._error("chat.send requires content and exactly one of thread_uuid or workspace_uuid")
                return
            async with self.app.state.database.session() as session:
                if isinstance(requested_thread, str):
                    thread = await session.scalar(select(ConversationThread).options(
                        selectinload(ConversationThread.workspace)).where(ConversationThread.uuid == requested_thread))
                    if thread is None:
                        await self._send("chat.error", {"thread_uuid": requested_thread,
                            "error": f"Thread '{requested_thread}' not found."}, turn_id)
                        return
                    workspace = thread.workspace
                else:
                    workspace = await session.scalar(select(Workspace).where(Workspace.uuid == requested_workspace))
                    if workspace is None:
                        await self._send("chat.error", {"thread_uuid": "",
                            "error": f"Workspace '{requested_workspace}' not found."}, turn_id)
                        return
                    now = utc_now()
                    thread = ConversationThread(uuid=str(uuid4()), workspace_id=workspace.id,
                        title=self._title(content), default_model_id=None, created_at=now, updated_at=now)
                    session.add(thread)
                    await session.flush()
                    created_thread = True
                thread_uuid = thread.uuid
                selected_model = model_id if isinstance(model_id, str) else (
                    thread.default_model_id or workspace.default_model_id or "echo")
                config = ModelConfig(id="echo", provider="subconscious", model="echo") if selected_model.casefold() == "echo" \
                    else await self.app.state.model_configuration_store.resolve(selected_model)
                if config is None:
                    await self._send("chat.error", {"thread_uuid": thread_uuid,
                        "error": f"Model configuration '{selected_model}' was not found."}, turn_id)
                    return
                prior = (await session.scalars(select(Message).where(Message.thread_id == thread.id)
                                               .order_by(Message.created_at, Message.id))).all()
                history = [(message.role, message.content) for message in prior
                           if message.role in {"user", "assistant", "system"}]
                thread.default_model_id = config.id
                if not thread.title:
                    thread.title = self._title(content)
                thread.updated_at = utc_now()
                user_message = Message(uuid=str(uuid4()), thread_id=thread.id, role="user", content=content)
                session.add(user_message)
                await session.commit()
                if created_thread:
                    await self._publish_thread_created(thread, workspace)
                await self._publish_message(user_message, thread_uuid)
                tools_enabled = data.get("tools_enabled", True) is not False
                tools = []
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
                graph_engine = getattr(self.app.state, "graph_engine", None)
                if graph_engine is None:
                    result = await self.app.state.agent_manager.execute(
                        config, agent_content, history, tools,
                        lambda call: self._request_approval(turn_id, thread_uuid, call),
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

                    result = await graph_engine.run_conscious(
                        config,
                        agent_content,
                        history,
                        tools,
                        lambda call: self._request_approval(turn_id, thread_uuid, call),
                        state={
                            "active_skills": thread.skills_config or workspace.skills_config or "[]",
                        },
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
            if result.text:
                await self._send("chat.delta", {"thread_uuid": thread_uuid, "delta": result.text}, turn_id)
            await self._send("chat.done", {"thread_uuid": thread_uuid}, turn_id)
        except asyncio.CancelledError:
            await self._send("chat.cancelled", {"thread_uuid": thread_uuid}, turn_id)
        except Exception as error:
            await self._send("chat.error", {"thread_uuid": thread_uuid, "error": str(error)}, turn_id)
        finally:
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
            current_task = asyncio.current_task()
            if self.active_turn is None:
                self.active_turn_id = None
            elif self.active_turn is current_task:
                self.active_turn = None
                self.active_turn_id = None

    async def _request_approval(self, turn_id: str, thread_uuid: str, call: ToolCallPart) -> bool:
        approval_id = uuid4().hex
        future: asyncio.Future[bool] = asyncio.get_running_loop().create_future()
        self.pending[approval_id] = (turn_id, future)
        try:
            await self._send("tool.approval.request", {"approval_id": approval_id,
                "thread_uuid": thread_uuid, "tool_name": call.tool_name,
                "arguments": call.args_as_dict(), "operation": classify_operation(call.tool_name)}, turn_id)
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
