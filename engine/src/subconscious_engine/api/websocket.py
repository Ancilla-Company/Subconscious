"""Camel-case-envelope WebSocket protocol for chat, tools, and approvals."""

import asyncio
from collections.abc import Callable
from contextlib import suppress
import json
from threading import RLock
from typing import Any
from uuid import uuid4

from pydantic_ai.messages import ToolCallPart
from sqlalchemy import select
from sqlalchemy.orm import selectinload
from starlette.websockets import WebSocket, WebSocketDisconnect

from subconscious_engine.approval import ApprovalConfig, classify_operation
from subconscious_engine.configuration.models import ModelConfig
from subconscious_engine.storage.models import ConversationThread, Message, Workspace, utc_now
from subconscious_engine.tools import ToolContext, merge_tool_config


class ClientRegistry:
    def __init__(self) -> None:
        self._clients: dict[str, str] = {}
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
            snapshot = self._snapshot_locked()
        self._notify(snapshot)

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
        elif frame_type == "chat.cancel":
            await self._cancel(turn_id or data.get("turn_id"))
        elif frame_type == "tool.approval.response":
            await self._approval(turn_id, data)
        elif frame_type == "tool.register":
            for tool in data.get("tools", []):
                if isinstance(tool, dict) and isinstance(tool.get("id"), str):
                    self.client_tools[tool["id"]] = tool
        elif frame_type == "tool.unregister":
            identifier = data.get("id")
            if isinstance(identifier, str):
                self.client_tools.pop(identifier, None)
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

    async def _run_turn(self, turn_id: str, data: dict[str, Any]) -> None:
        thread_uuid = ""
        try:
            created_thread = False
            content = data.get("content")
            requested_thread = data.get("thread_uuid")
            requested_workspace = data.get("workspace_uuid")
            model_id = data.get("model_id")
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
                    await self.app.state.event_bus.publish("thread.created", {
                        "threadId": thread.uuid, "workspaceId": workspace.uuid,
                        "title": thread.title or ""})
                await self._publish_message(user_message, thread_uuid)
                tools_enabled = data.get("tools_enabled", True) is not False
                tools = []
                if tools_enabled:
                    tools_raw = merge_tool_config(workspace.tools_config, thread.tools_config)
                    approval = ApprovalConfig.from_json(
                        thread.approval_config or workspace.approval_config
                    )
                    tools = self.app.state.tool_registry.tools_for_config(
                        tools_raw,
                        ToolContext(
                            self.app.state.rag_service,
                            self.app.state.database,
                            workspace.uuid,
                            thread.id,
                        ),
                        approval,
                    )
                result = await self.app.state.agent_manager.execute(config, content, history, tools,
                    lambda call: self._request_approval(turn_id, thread_uuid, call))
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

    async def _publish_message(self, message: Message, thread_uuid: str) -> None:
        await self.app.state.event_bus.publish("message.created", {"messageId": message.uuid,
            "threadId": thread_uuid, "role": message.role, "content": message.content})

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
