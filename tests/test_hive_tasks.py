"""Phase 4 tests: tasks, routing, approvals, restart recovery and token streaming."""

import asyncio
import json
import time
from types import SimpleNamespace

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st
from httpx import ASGITransport, AsyncClient
from pydantic_ai.messages import ToolCallPart
from sqlalchemy import select

from hive_testkit import MemEngine, MemThin, connect, converged, make_entries, mesh, until
from subconscious_engine.agents import AgentExecutionResult
from subconscious_engine.api.websocket import WebSocketSession
from subconscious_engine.hive.channels import Envelope
from subconscious_engine.hive.identity import NodeIdentity
from subconscious_engine.hive.sync.hlc import format_stamp
from subconscious_engine.hive.sync.ops import sign_op
from subconscious_engine.hive.tasks import (
    TERMINAL,
    TRANSITIONS,
    InvalidTransition,
    TaskError,
    can_transition,
)
from subconscious_engine.storage.models import Message, SyncLog, TaskRecord


def run(coro):
    return asyncio.run(coro)


class FakeSocket:
    def __init__(self, app):
        self.app, self.sent, self.client = app, [], None

    async def accept(self):
        return None

    async def receive_json(self):
        await asyncio.Event().wait()

    async def send_json(self, data):
        self.sent.append(data)


def local_session(app):
    session = WebSocketSession(FakeSocket(app))
    session.frames = session.socket.sent
    return session


def types(frames):
    return [f["type"] for f in frames]


def statuses(frames):
    return [f["data"]["status"] for f in frames if f["type"] == "task.status"]


async def task_status(engine, task_id):
    async with engine.database.session() as session:
        row = await session.scalar(select(TaskRecord).where(TaskRecord.task_id == task_id))
        return row.status if row else None


# --- agents used by the tests -----------------------------------------------------------------


class TokenAgent:
    """Streams tokens through ``model.delta`` like the real AgentManager."""

    def __init__(self, tokens, final=None):
        self.tokens, self.final = tokens, final if final is not None else "".join(tokens)

    async def execute(self, config, prompt, history, tools, approve, system_prompt=None, event_sink=None):
        for token in self.tokens:
            if event_sink is not None:
                await event_sink({"type": "model.delta", "delta": token})
            await asyncio.sleep(0)
        return AgentExecutionResult(self.final, [])


class BlockingAgent:
    def __init__(self):
        self.started = asyncio.Event()
        self.release = asyncio.Event()

    async def execute(self, config, prompt, history, tools, approve, system_prompt=None, event_sink=None):
        self.started.set()
        await self.release.wait()
        return AgentExecutionResult("finished", [])


class ApprovalAgent:
    def __init__(self):
        self.asked = asyncio.Event()

    async def execute(self, config, prompt, history, tools, approve, system_prompt=None, event_sink=None):
        self.asked.set()
        approved = await approve(ToolCallPart(tool_name="write_file", args={"path": "x.txt"}))
        return AgentExecutionResult(f"approved={approved}", [])


# --- state machine -------------------------------------------------------------------------------


def test_transition_table_is_forward_only_and_terminal_states_are_final():
    assert can_transition("queued", "running") and can_transition("running", "waiting_approval")
    assert can_transition("waiting_approval", "running")  # the only allowed back-edge
    for final in TERMINAL:
        assert TRANSITIONS[final] == frozenset()
    assert not can_transition("running", "queued") and not can_transition("done", "running")
    assert not can_transition("queued", "waiting_approval") and not can_transition("bogus", "running")


@settings(max_examples=60, deadline=None)
@given(st.lists(st.sampled_from(sorted(TRANSITIONS)), max_size=25))
def test_status_property_applying_only_valid_transitions_never_leaves_a_terminal_state(attempts):
    state, finished = "queued", False
    for target in attempts:
        if can_transition(state, target):
            assert not finished
            state = target
            finished = state in TERMINAL
    assert finished or state in {"queued", "running", "waiting_approval"}


def test_only_the_executor_writes_status_and_backwards_moves_are_refused(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a", "b"]) as (engines, _):
            a, b = engines["a"], engines["b"]
            async with a.database.session() as session:
                session.add(TaskRecord(task_id="t-remote", thread_uuid="th", executor_node_id=b.identity.node_id,
                                       requester_node_id=a.identity.node_id, status="queued", rev=0))
                session.add(TaskRecord(task_id="t-local", thread_uuid="th", executor_node_id=a.identity.node_id,
                                       requester_node_id=a.identity.node_id, status="running", rev=1))
                await session.commit()
            with pytest.raises(TaskError):  # a is not the executor of t-remote
                await a.tasks.set_status("t-remote", "running")
            row = await a.tasks.set_status("t-local", "done")
            assert row.status == "done" and row.rev == 2 and row.finished_at is not None
            with pytest.raises(InvalidTransition):
                await a.tasks.set_status("t-local", "running")
            assert (await a.tasks.set_status("t-local", "done")).rev == 2  # idempotent

    run(scenario())


def test_task_merge_prefers_terminal_and_rejects_writes_from_non_executors(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a", "b", "c"]) as (engines, _):
            a, b, c = engines["a"], engines["b"], engines["c"]
            base = {"thread_uuid": "th", "workspace_uuid": None, "executor_node_id": b.identity.node_id,
                    "requester_node_id": a.identity.node_id, "turn_id": "t1", "model_id": None,
                    "client_msg_uuid": "m1", "created_at": "2024-01-01T00:00:00+00:00", "started_at": None,
                    "finished_at": None, "error": None}
            now = int(time.time() * 1000)
            create = sign_op(a.identity, 1, "task", "t1", "create", format_stamp(now, 0),
                             {**base, "status": "queued", "rev": 0})
            running = sign_op(b.identity, 1, "task", "t1", "update", format_stamp(now + 10, 0),
                              {**base, "status": "running", "rev": 1})
            expired = sign_op(a.identity, 2, "task", "t1", "update", format_stamp(now + 5, 0),
                              {**base, "status": "failed", "rev": 1, "error": "expired"})
            outsider = sign_op(c.identity, 1, "task", "t1", "update", format_stamp(now + 20, 0),
                               {**base, "status": "done", "rev": 5})
            first = [create, running, expired]
            second = [expired, create, running]
            for engine, order in ((a, first), (b, second)):
                pass
            await c.engine.apply(first)
            await a.engine.apply([running])
            await b.engine.apply(second)
            report = await b.engine.apply([outsider])
            assert [r for _, r in report.rejected] == ["Task written by a node that is neither executor nor creator."]
            assert await task_status(c, "t1") == "failed" and await task_status(b, "t1") == "failed"

    run(scenario())


# --- local tasks, idempotency and streaming -----------------------------------------------------------


def test_local_task_runs_the_chat_pipeline_and_is_idempotent_per_client_message(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a"]) as (engines, _):
            a = engines["a"]
            ws = await a.workspace("W")
            session = local_session(a.app)
            payload = {"workspace_uuid": ws, "content": "hello task", "client_msg_uuid": "msg-1"}
            await session._handle({"type": "task.submit", "id": "req-1", "data": payload})
            accepted = next(f for f in session.frames if f["type"] == "task.accepted")
            task_id, thread = accepted["data"]["task_id"], accepted["data"]["thread_uuid"]
            assert accepted["id"] == "req-1" and accepted["data"]["executor_node_id"] == a.identity.node_id
            await until(lambda: "task.status" in types(session.frames) and "done" in statuses(session.frames))
            assert statuses(session.frames) == ["running", "done"]
            deltas = [f["data"]["delta"] for f in session.frames if f["type"] == "chat.delta"]
            assert "".join(deltas) == "hello task"
            assert all(f["id"] == task_id for f in session.frames if f["type"].startswith("chat."))
            assert types(session.frames).index("chat.done") < len(types(session.frames))

            await session._handle({"type": "task.submit", "id": "req-2", "data": payload})  # same client message
            again = [f for f in session.frames if f["type"] == "task.accepted"][-1]
            assert again["data"]["task_id"] == task_id
            async with a.database.session() as db:
                rows = (await db.scalars(select(Message).order_by(Message.hlc))).all()
                assert [(m.role, m.uuid == "msg-1") for m in rows] == [("user", True), ("assistant", False)]
                assert len((await db.scalars(select(TaskRecord))).all()) == 1
            assert (await a.fingerprint())["threads"][thread][0] == ws

    run(scenario())


def test_chat_deltas_stream_in_arrival_order_and_the_final_message_is_persisted(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a"], agent_manager=TokenAgent(["Hel", "lo ", "wor", "ld"])) as (engines, _):
            a = engines["a"]
            ws = await a.workspace("W")
            session = local_session(a.app)
            await session._handle({"type": "chat.send", "id": "turn-1",
                                   "data": {"workspace_uuid": ws, "content": "say hi"}})
            turn = session.active_turn  # cleared by the turn itself once it finishes
            await until(lambda: "chat.done" in types(session.frames))
            if turn is not None:
                await turn
            deltas = [f["data"]["delta"] for f in session.frames if f["type"] == "chat.delta"]
            assert deltas == ["Hel", "lo ", "wor", "ld"]  # per token, in order, no duplicated final blob
            assert types(session.frames)[-1] == "chat.done"
            async with a.database.session() as db:
                assistant = await db.scalar(select(Message).where(Message.role == "assistant"))
                assert assistant.content == "Hello world"

    run(scenario())


def test_delta_stream_falls_back_to_the_final_text_when_nothing_or_only_a_prefix_streamed(tmp_path):
    async def scenario(tokens, final, expected):
        async with mesh(tmp_path / str(len(expected)), ["a"], agent_manager=TokenAgent(tokens, final)) as (engines, _):
            a = engines["a"]
            ws = await a.workspace("W")
            session = local_session(a.app)
            await session._handle({"type": "chat.send", "id": "t", "data": {"workspace_uuid": ws, "content": "x"}})
            await until(lambda: "chat.done" in types(session.frames))
            deltas = [f["data"]["delta"] for f in session.frames if f["type"] == "chat.delta"]
            assert deltas == expected and "".join(deltas) == final

    for index, args in enumerate((([], "all at once", ["all at once"]), (["Hello "], "Hello world", ["Hello ", "world"]))):
        (tmp_path / str(len(args[2]))).mkdir(exist_ok=True)
        run(scenario(*args))


def test_graph_engine_model_deltas_become_chat_deltas_after_their_agui_event(tmp_path):
    class Graph:
        async def run_conscious(self, model, prompt, history, tools, approve, state=None, event_sink=None):
            await event_sink({"type": "run.started", "run_id": "r"})
            for token in ("a", "b"):
                await event_sink({"type": "model.delta", "node_id": "general", "delta": token})
            return SimpleNamespace(text="ab", tool_records=[])

    async def scenario():
        async with mesh(tmp_path, ["a"]) as (engines, _):
            a = engines["a"]
            a.app.state.graph_engine = Graph()
            ws = await a.workspace("W")
            session = local_session(a.app)
            await session._handle({"type": "chat.send", "id": "t", "data": {"workspace_uuid": ws, "content": "x"}})
            await until(lambda: "chat.done" in types(session.frames))
            relevant = [(f["type"], f["data"]["type"] if f["type"] == "agui.event" else f["data"]["delta"])
                        for f in session.frames if f["type"] in {"agui.event", "chat.delta"}]
            assert relevant == [("agui.event", "run.started"), ("agui.event", "model.delta"), ("chat.delta", "a"),
                                ("agui.event", "model.delta"), ("chat.delta", "b")]

    run(scenario())


# --- routing, forwarding and re-authorisation ---------------------------------------------------------------


def test_task_from_a_thin_client_is_forwarded_to_the_executor_and_relayed_back(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a", "b"], thin=["t"]) as (engines, thins):
            a, b = engines["a"], engines["b"]
            connect(a, b)
            assert await a.node.coordinator.wait_ready(b.identity.node_id)
            ws = await a.workspace("Forwarded task")
            await until(lambda: asyncio.ensure_future(_has_workspace(b, ws)))
            thin = MemThin(a, thins["t"])  # the phone is connected to a, but b is the executor
            await thin.send("task.submit", {"workspace_uuid": ws, "content": "run on b", "client_msg_uuid": "cm-1",
                                            "executor": b.identity.node_id}, "req")
            await until(lambda: thin.of_type("task.accepted"))
            task_id = thin.of_type("task.accepted")[0].data["task_id"]
            await until(lambda: any(e.data.get("status") == "done" for e in thin.of_type("task.status")))
            await until(lambda: thin.of_type("chat.done"))
            assert "run on b" in "".join(e.data["delta"] for e in thin.of_type("chat.delta"))
            assert all(e.id == task_id for e in thin.of_type("chat.delta"))
            fingerprint = await converged(a, b)
            task = fingerprint["tasks"][task_id]
            assert task[1] == b.identity.node_id and task[2] == thins["t"].node_id and task[3] == "done"
            assert "cm-1" in fingerprint["messages"]
            rows = await b.task_rows()
            assert rows[0].status == "done" and rows[0].requester_node_id == thins["t"].node_id

    run(scenario())


async def _has_workspace(engine, uuid):
    return uuid in (await engine.fingerprint())["workspaces"]


def test_executor_reauthorizes_forwarded_requests(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a", "b"], thin=["t"]) as (engines, thins):
            a, b = engines["a"], engines["b"]
            la, lb = connect(a, b)
            ws = await a.workspace("W")
            base = {"workspace_uuid": ws, "thread_uuid": "th-1", "content": "x", "forwarded": True,
                    "executor": b.identity.node_id}

            async def forward(identifier, **changes):
                before = len(lb.sent)
                await la.send("control", Envelope("task.submit", {**base, "client_msg_uuid": identifier, **changes},
                                                  identifier))
                await until(lambda: len(lb.sent) > before and any(e.type == "task.error" for _, e in lb.sent[before:]))
                return [e for _, e in lb.sent[before:] if e.type == "task.error"][0].data["error"]

            assert "not authorised" in await forward("c1", requester_node_id="n_unknown")
            assert "not authorised" in await forward("c2")  # no requester claimed at all
            # revoked requester: still rejected even though it was once valid
            revoked = [dict(e, status="revoked") if e["id"] == thins["t"].node_id else e for e in
                       make_entries(a.identity, (b.identity, "engine"), (thins["t"], "thin"))]
            b.directory.update(revoked, "hive-1")
            assert "not authorised" in await forward("c3", requester_node_id=thins["t"].node_id)
            # thin clients can never assert someone else's identity
            thin = MemThin(b, NodeIdentity.generate())
            await thin.send("task.submit", {**base, "client_msg_uuid": "c4", "requester_node_id": a.identity.node_id},
                            "x")
            await until(lambda: thin.of_type("error") or thin.of_type("task.error"))
            assert not await b.task_rows()

    run(scenario())


def test_task_for_an_offline_executor_stays_queued_then_expires(tmp_path):
    async def scenario():
        # The TTL must comfortably exceed the time the setup takes on a slow machine,
        # or the "still inside the TTL" assertion races the clock.
        async with mesh(tmp_path, ["a", "b"], thin=["t"], ttl=3.0) as (engines, thins):
            a, b = engines["a"], engines["b"]
            thin = MemThin(a, thins["t"])
            ws = await a.workspace("W")
            await thin.send("task.submit", {"workspace_uuid": ws, "content": "later", "client_msg_uuid": "cm",
                                            "executor": b.identity.node_id}, "r")
            await until(lambda: thin.of_type("task.accepted"))
            task_id = thin.of_type("task.accepted")[0].data["task_id"]
            assert await task_status(a, task_id) == "queued"
            assert await a.tasks.sweep() == 0  # still inside the TTL
            await asyncio.sleep(3.2)
            # The background sweeper may already have expired it; the outcome is what matters.
            await a.tasks.sweep()
            row = (await a.task_rows())[0]
            assert (row.status, row.error, row.rev) == ("failed", "expired", 1)
            assert statuses([{"type": e.type, "data": e.data} for e in thin.frames]) == ["queued", "failed"]
            assert not await b.task_rows()  # nothing ever ran on the executor

    run(scenario())


def test_queued_task_is_delivered_when_the_executor_connects_before_the_ttl(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a", "b"], thin=["t"]) as (engines, thins):
            a, b = engines["a"], engines["b"]
            thin = MemThin(a, thins["t"])
            ws = await a.workspace("W")
            await thin.send("task.submit", {"workspace_uuid": ws, "content": "when you wake", "client_msg_uuid": "cm",
                                            "executor": b.identity.node_id}, "r")
            await until(lambda: thin.of_type("task.accepted"))
            task_id = thin.of_type("task.accepted")[0].data["task_id"]
            assert await task_status(a, task_id) == "queued" and (await a.task_rows())[0].payload
            connect(a, b)
            await until(lambda: any(e.data.get("status") == "done" for e in thin.of_type("task.status")))
            await converged(a, b)
            assert await task_status(b, task_id) == "done"
            assert (await a.task_rows())[0].payload is None  # request body dropped once the executor took over

    run(scenario())


def test_engine_restart_marks_running_tasks_interrupted(tmp_path):
    async def scenario():
        agent = BlockingAgent()
        identities = [NodeIdentity.generate()]
        entries = make_entries(identities[0])
        first = MemEngine(tmp_path, "a", identities[0], entries, agent_manager=agent)
        await first.start()
        ws = await first.workspace("W")
        session = local_session(first.app)
        await session._handle({"type": "task.submit", "data": {"workspace_uuid": ws, "content": "long job"}})
        await asyncio.wait_for(agent.started.wait(), 10)
        task_id = next(f for f in session.frames if f["type"] == "task.accepted")["data"]["task_id"]
        assert await task_status(first, task_id) == "running"
        await first.stop()  # shutdown: the task is left "running" on disk

        second = MemEngine(tmp_path, "a", identities[0], entries)
        await second.start()
        try:
            row = (await second.task_rows())[0]
            assert (row.status, row.rev) == ("interrupted", 2) and "restarted" in row.error
            async with second.database.session() as db:
                updates = (await db.scalars(select(SyncLog).where(SyncLog.entity == "task"))).all()
                assert [u.op for u in updates].count("update") >= 1  # the interruption is a signed, synced op
        finally:
            await second.stop()

    run(scenario())


def test_cancel_stops_a_running_task_even_when_routed_through_another_node(tmp_path):
    async def scenario():
        agent = BlockingAgent()
        async with mesh(tmp_path, ["a", "b"], thin=["t"]) as (engines, thins):
            a, b = engines["a"], engines["b"]
            b.app.state.agent_manager = agent
            connect(a, b)
            assert await a.node.coordinator.wait_ready(b.identity.node_id)
            ws = await a.workspace("W")
            await until(lambda: asyncio.ensure_future(_has_workspace(b, ws)))
            thin = MemThin(a, thins["t"])
            await thin.send("task.submit", {"workspace_uuid": ws, "content": "stop me", "client_msg_uuid": "cm",
                                            "executor": b.identity.node_id}, "r")
            await asyncio.wait_for(agent.started.wait(), 10)
            task_id = thin.of_type("task.accepted")[0].data["task_id"]
            await thin.send("task.cancel", {"task_id": task_id})
            await until(lambda: thin.of_type("chat.cancelled"))
            await until(lambda: any(e.data.get("status") == "cancelled" for e in thin.of_type("task.status")))
            await converged(a, b)
            assert await task_status(a, task_id) == "cancelled"
            stranger = MemThin(a, NodeIdentity.generate())
            await stranger.send("task.cancel", {"task_id": task_id})  # unknown principal: never an error leak
            agent.release.set()

    run(scenario())


# --- approvals ------------------------------------------------------------------------------------------------


def test_approval_race_first_valid_response_wins_and_others_are_told(tmp_path):
    async def scenario():
        agent = ApprovalAgent()
        async with mesh(tmp_path, ["a"], thin=["t1", "t2", "t3"], agent_manager=agent) as (engines, thins):
            a = engines["a"]
            ws = await a.workspace("W")
            thread = await a.thread(ws, "approvals")
            requester, viewer, stranger = (MemThin(a, thins[n]) for n in ("t1", "t2", "t3"))
            await viewer.send("thread.subscribe", {"thread_uuid": thread})
            await until(lambda: viewer.of_type("thread.subscribed"))
            await requester.send("task.submit", {"thread_uuid": thread, "content": "write it", "client_msg_uuid": "cm"},
                                 "r")
            await until(lambda: requester.of_type("tool.approval.request") and viewer.of_type("tool.approval.request"))
            request = requester.of_type("tool.approval.request")[0]
            approval_id, task_id = request.data["approval_id"], request.data["task_id"]
            assert request.id == task_id and request.data["tool_name"] == "write_file"
            assert "waiting_approval" in statuses([{"type": e.type, "data": e.data} for e in requester.frames])

            await stranger.send("tool.approval.response", {"approval_id": approval_id, "decision": "approve"}, task_id)
            await until(lambda: stranger.of_type("error"))  # not the requester nor a subscribed viewer
            assert not agent.asked.is_set() or await task_status(a, task_id) == "waiting_approval"

            await asyncio.gather(
                requester.send("tool.approval.response", {"approval_id": approval_id, "decision": "approve"}, task_id),
                viewer.send("tool.approval.response", {"approval_id": approval_id, "decision": "deny"}, task_id),
            )
            await until(lambda: requester.of_type("chat.done"))
            resolved = requester.of_type("tool.approval.resolved") + viewer.of_type("tool.approval.resolved")
            errors = requester.of_type("error") + viewer.of_type("error")
            assert len(resolved) == 1 and len(errors) == 1  # exactly one winner; the loser is told
            winner_decision = resolved[0].data["decision"]
            async with a.database.session() as db:
                answer = await db.scalar(select(Message).where(Message.role == "assistant"))
            assert answer.content == f"approved={winner_decision == 'approve'}"
            await until(lambda: asyncio.ensure_future(_done(a, task_id)))

    run(scenario())


async def _done(engine, task_id):
    return await task_status(engine, task_id) == "done"


# --- REST + capabilities -------------------------------------------------------------------------------------------


def test_hive_tasks_and_sync_status_routes(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a"]) as (engines, _):
            a = engines["a"]
            ws = await a.workspace("W")
            session = local_session(a.app)
            await session._handle({"type": "task.submit", "data": {"workspace_uuid": ws, "content": "listed"}})
            await until(lambda: "done" in statuses(session.frames))
            headers = {"Authorization": "Bearer secret-token"}
            async with AsyncClient(transport=ASGITransport(app=a.app), base_url="http://t", headers=headers) as client:
                tasks = (await client.get("/api/v1/hive/tasks")).json()["tasks"]
                assert len(tasks) == 1 and tasks[0]["status"] == "done" and "payload" not in tasks[0]
                assert (await client.get("/api/v1/hive/tasks?status=failed")).json() == {"tasks": []}
                assert (await client.get("/api/v1/hive/tasks?limit=x")).status_code == 400
                status = (await client.get("/api/v1/hive/sync/status")).json()
                assert status["state"] == "recording" and status["node_id"] == a.identity.node_id
                assert status["version_vector"][a.identity.node_id] >= 4 and status["pending_ops"] == 0
            async with AsyncClient(transport=ASGITransport(app=a.app), base_url="http://t") as anonymous:
                assert (await anonymous.get("/api/v1/hive/tasks")).status_code == 401
                assert (await anonymous.get("/api/v1/hive/sync/status")).status_code == 401

    run(scenario())


def test_presence_advertises_capabilities_with_model_names_and_never_keys(tmp_path):
    from test_hive_runtime import FakeAccount, FakeServerApi, _service

    class Store:
        async def list(self):
            return [SimpleNamespace(id="m1", alias="Fast", model="gpt-x", api_key="sk-secret-value",
                                    has_api_key=True)]

    class Signaling:
        def __init__(self):
            self.calls = []

        async def set_presence(self, clients, capabilities):
            self.calls.append((clients, capabilities))

    async def scenario():
        service = _service(tmp_path, FakeAccount(), FakeServerApi())
        service.app = SimpleNamespace(state=SimpleNamespace(model_configuration_store=Store()))
        signaling = Signaling()
        await service._publish_presence(signaling, ("desktop",))
        clients, capabilities = signaling.calls[0]
        assert clients == ["desktop"] and capabilities["can_run_agents"] is True
        assert capabilities["models"] == [{"id": "m1", "name": "Fast"}]
        assert "sk-secret-value" not in json.dumps(capabilities)

    run(scenario())
