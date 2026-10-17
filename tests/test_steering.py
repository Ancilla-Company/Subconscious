"""Messages sent while the agent is working steer the run instead of being rejected."""

import asyncio

from sqlalchemy import select

from hive_testkit import mesh, until
from subconscious_engine.agents import AgentExecutionResult, steering_source
from subconscious_engine.storage.models import Message
from test_hive_tasks import local_session, run, types


class SteerableAgent:
    """Works until released; ``consume`` mimics the next model request reading steering."""

    def __init__(self, consume):
        self.consume, self.gate, self.seen, self.prompts = consume, asyncio.Event(), [], []

    async def execute(self, config, prompt, history, tools, approve, system_prompt=None, event_sink=None):
        self.prompts.append(prompt)
        if event_sink is not None:
            await event_sink({"type": "model.delta", "delta": "working "})
        if len(self.prompts) == 1:
            await self.gate.wait()
            if self.consume:
                self.seen = await steering_source.get()()
        return AgentExecutionResult(f"done {len(self.prompts)}", [])


async def start(a, agent):
    ws = await a.workspace("W")
    session = local_session(a.app)
    await session._handle({"type": "chat.send", "id": "t1", "data": {"workspace_uuid": ws, "content": "go"}})
    await until(lambda: any(f["type"] == "chat.delta" for f in session.frames))
    thread = next(f["data"]["thread_uuid"] for f in session.frames if f["type"] == "chat.delta")
    return session, thread


def test_message_sent_mid_run_is_injected_into_the_running_agent(tmp_path):
    async def scenario():
        agent = SteerableAgent(consume=True)
        async with mesh(tmp_path, ["a"], agent_manager=agent) as (engines, _):
            a = engines["a"]
            session, thread = await start(a, agent)
            await session._handle({"type": "chat.send", "id": "t2",
                                   "data": {"thread_uuid": thread, "content": "also check X"}})
            assert not any(f["type"] == "error" for f in session.frames)
            assert any(f["type"] == "chat.steered" and f["id"] == "t2" for f in session.frames)
            agent.gate.set()
            await until(lambda: any(f["type"] == "chat.done" and f["id"] == "t1" for f in session.frames))
            assert agent.seen == ["also check X"]
            assert len(agent.prompts) == 1  # no second turn needed
            assert any(f["type"] == "chat.done" and f["id"] == "t2" and f["data"].get("steered")
                       for f in session.frames)
            async with a.database.session() as db:
                roles = [(m.role, m.content) for m in (await db.scalars(select(Message).order_by(Message.hlc)))]
            assert ("user", "also check X") in roles

    run(scenario())


def test_message_that_arrives_too_late_runs_as_a_follow_up_turn(tmp_path):
    async def scenario():
        agent = SteerableAgent(consume=False)  # the run never reads steering
        async with mesh(tmp_path, ["a"], agent_manager=agent) as (engines, _):
            a = engines["a"]
            session, thread = await start(a, agent)
            await session._handle({"type": "chat.send", "id": "t2",
                                   "data": {"thread_uuid": thread, "content": "and one more thing"}})
            agent.gate.set()
            await until(lambda: any(f["type"] == "chat.done" and f["id"] == "t2" for f in session.frames))
            assert len(agent.prompts) == 2 and agent.prompts[1] == "and one more thing"
            assert any(f["type"] == "chat.delta" and f["id"] == "t2" for f in session.frames)
            async with a.database.session() as db:
                users = [m.content for m in (await db.scalars(select(Message).where(Message.role == "user")))]
            assert users.count("and one more thing") == 1  # not duplicated by the follow-up

    run(scenario())


def test_message_for_another_thread_is_not_blocked_by_a_busy_one(tmp_path):
    async def scenario():
        agent = SteerableAgent(consume=True)
        async with mesh(tmp_path, ["a"], agent_manager=agent) as (engines, _):
            a = engines["a"]
            session, _thread = await start(a, agent)
            await session._handle({"type": "chat.send", "id": "t2",
                                   "data": {"thread_uuid": "other", "content": "hi"}})
            await until(lambda: any(f["type"] == "chat.error" and f["id"] == "t2" for f in session.frames))
            assert "error" not in types(session.frames)  # no "one turn at a time" rejection
            agent.gate.set()

    run(scenario())


class GatedAgent:
    """Each prompt blocks on its own gate so several threads can be mid-run together."""

    def __init__(self):
        self.gates = {}

    def gate(self, prompt):
        return self.gates.setdefault(prompt, asyncio.Event())

    async def execute(self, config, prompt, history, tools, approve, system_prompt=None, event_sink=None):
        if event_sink is not None:
            await event_sink({"type": "model.delta", "delta": f"{prompt}: "})
        await self.gate(prompt).wait()
        return AgentExecutionResult(f"result {prompt}", [])


def done(session, frame_id):
    return any(f["type"] == "chat.done" and f["id"] == frame_id for f in session.frames)


def test_threads_run_concurrently_across_workspaces_and_stay_independent(tmp_path):
    async def scenario():
        agent = GatedAgent()
        async with mesh(tmp_path, ["a"], agent_manager=agent) as (engines, _):
            a = engines["a"]
            ws1, ws2 = await a.workspace("One"), await a.workspace("Two")
            session = local_session(a.app)
            await session._handle({"type": "chat.send", "id": "t1", "data": {"workspace_uuid": ws1, "content": "alpha"}})
            await session._handle({"type": "chat.send", "id": "t2", "data": {"workspace_uuid": ws2, "content": "beta"}})
            await until(lambda: {f["id"] for f in session.frames if f["type"] == "chat.delta"} == {"t1", "t2"})
            assert "error" not in types(session.frames)
            assert len(session.turns) == 2
            agent.gate("beta").set()  # the second thread finishes first
            await until(lambda: done(session, "t2"))
            assert not done(session, "t1")
            first_thread = next(f["data"]["thread_uuid"] for f in session.frames
                                if f["type"] == "chat.delta" and f["id"] == "t1")
            # the first thread is still running and can be steered after switching back
            await session._handle({"type": "chat.send", "id": "t3",
                                   "data": {"thread_uuid": first_thread, "content": "more"}})
            assert any(f["type"] == "chat.steered" and f["id"] == "t3" for f in session.frames)
            agent.gate("more").set()  # the late message becomes a follow-up turn
            agent.gate("alpha").set()
            await until(lambda: done(session, "t1") and done(session, "t3"))

    run(scenario())


def test_cancelling_one_thread_leaves_the_others_running(tmp_path):
    async def scenario():
        agent = GatedAgent()
        async with mesh(tmp_path, ["a"], agent_manager=agent) as (engines, _):
            a = engines["a"]
            ws1, ws2 = await a.workspace("One"), await a.workspace("Two")
            session = local_session(a.app)
            await session._handle({"type": "chat.send", "id": "t1", "data": {"workspace_uuid": ws1, "content": "alpha"}})
            await session._handle({"type": "chat.send", "id": "t2", "data": {"workspace_uuid": ws2, "content": "beta"}})
            await until(lambda: {f["id"] for f in session.frames if f["type"] == "chat.delta"} == {"t1", "t2"})
            await session._handle({"type": "chat.cancel", "id": "t1"})
            assert any(f["type"] == "chat.cancelled" and f["id"] == "t1" for f in session.frames)
            assert [t.turn_id for t in session.turns] == ["t2"]
            agent.gate("beta").set()
            await until(lambda: done(session, "t2"))

    run(scenario())
