import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import pytest
from starlette.websockets import WebSocketDisconnect

from subconscious_engine.api.websocket import ClientRegistry, WebSocketSession, _Turn, websocket_endpoint


def run(coro):
    return asyncio.run(coro)


class FakeSocket:
    def __init__(self, registry=None, incoming=None):
        self.app = SimpleNamespace(state=SimpleNamespace(
            client_registry=registry or ClientRegistry(),
            event_bus=SimpleNamespace(publish=AsyncMock()),
        ))
        self.incoming = list(incoming or [])
        self.accepted = False
        self.sent = []

    async def accept(self):
        self.accepted = True

    async def receive_json(self):
        value = self.incoming.pop(0)
        if isinstance(value, BaseException):
            raise value
        return value

    async def send_json(self, value):
        self.sent.append(value)


class FakeToolCall:
    tool_name = "read_file"

    def args_as_dict(self):
        return {"path": "notes.txt"}


def test_client_registry_rejects_duplicates_notifies_snapshots_and_releases_idempotently():
    async def scenario():
        registry = ClientRegistry()
        snapshots = []
        unsubscribe = registry.subscribe(snapshots.append)
        assert snapshots == [()]
        assert await registry.acquire("desktop", label="Desktop App") == "desktop"
        assert registry.snapshot() == ("Desktop App",)
        assert await registry.acquire("desktop") is None
        with patch(
            "subconscious_engine.api.websocket.uuid4",
            return_value=SimpleNamespace(hex="generated"),
        ):
            assert await registry.acquire(None, label="Android") == "generated"
            assert await registry.acquire(None) is None
        assert registry.snapshot() == ("Android", "Desktop App")
        await registry.release("desktop")
        await registry.release("desktop")
        await registry.release(None)
        assert snapshots[-1] == ("Android",)
        unsubscribe()
        assert await registry.acquire("desktop") == "desktop"
        assert snapshots[-1] == ("Android",)
    run(scenario())


def test_run_accepts_handshake_uses_versioned_envelopes_and_releases_on_disconnect():
    async def scenario():
        registry = ClientRegistry()
        socket = FakeSocket(registry, [
            {"type": "client.hello", "data": {"clientId": "desktop"}},
            {"type": "ping"},
            WebSocketDisconnect(code=1000),
        ])
        await WebSocketSession(socket).run()
        assert socket.accepted is True
        assert socket.sent == [
            {"v": 1, "type": "client.hello.ack", "data": {"clientId": "desktop", "local": False}},
            {"v": 1, "type": "pong", "data": None},
        ]
        assert await registry.acquire("desktop") == "desktop"
    run(scenario())


def test_hello_rejects_active_id_and_rehello_releases_previous_id():
    async def scenario():
        registry = ClientRegistry()
        assert await registry.acquire("busy") == "busy"
        socket = FakeSocket(registry)
        session = WebSocketSession(socket)

        await session._handle({"type": "client.hello", "data": {"clientId": "busy"}})
        assert session.client_id is None
        assert socket.sent[-1] == {
            "v": 1,
            "type": "client.hello.reject",
            "data": {"reason": "Client_ID already in use by an active connection."},
        }
        await session._handle({"type": "client.hello", "data": {"clientId": "first"}})
        await session._handle({"type": "client.hello", "data": {"clientId": "second"}})
        assert session.client_id == "second"
        assert await registry.acquire("first") == "first"
        assert await registry.acquire("second") is None
    run(scenario())


def test_frame_dispatch_validates_types_tracks_client_tools_and_reports_unknown_frames():
    async def scenario():
        socket = FakeSocket()
        session = WebSocketSession(socket)
        await session._handle(None)
        await session._handle({"data": {}})
        await session._handle({
            "type": "tool.register",
            "data": {"tools": [
                {"id": "set_ui_theme_color", "name": "Theme"},
                {"id": "weather", "name": "Untrusted"},
                {"name": "missing id"},
                "not an object",
            ]},
        })
        assert session.client_tools == {
            "set_ui_theme_color": {"id": "set_ui_theme_color"}
        }
        await session._handle({
            "type": "tool.unregister",
            "data": {"id": "set_ui_theme_color"},
        })
        assert session.client_tools == {}
        await session._handle({"type": "profile.set", "data": "ignored"})
        await session._handle({"type": "tool.result"})
        await session._handle({"type": "surprise"})
        assert socket.sent == [
            {"v": 1, "type": "error", "data": {"error": "Missing 'type' field"}},
            {"v": 1, "type": "error", "data": {"error": "Missing 'type' field"}},
            {"v": 1, "type": "error", "data": {"error": "Unknown frame type: surprise"}},
        ]
    run(scenario())


def test_turn_start_enforces_single_active_task_and_cancel_matches_turn_id():
    async def scenario():
        socket = FakeSocket()
        session = WebSocketSession(socket)
        started = asyncio.Event()

        async def blocked(turn_id, data):
            started.set()
            await asyncio.Event().wait()

        session._run_turn = blocked
        await session._start_turn("turn-1", {"content": "hello"})
        await started.wait()
        task = session.active_turn
        assert task is not None and session.active_turn_id == "turn-1"
        await session._start_turn("turn-2", {"content": "other"})
        # A second turn runs alongside the first instead of being rejected.
        assert not any(frame["type"] == "error" for frame in socket.sent)
        second = session._turn_for_id("turn-2").task
        await session._cancel("turn-2")
        assert second.cancelled() and not task.cancelled()
        await session._cancel("turn-1")
        with pytest.raises(asyncio.CancelledError):
            await task
    run(scenario())


def test_approval_validation_turn_matching_and_decision_resolution():
    async def scenario():
        socket = FakeSocket()
        session = WebSocketSession(socket)
        await session._approval(None, {})
        await session._approval(None, {"approval_id": "missing", "decision": "approve"})
        future = asyncio.get_running_loop().create_future()
        session.pending["approval-1"] = ("turn-1", future)
        await session._approval(
            "turn-2", {"approval_id": "approval-1", "decision": "approve"}
        )
        assert not future.done()
        await session._approval(
            "turn-1", {"approval_id": "approval-1", "decision": "DENY"}
        )
        assert await future is False
        assert [frame["data"]["error"] for frame in socket.sent] == [
            "tool.approval.response requires approval_id and decision.",
            "Approval request was not found or has already completed.",
            "Approval response does not belong to this chat turn.",
        ]
    run(scenario())


def test_approval_request_envelope_resolves_and_always_removes_pending_future():
    async def scenario():
        socket = FakeSocket()
        session = WebSocketSession(socket)
        with patch(
            "subconscious_engine.api.websocket.uuid4",
            return_value=SimpleNamespace(hex="approval-fixed"),
        ):
            waiting = asyncio.create_task(
                session._request_approval("turn-7", "thread-3", FakeToolCall())
            )
            await asyncio.sleep(0)
            assert socket.sent == [{
                "v": 1,
                "type": "tool.approval.request",
                "id": "turn-7",
                "data": {
                    "approval_id": "approval-fixed",
                    "thread_uuid": "thread-3",
                    "tool_name": "read_file",
                    "arguments": {"path": "notes.txt"},
                    "operation": "read",
                },
            }]
            assert "approval-fixed" in session.pending
            await session._approval(
                "turn-7",
                {"approval_id": "approval-fixed", "decision": "ApPrOvE"},
            )
            assert await waiting is True
            assert session.pending == {}
    run(scenario())


def test_run_cleanup_cancels_turn_and_approvals_and_releases_client_on_bad_json():
    async def scenario():
        registry = ClientRegistry()
        assert await registry.acquire("desktop") == "desktop"
        socket = FakeSocket(registry, [ValueError("invalid JSON")])
        session = WebSocketSession(socket)
        session.client_id = "desktop"
        session.turns.append(_Turn("turn", task=asyncio.create_task(asyncio.sleep(60))))
        future = asyncio.get_running_loop().create_future()
        session.pending["approval"] = ("turn", future)

        task = session.active_turn
        await session.run()
        assert socket.accepted is True
        assert future.cancelled()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert task.cancelled()
        assert await registry.acquire("desktop") == "desktop"
    run(scenario())


def test_run_turn_validation_emits_correlated_error_and_cleans_turn_approvals():
    async def scenario():
        socket = FakeSocket()
        session = WebSocketSession(socket)
        future = asyncio.get_running_loop().create_future()
        session.pending["approval"] = ("turn-1", future)

        await session._run_turn("turn-1", {"content": "hello"})
        assert socket.sent == [{
            "v": 1,
            "type": "error",
            "data": {
                "error": "chat.send requires content and exactly one of thread_uuid or workspace_uuid"
            },
        }]
        assert session.pending == {}
        assert future.cancelled()
        assert session.active_turn_id is None
    run(scenario())


@pytest.mark.parametrize(("content", "expected"), [
    ("", "New conversation"),
    ("  hello   websocket  ", "hello websocket"),
    ("x" * 61, "x" * 57 + "…"),
])
def test_title_normalizes_whitespace_empty_and_long_content(content, expected):
    assert WebSocketSession._title(content) == expected


def test_websocket_endpoint_constructs_and_runs_a_session():
    async def scenario():
        socket = FakeSocket()
        session = AsyncMock()
        with patch(
            "subconscious_engine.api.websocket.WebSocketSession", return_value=session
        ) as constructor:
            await websocket_endpoint(socket)
        constructor.assert_called_once_with(socket)
        session.run.assert_awaited_once_with()
    run(scenario())
