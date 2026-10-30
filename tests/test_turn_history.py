"""A real chat turn leaves an ordered, complete record in the thread."""

import json

from sqlalchemy import select

from subconscious_engine.agents import AgentExecutionResult
from subconscious_engine.api.websocket import WebSocketSession
from subconscious_engine.storage.models import Message
from subconscious_engine.tool_events import progress_sink, tool_call_event, tool_progress_event

from test_api import run
from test_configured_tools import TurnSocket, turn_fixture


class ScriptedAgent:
    """Streams text, runs one approval-gated sub-agent call, then answers."""

    def __init__(self, fail_after_tool=False):
        self.fail_after_tool, self.history = fail_after_tool, None

    async def execute(self, config, prompt, history, tools, approve, system_prompt=None, event_sink=None):
        self.history = list(history)
        await event_sink({"type": "model.delta", "delta": "I'll ask the helper. "})
        call = {"tool_call_id": "c1", "tool_name": "ask_helper"}
        await event_sink(tool_call_event(**call, status="pending", arguments={"prompt": "hi"}))
        assert await approve(_Call("c1", "ask_helper")) is True
        await event_sink(tool_call_event(**call, status="in_progress"))
        await progress_sink.get()(tool_progress_event("c1", {"id": "message-0", "kind": "message", "text": "hello"}))
        await event_sink(tool_call_event(**call, status="completed", output={"output": "hello"}))
        if self.fail_after_tool:
            await event_sink({"type": "model.delta", "delta": "Half an ans"})
            raise RuntimeError("model fell over")
        await event_sink({"type": "model.delta", "delta": "The helper said hello."})
        return AgentExecutionResult("The helper said hello.", [])


class _Call:
    def __init__(self, call_id, name):
        self.tool_call_id, self.tool_name = call_id, name

    def args_as_dict(self):
        return {"prompt": "hi"}


async def stored(database):
    async with database.session() as session:
        rows = (await session.scalars(select(Message).order_by(Message.id))).all()
    return [(row.role, row.content) for row in rows]


def answer_approvals(session, approve=True):
    """Answer approval requests as the user would, through the session's own frame handler."""
    original = session._send

    async def send(frame_type, data, identifier=None):
        await original(frame_type, data, identifier)
        if frame_type == "tool.approval.request":
            pending = session.pending[data["approval_id"]]
            pending[1].set_result(approve)

    session._send = send


def test_turn_is_stored_in_order_with_approval_and_subagent_steps(tmp_path):
    async def scenario():
        database, app, _ = await turn_fixture(tmp_path)
        try:
            app.state.agent_manager = ScriptedAgent()
            session = WebSocketSession(TurnSocket(app))
            answer_approvals(session)
            assert await session._run_turn("t1", {"content": "hi", "workspace_uuid": "ws"}) == ("done", None)

            rows = await stored(database)
            assert [role for role, _ in rows] == ["user", "assistant", "tool", "assistant"]
            assert rows[1][1] == "I'll ask the helper. "
            assert rows[3][1] == "The helper said hello."
            tool = json.loads(rows[2][1])
            assert tool["v"] == 2 and tool["toolName"] == "ask_helper" and tool["status"] == "completed"
            assert tool["approval"] == "approved" and tool["approvalAt"]
            assert tool["input"] == {"prompt": "hi"} and tool["output"] == {"output": "hello"}
            assert tool["steps"] == [{"id": "message-0", "kind": "message", "text": "hello"}]

            frames = [f["type"] for f in session.socket.sent]
            assert "chat.tool_call" in frames and "chat.tool_progress" in frames
            progress = next(f for f in session.socket.sent if f["type"] == "chat.tool_progress")
            assert progress["data"]["tool_call_id"] == "c1" and progress["data"]["step"]["text"] == "hello"
            assert frames[-1] == "chat.done"
        finally:
            await app.state.configured_tools.close()
            await database.close()

    run(scenario())


def test_next_turn_sees_one_assistant_reply_not_one_per_segment(tmp_path):
    async def scenario():
        database, app, _ = await turn_fixture(tmp_path)
        try:
            agent = ScriptedAgent()
            app.state.agent_manager = agent
            session = WebSocketSession(TurnSocket(app))
            answer_approvals(session)
            await session._run_turn("t1", {"content": "first", "workspace_uuid": "ws"})
            async with database.session() as db:
                from subconscious_engine.storage.models import ConversationThread
                thread_uuid = (await db.scalar(select(ConversationThread))).uuid
            await session._run_turn("t2", {"content": "second", "thread_uuid": thread_uuid})
            assert [role for role, _ in agent.history] == ["user", "assistant"]
            assert agent.history[1][1] == "I'll ask the helper. \n\nThe helper said hello."
        finally:
            await app.state.configured_tools.close()
            await database.close()

    run(scenario())


def test_a_failed_turn_keeps_what_was_said_and_done(tmp_path):
    async def scenario():
        database, app, _ = await turn_fixture(tmp_path)
        try:
            app.state.agent_manager = ScriptedAgent(fail_after_tool=True)
            session = WebSocketSession(TurnSocket(app))
            answer_approvals(session)
            outcome = await session._run_turn("t1", {"content": "hi", "workspace_uuid": "ws"})
            assert outcome == ("failed", "model fell over")
            rows = await stored(database)
            assert [role for role, _ in rows] == ["user", "assistant", "tool", "assistant"]
            assert rows[3][1] == "Half an ans"
            assert session.socket.sent[-1]["type"] == "chat.error"
        finally:
            await app.state.configured_tools.close()
            await database.close()

    run(scenario())


def test_denied_calls_are_recorded_as_denied(tmp_path):
    async def scenario():
        database, app, _ = await turn_fixture(tmp_path)
        try:
            class Denied(ScriptedAgent):
                async def execute(self, config, prompt, history, tools, approve, system_prompt=None, event_sink=None):
                    call = {"tool_call_id": "d1", "tool_name": "remove_skill"}
                    await event_sink(tool_call_event(**call, status="pending", arguments={"name": "x"}))
                    assert await approve(_Call("d1", "remove_skill")) is False
                    await event_sink(tool_call_event(**call, status="failed", error="The tool call was denied."))
                    return AgentExecutionResult("Okay, I left it.", [])

            app.state.agent_manager = Denied()
            session = WebSocketSession(TurnSocket(app))
            answer_approvals(session, approve=False)
            await session._run_turn("t1", {"content": "hi", "workspace_uuid": "ws"})
            tool = json.loads(next(c for r, c in await stored(database) if r == "tool"))
            assert tool["approval"] == "denied" and tool["status"] == "failed"
        finally:
            await app.state.configured_tools.close()
            await database.close()

    run(scenario())
