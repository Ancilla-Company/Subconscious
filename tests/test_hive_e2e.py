"""Phase 4 end to end: three engines + a thin client over real aiortc links.

The in-memory signalling hub is the one the Phase 2 loopback tests use; only the
signalling server is faked, ICE/DTLS/SCTP data channels are real.
"""

import asyncio

from sqlalchemy import select

from hive_testkit import MemEngine, converged, make_entries, until
from subconscious_engine.api.websocket import WebSocketSession
from subconscious_engine.hive.identity import NodeIdentity
from subconscious_engine.hive.peers import PeerManager
from subconscious_engine.storage.models import Message, TaskRecord
from test_hive import FakeHub, no_ice
from test_hive_tasks import FakeSocket


def run(coro):
    return asyncio.run(coro)


def test_three_engines_and_a_thin_client_converge_after_a_task_from_the_phone(tmp_path):
    async def scenario():
        a_id, b_id, c_id, phone = (NodeIdentity.generate() for _ in range(4))
        entries = make_entries(a_id, (b_id, "engine"), (c_id, "engine"), (phone, "thin"))
        engines = {name: MemEngine(tmp_path, name, ident, entries) for name, ident in
                   (("a", a_id), ("b", b_id), ("c", c_id))}
        hub = FakeHub()
        managers = {}
        for name, engine in engines.items():
            await engine.start()
            manager = PeerManager(engine.identity, engine.directory, hub.signaler_for(engine.identity.node_id),
                                  no_ice, on_link=engine.node.on_link, on_link_closed=engine.node.on_link_closed)
            engine.node.peers = manager
            hub.managers[engine.identity.node_id] = manager
            managers[name] = manager

        from test_hive import make_directory

        inbox = asyncio.Queue()
        phone_manager = PeerManager(phone, make_directory(phone, *entries), hub.signaler_for(phone.node_id), no_ice,
                                    on_link=lambda link: setattr(link, "handler", lambda lk, ch, env: inbox.put_nowait(env)))
        hub.managers[phone.node_id] = phone_manager
        a, b, c = engines["a"], engines["b"], engines["c"]
        try:
            # a - b - c: a and c are never linked directly, so c only learns through b
            await asyncio.wait_for(managers["a"].connect(b_id.node_id), 60)
            await asyncio.wait_for(managers["c"].connect(b_id.node_id), 60)
            assert await a.node.coordinator.wait_ready(b_id.node_id, 30)
            assert await c.node.coordinator.wait_ready(b_id.node_id, 30)
            assert await b.node.coordinator.wait_ready(a_id.node_id, 30)
            assert await b.node.coordinator.wait_ready(c_id.node_id, 30)

            workspace = await a.workspace("Shared hive workspace")
            thread = await a.thread(workspace, "Phone thread")
            await converged(a, b, c)

            # c watches the thread through its own local client session
            watcher = WebSocketSession(FakeSocket(c.app))
            await watcher._handle({"type": "thread.subscribe", "data": {"thread_uuid": thread}})
            await until(lambda: any(f["type"] == "thread.subscribed" for f in watcher.socket.sent))
            await until(lambda: thread in b.app.state.task_manager.viewers)

            # the phone (thin_client role) is connected to b and asks b to run a task
            link = await asyncio.wait_for(phone_manager.connect(b_id.node_id), 60)
            assert link.role == "hive_peer"  # how the phone sees b; b sees the phone as thin_client
            assert b.node.link(phone.node_id).role == "thin_client"
            await link.send_frame("control", "task.submit", {
                "thread_uuid": thread, "content": "hello from the phone", "client_msg_uuid": "phone-msg-1",
                "executor": b_id.node_id}, "req-1")

            frames = []
            while not any(f.type == "chat.done" for f in frames):
                frames.append(await asyncio.wait_for(inbox.get(), 60))
            accepted = next(f for f in frames if f.type == "task.accepted")
            task_id = accepted.data["task_id"]
            assert accepted.id == "req-1"
            deltas = "".join(f.data["delta"] for f in frames if f.type == "chat.delta")
            assert "hello from the phone" in deltas

            fingerprint = await converged(a, b, c, timeout=60)
            assert fingerprint["tasks"][task_id][1:4] == (b_id.node_id, phone.node_id, "done")
            assert len(fingerprint["order"][thread]) == 2 and "phone-msg-1" in fingerprint["messages"]
            for engine in (a, b, c):
                rows = await engine.task_rows()
                assert [(r.task_id, r.status) for r in rows] == [(task_id, "done")]
                async with engine.database.session() as db:
                    roles = [m.role for m in (await db.scalars(select(Message))).all()]
                    assert sorted(roles) == ["assistant", "user"]

            # c's local viewer saw the run live, via b (not via sync)
            await until(lambda: any(f["type"] == "task.status" and f["data"]["status"] == "done"
                                    for f in watcher.socket.sent), 30)
            assert "hello from the phone" in "".join(
                f["data"]["delta"] for f in watcher.socket.sent if f["type"] == "chat.delta")
        finally:
            await phone_manager.close()
            for manager in managers.values():
                await manager.close()
            for engine in engines.values():
                await engine.stop()

    run(scenario())


def test_partitioned_engines_converge_after_reconnecting(tmp_path):
    async def scenario():
        a_id, b_id = NodeIdentity.generate(), NodeIdentity.generate()
        entries = make_entries(a_id, (b_id, "engine"))
        a, b = (MemEngine(tmp_path, n, i, entries) for n, i in (("a", a_id), ("b", b_id)))
        hub = FakeHub()
        managers = []
        for engine in (a, b):
            await engine.start()
            manager = PeerManager(engine.identity, engine.directory, hub.signaler_for(engine.identity.node_id),
                                  no_ice, on_link=engine.node.on_link, on_link_closed=engine.node.on_link_closed)
            engine.node.peers = manager
            hub.managers[engine.identity.node_id] = manager
            managers.append(manager)
        try:
            ws_a = await a.workspace("written while apart (a)")
            ws_b = await b.workspace("written while apart (b)")
            await a.thread(ws_a, "ta")
            await b.thread(ws_b, "tb")
            await asyncio.wait_for(managers[0].connect(b_id.node_id), 60)
            fingerprint = await converged(a, b, timeout=60)
            assert {ws_a, ws_b} <= set(fingerprint["workspaces"]) and len(fingerprint["threads"]) == 2
            # split again, diverge, heal
            await managers[0].close_peer(b_id.node_id)
            await until(lambda: a.node.link(b_id.node_id) is None and b.node.link(a_id.node_id) is None, 30)
            await a.rename(next(iter(fingerprint["threads"])), "renamed while apart")
            await b.workspace("another")
            await asyncio.wait_for(managers[1].connect(a_id.node_id), 60)
            await converged(a, b, timeout=60)
        finally:
            for manager in managers:
                await manager.close()
            for engine in (a, b):
                await engine.stop()

    run(scenario())
