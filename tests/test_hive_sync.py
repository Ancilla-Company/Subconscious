"""Phase 4 tests: migrations, HLC, signed change log, apply path, sync protocol."""

import asyncio
import json
import random
import sqlite3
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

import pytest
from hypothesis import HealthCheck, Phase, given, settings
from hypothesis import strategies as st
from sqlalchemy import select, text

from hive_testkit import MemEngine, connect, converged, make_entries, mesh, until
from subconscious_engine.hive.identity import NodeIdentity
from subconscious_engine.hive.sync.hlc import ClockSkewError, HybridClock, InvalidStamp, format_stamp, parse_stamp
from subconscious_engine.hive.sync.ops import SyncOp, canonical_payload, sign_op, verify_op
from subconscious_engine.storage import Database
from subconscious_engine.storage.models import (
    Contact,
    ConversationThread,
    Message,
    Note,
    SyncLog,
    SyncPending,
    Workspace,
)


def run(coro):
    return asyncio.run(coro)


# --- hybrid logical clock -------------------------------------------------------------


def test_hlc_is_monotonic_even_when_wall_time_stalls_or_goes_backwards():
    wall = [1_000]
    clock = HybridClock(lambda: wall[0])
    stamps = [clock.tick()]
    wall[0] = 1_000
    stamps.append(clock.tick())
    wall[0] = 900
    stamps.append(clock.tick())
    wall[0] = 2_000
    stamps.append(clock.tick())
    assert stamps == sorted(stamps) and len(set(stamps)) == 4
    assert parse_stamp(stamps[-1]) == (2_000, 0)
    assert format_stamp(5, 7) == "0000000000005.00007"


def test_hlc_observe_orders_after_remote_and_rejects_ops_over_five_minutes_ahead():
    wall = [10_000_000]
    clock = HybridClock(lambda: wall[0])
    ahead_ok = format_stamp(wall[0] + 4 * 60 * 1000, 3)
    assert clock.observe(ahead_ok) > ahead_ok
    assert clock.tick() > ahead_ok
    with pytest.raises(ClockSkewError):
        clock.observe(format_stamp(wall[0] + 5 * 60 * 1000 + 1, 0))
    with pytest.raises(InvalidStamp):
        clock.observe("not-a-stamp")
    # a rejected stamp never moves the clock
    assert parse_stamp(clock.last)[0] <= wall[0] + 4 * 60 * 1000


@settings(max_examples=60, deadline=None)
@given(st.lists(st.tuples(st.booleans(), st.integers(0, 10_000), st.integers(0, 50)), min_size=1, max_size=40))
def test_hlc_property_stamps_strictly_increase_and_dominate_observed(events):
    wall = [5_000]
    clock = HybridClock(lambda: wall[0], max_drift_ms=10**9)
    previous = ""
    for local, wall_value, counter in events:
        wall[0] = wall_value
        if local:
            stamp = clock.tick()
        else:
            remote = format_stamp(wall_value, counter)
            stamp = clock.observe(remote)
            assert stamp > remote
        assert stamp > previous
        previous = stamp


# --- migrations -----------------------------------------------------------------------------

OLD_SCHEMA = """
CREATE TABLE networks (id INTEGER PRIMARY KEY, uuid VARCHAR NOT NULL UNIQUE, name VARCHAR NOT NULL,
  description TEXT, default_workspace_uuid VARCHAR, passphrase VARCHAR, created_at DATETIME NOT NULL);
CREATE TABLE workspaces (id INTEGER PRIMARY KEY, name VARCHAR NOT NULL, description TEXT,
  network_id INTEGER NOT NULL REFERENCES networks(id) ON DELETE CASCADE, uuid VARCHAR NOT NULL UNIQUE,
  tools_config TEXT, skills_config TEXT, directories TEXT, approval_config TEXT, rag_config TEXT,
  default_model_id VARCHAR, updated_at DATETIME NOT NULL, created_at DATETIME NOT NULL);
CREATE TABLE threads (id INTEGER PRIMARY KEY, uuid VARCHAR NOT NULL UNIQUE,
  workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE, title VARCHAR, description TEXT,
  default_model_id VARCHAR, tools_config TEXT, skills_config TEXT, approval_config TEXT,
  updated_at DATETIME NOT NULL, created_at DATETIME NOT NULL);
CREATE TABLE messages (id INTEGER PRIMARY KEY, uuid VARCHAR NOT NULL UNIQUE,
  thread_id INTEGER NOT NULL REFERENCES threads(id) ON DELETE CASCADE, role VARCHAR NOT NULL,
  content TEXT NOT NULL, created_at DATETIME NOT NULL);
CREATE TABLE todo_items (id INTEGER PRIMARY KEY, workspace_id INTEGER NOT NULL, thread_id INTEGER,
  title VARCHAR NOT NULL, notes TEXT, status VARCHAR NOT NULL, priority VARCHAR NOT NULL, due_date DATETIME,
  created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL);
CREATE TABLE workspace_memory (id INTEGER PRIMARY KEY, workspace_id INTEGER NOT NULL, key VARCHAR NOT NULL,
  value TEXT NOT NULL, source_thread_id INTEGER, created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL);
CREATE TABLE notes (id INTEGER PRIMARY KEY, workspace_id INTEGER NOT NULL, title VARCHAR NOT NULL,
  content TEXT NOT NULL, tags TEXT, created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL);
CREATE TABLE contacts (id INTEGER PRIMARY KEY, workspace_id INTEGER NOT NULL, name VARCHAR NOT NULL,
  email VARCHAR, phone VARCHAR, notes TEXT, created_at DATETIME NOT NULL, updated_at DATETIME NOT NULL);
INSERT INTO networks VALUES (1, 'net-1', 'default', NULL, NULL, NULL, '2024-01-01 00:00:00.000000');
INSERT INTO workspaces (id, name, network_id, uuid, updated_at, created_at)
  VALUES (1, 'Old workspace', 1, 'ws-old', '2024-02-02 10:00:00.500000', '2024-01-01 00:00:00.000000');
INSERT INTO threads (id, uuid, workspace_id, title, updated_at, created_at)
  VALUES (1, 'th-old', 1, 'Old thread', '2024-03-03 10:00:00.000000', '2024-01-02 00:00:00.000000');
INSERT INTO messages VALUES (1, 'm-1', 1, 'user', 'first', '2024-01-02 00:00:01.000000');
INSERT INTO messages VALUES (2, 'm-2', 1, 'assistant', 'second', '2024-01-02 00:00:02.000000');
INSERT INTO notes (id, workspace_id, title, content, created_at, updated_at)
  VALUES (1, 1, 'n1', 'c', '2024-01-01 00:00:00', '2024-01-01 00:00:00'), (2, 1, 'n2', 'c', '2024-01-01 00:00:00', '2024-01-01 00:00:00');
INSERT INTO contacts (id, workspace_id, name, created_at, updated_at)
  VALUES (1, 1, 'Ada', '2024-01-01 00:00:00', '2024-01-01 00:00:00');
"""


def _old_database(path: Path) -> None:
    connection = sqlite3.connect(path)
    connection.executescript(OLD_SCHEMA)
    connection.commit()
    connection.close()


def test_migration_upgrades_existing_database_with_backup_and_is_idempotent(tmp_path):
    path = tmp_path / "subconscious.db"
    _old_database(path)

    async def scenario():
        database = Database(path)
        await database.initialize()
        backup = database.last_backup
        assert backup is not None and backup.exists() and backup.name.startswith("subconscious.db.bak-")
        original = sqlite3.connect(backup)
        assert original.execute("SELECT count(*) FROM messages").fetchone()[0] == 2
        assert "hlc" not in [r[1] for r in original.execute("PRAGMA table_info(messages)")]
        original.close()
        async with database.session() as session:
            workspace = await session.scalar(select(Workspace))
            assert workspace.origin_node_id is None and workspace.deleted_at is None
            expected_ms = int(datetime(2024, 2, 2, 10, 0, 0, 500000, tzinfo=timezone.utc).timestamp() * 1000)
            assert workspace.hlc == format_stamp(expected_ms, 0)
            notes = (await session.scalars(select(Note))).all()
            uuids = {n.uuid for n in notes} | {c.uuid for c in (await session.scalars(select(Contact))).all()}
            assert len(uuids) == 3 and all(len(u) == 36 for u in uuids)
            messages = (await session.scalars(select(Message).order_by(Message.id))).all()
            assert messages[0].hlc < messages[1].hlc  # derived from created_at, order preserved
            versions = [r[0] for r in (await session.execute(text("SELECT version FROM schema_migrations")))]
            assert versions == [1, 2, 3]
            for table in ("sync_log", "sync_state", "sync_pending", "sync_field_clock", "tasks", "hive_meta",
                          "remote_tool_audit"):
                await session.execute(text(f"SELECT count(*) FROM {table}"))
        before = sorted(uuids)
        await database.close()

        again = Database(path)  # a second start: nothing pending, no new backup, same uuids
        await again.initialize()
        assert again.last_backup is None
        async with again.session() as session:
            after = {n.uuid for n in (await session.scalars(select(Note))).all()}
            after |= {c.uuid for c in (await session.scalars(select(Contact))).all()}
            assert sorted(after) == before
        await again.close()
        assert len(list(tmp_path.glob("subconscious.db.bak-*"))) == 1

    run(scenario())


def test_migration_one_is_safe_to_rerun_after_an_interrupted_upgrade(tmp_path):
    path = tmp_path / "subconscious.db"
    _old_database(path)
    connection = sqlite3.connect(path)  # half applied: some columns exist already
    connection.execute("ALTER TABLE threads ADD COLUMN hlc TEXT")
    connection.execute("ALTER TABLE notes ADD COLUMN uuid TEXT")
    connection.commit()
    connection.close()

    async def scenario():
        database = Database(path)
        await database.initialize()
        async with database.session() as session:
            assert (await session.scalar(select(ConversationThread))).hlc is not None
            assert all(n.uuid for n in (await session.scalars(select(Note))).all())
        await database.close()

    run(scenario())


def test_fresh_database_is_created_current_without_a_backup(tmp_path):
    async def scenario():
        database = Database(tmp_path / "fresh.db")
        await database.initialize()
        assert database.last_backup is None
        async with database.session() as session:
            assert [r[0] for r in await session.execute(text("SELECT version FROM schema_migrations"))] == [1, 2, 3]
        await database.close()
        assert not list(tmp_path.glob("*.bak-*"))

    run(scenario())


# --- signed ops ------------------------------------------------------------------------------


def test_op_signature_binds_every_field_of_the_op():
    identity = NodeIdentity.generate()
    op = sign_op(identity, 7, "thread", "t-1", "update", format_stamp(1, 0), {"title": "x"})
    assert verify_op(op, identity.public_key)
    assert op.message().startswith(b"sc-op-v1\n" + identity.node_id.encode() + b"\n7\nthread\nt-1\nupdate\n")
    for tampered in (
        SyncOp(op.origin, 8, op.entity, op.uuid, op.op, op.hlc, op.payload, op.sig),
        SyncOp(op.origin, op.seq, "message", op.uuid, op.op, op.hlc, op.payload, op.sig),
        SyncOp(op.origin, op.seq, op.entity, "t-2", op.op, op.hlc, op.payload, op.sig),
        SyncOp(op.origin, op.seq, op.entity, op.uuid, "delete", op.hlc, op.payload, op.sig),
        SyncOp(op.origin, op.seq, op.entity, op.uuid, op.op, format_stamp(2, 0), op.payload, op.sig),
        SyncOp(op.origin, op.seq, op.entity, op.uuid, op.op, op.hlc, {"title": "y"}, op.sig),
        SyncOp("n_other", op.seq, op.entity, op.uuid, op.op, op.hlc, op.payload, op.sig),
    ):
        assert not verify_op(tampered, identity.public_key)
    assert not verify_op(op, NodeIdentity.generate().public_key)
    assert canonical_payload({"b": 1, "a": 2}) == '{"a":2,"b":1}'


def _wire(op):
    return SyncOp.from_wire(json.loads(json.dumps(op.to_wire())))


def test_apply_rejects_tampering_forged_origin_inactive_origin_and_clock_skew(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a", "b"], thin=["t"]) as (engines, thins):
            a, b = engines["a"], engines["b"]
            ws = await a.workspace("Shared")
            ops = await a.engine.read_ops({})
            create = next(o for o in ops if o.entity == "workspace")

            tampered = SyncOp(create.origin, create.seq, create.entity, create.uuid, create.op, create.hlc,
                              {**create.payload, "name": "Evil"}, create.sig)
            report = await b.engine.apply([tampered])
            assert [r for _, r in report.rejected] == ["bad_signature"] and not report.accepted

            intruder = NodeIdentity.generate()  # signs with its own key but claims to be A
            forged = sign_op(intruder, create.seq, "workspace", create.uuid, "create", create.hlc, create.payload)
            claimed = SyncOp(a.identity.node_id, forged.seq, forged.entity, forged.uuid, forged.op, forged.hlc,
                             forged.payload, forged.sig)
            assert [r for _, r in (await b.engine.apply([claimed])).rejected] == ["bad_signature"]

            unknown = sign_op(intruder, 1, "workspace", "w-x", "create", create.hlc, {"name": "x"})
            assert [r for _, r in (await b.engine.apply([unknown])).rejected] == ["origin_not_active"]

            thin = sign_op(thins["t"], 1, "workspace", "w-y", "create", create.hlc, {"name": "y"})
            assert [r for _, r in (await b.engine.apply([thin])).rejected] == ["origin_not_engine"]

            # an op naming B itself as origin that B never issued is a forgery
            fake_self = sign_op(b.identity, 999, "workspace", "w-z", "create", create.hlc, {"name": "z"})
            assert [r for _, r in (await b.engine.apply([fake_self])).rejected] == ["forged_origin"]

            future = format_stamp(int(time.time() * 1000) + 6 * 60 * 1000, 0)
            skewed = sign_op(a.identity, 500, "workspace", "w-s", "create", future, {"name": "s"})
            assert [r for _, r in (await b.engine.apply([skewed])).rejected] == ["clock_skew"]

            async with b.database.session() as session:
                assert await session.scalar(select(Workspace).where(Workspace.uuid == ws)) is None
                assert await session.scalar(select(Workspace)) is None
            good = await b.engine.apply([create])
            assert len(good.accepted) == 1 and not good.rejected
            assert (await b.engine.apply([_wire(create)])).duplicates == 1

    run(scenario())


def test_apply_rejects_ops_from_a_revoked_node(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a", "b"]) as (engines, _):
            a, b = engines["a"], engines["b"]
            await a.workspace("Before revoke")
            ops = await a.engine.read_ops({})
            revoked = [dict(e, status="revoked") if e["id"] == a.identity.node_id else e
                       for e in make_entries(a.identity, (b.identity, "engine"))]
            b.directory.update(revoked, "hive-1")
            report = await b.engine.apply(ops)
            assert report.accepted == [] and {r for _, r in report.rejected} == {"origin_not_active"}

    run(scenario())


def test_machine_local_workspace_fields_never_enter_payloads_or_get_applied(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a", "b"]) as (engines, _):
            a, b = engines["a"], engines["b"]
            ws = await a.workspace("Local fields")
            async with a.database.session() as session:
                row = await session.scalar(select(Workspace).where(Workspace.uuid == ws))
                row.directories, row.tools_config = '["C:/secret"]', '{"x":1}'
                row.approval_config, row.rag_config = '{"mode":"loose"}', '{"r":1}'
                row.description = "shared description"
                await session.commit()
            async with a.database.session() as session:
                payloads = [json.loads(r.payload) for r in (await session.scalars(
                    select(SyncLog).where(SyncLog.entity == "workspace"))).all()]
            blob = json.dumps(payloads)
            for secret in ("directories", "tools_config", "approval_config", "rag_config", "C:/secret", "loose"):
                assert secret not in blob
            assert any(p.get("description") == "shared description" for p in payloads)
            # a hostile (but validly signed) op carrying local fields must not set them remotely
            create = next(o for o in await a.engine.read_ops({}) if o.entity == "workspace" and o.op == "create")
            hostile = sign_op(a.identity, 900, "workspace", ws, "update", format_stamp(int(time.time() * 1000) + 5, 0),
                              {"name": "Renamed", "directories": "/etc", "approval_config": "{}"})
            await b.engine.apply([create, hostile])
            async with b.database.session() as session:
                mirrored = await session.scalar(select(Workspace).where(Workspace.uuid == ws))
                assert mirrored.name == "Renamed"
                assert mirrored.directories is None and mirrored.approval_config is None

    run(scenario())


# --- parking, ordering, per-field LWW -------------------------------------------------------------


def test_ops_with_a_missing_parent_are_parked_and_applied_when_the_parent_arrives(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a", "b"]) as (engines, _):
            a, b = engines["a"], engines["b"]
            ws = await a.workspace("P")
            thread = await a.thread(ws)
            message = await a.message(thread, "hello")
            ops = await a.engine.read_ops({})
            by_entity = {o.entity: o for o in ops}
            report = await b.engine.apply([by_entity["message"]])
            assert report.parked == 1
            report = await b.engine.apply([by_entity["thread"]])
            assert report.parked == 1
            async with b.database.session() as session:
                assert len((await session.scalars(select(SyncPending))).all()) == 2
                assert await session.scalar(select(Message)) is None
            await b.engine.apply([by_entity["workspace"]])
            async with b.database.session() as session:
                assert (await session.scalars(select(SyncPending))).all() == []
                assert (await session.scalar(select(Message).where(Message.uuid == message))).content == "hello"
            assert (await b.engine.version_vector())[a.identity.node_id] == max(o.seq for o in ops)

    run(scenario())


def test_thread_fields_merge_last_writer_wins_per_field_with_node_id_tiebreak(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a", "b", "c"]) as (engines, _):
            a, b, c = engines["a"], engines["b"], engines["c"]
            ws = await a.workspace("W")
            thread = await a.thread(ws, "start")
            for source in (a,):
                ops = await source.engine.read_ops({})
                await b.engine.apply(ops)
                await c.engine.apply(ops)
            # concurrent edits of different fields and a same-field conflict
            async with a.database.session() as session:
                row = await session.scalar(select(ConversationThread).where(ConversationThread.uuid == thread))
                row.description = "from a"
                row.title = "title-a"
                await session.commit()
            async with b.database.session() as session:
                row = await session.scalar(select(ConversationThread).where(ConversationThread.uuid == thread))
                row.default_model_id = "model-b"
                row.title = "title-b"
                await session.commit()
            for left, right in ((a, b), (b, a), (a, c), (b, c), (c, a), (c, b)):
                await right.engine.apply(await left.engine.read_ops({}))
            prints = [await e.fingerprint() for e in (a, b, c)]
            assert prints[0] == prints[1] == prints[2]
            _, title, description, model, _ = prints[0]["threads"][thread]
            assert description == "from a" and model == "model-b"
            assert title in {"title-a", "title-b"}

    run(scenario())


def test_rest_message_listing_orders_by_hlc_origin_uuid_not_by_local_id(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a", "b"]) as (engines, _):
            a, b = engines["a"], engines["b"]
            ws = await a.workspace("Order")
            thread = await a.thread(ws)
            await b.engine.apply(await a.engine.read_ops({}))
            # b writes older-hlc-less messages first locally, then a's arrive: ids differ from hlc order
            first = await a.message(thread, "a1")
            second = await a.message(thread, "a2")
            ops = [o for o in await a.engine.read_ops({}) if o.entity == "message"]
            await b.engine.apply(list(reversed(ops)))  # arrives (and gets local ids) in reverse
            from httpx import ASGITransport, AsyncClient

            async with AsyncClient(transport=ASGITransport(app=b.app), base_url="http://t",
                                   headers={"Authorization": "Bearer secret-token"}) as client:
                listing = (await client.get(f"/api/v1/threads/{thread}/messages")).json()
            assert [m["uuid"] for m in listing] == [first, second]

    run(scenario())


# --- convergence (property based) ---------------------------------------------------------------------

ACTIONS = st.lists(
    st.tuples(st.integers(0, 2), st.sampled_from(["ws", "thread", "msg", "rename", "del_thread", "del_ws"]),
              st.integers(0, 50), st.integers(0, 10_000)),
    min_size=3, max_size=22,
)


async def _perform(engine, kind, pick, salt):
    async with engine.database.session() as session:
        workspaces = [w.uuid for w in (await session.scalars(
            select(Workspace).where(Workspace.deleted_at.is_(None)).order_by(Workspace.uuid))).all()]
        threads = [t.uuid for t in (await session.scalars(
            select(ConversationThread).where(ConversationThread.deleted_at.is_(None))
            .order_by(ConversationThread.uuid))).all()]
    if kind == "ws" or not workspaces:
        await engine.workspace(f"ws-{salt}")
    elif kind == "thread":
        await engine.thread(workspaces[pick % len(workspaces)], f"t-{salt}")
    elif kind == "msg" and threads:
        await engine.message(threads[pick % len(threads)], f"m-{salt}")
    elif kind == "rename" and threads:
        await engine.rename(threads[pick % len(threads)], f"r-{salt}")
    elif kind == "del_thread" and threads:
        await engine.delete_thread(threads[pick % len(threads)])
    elif kind == "del_ws":
        await engine.delete_workspace(workspaces[pick % len(workspaces)])


async def _transfer(source, target, rng, *, duplicate=False):
    """Move everything ``target`` lacks from ``source``'s log in a random order."""
    vv = await target.engine.version_vector()
    ops = await source.engine.read_ops(vv, max_ops=10_000, max_bytes=10**9)
    rng.shuffle(ops)
    await target.engine.apply(ops)
    if duplicate:
        await target.engine.apply(ops)


@settings(
    max_examples=12,
    deadline=None,
    derandomize=True,
    # Each example builds three databases, so shrinking a failure would run for minutes.
    phases=[Phase.explicit, Phase.generate],
    suppress_health_check=[HealthCheck.too_slow, HealthCheck.data_too_large],
)
@given(actions=ACTIONS, seed=st.integers(0, 2**31), topology=st.sampled_from(["mesh", "chain"]))
def test_three_nodes_converge_under_random_orders_duplicates_partitions_and_forwarding(actions, seed, topology):
    rng = random.Random(seed)

    async def scenario(directory):
        async with mesh(Path(directory), ["a", "b", "c"]) as (engines, _):
            nodes = [engines["a"], engines["b"], engines["c"]]
            edges = ([(0, 1), (1, 0), (0, 2), (2, 0), (1, 2), (2, 1)] if topology == "mesh"
                     else [(0, 1), (1, 0), (1, 2), (2, 1)])  # a and c never talk directly
            for index, (who, kind, pick, salt) in enumerate(actions):
                await _perform(nodes[who], kind, pick, salt)
                if rng.random() < 0.4:  # partitions: only some transfers happen mid-run
                    left, right = rng.choice(edges)
                    await _transfer(nodes[left], nodes[right], rng, duplicate=rng.random() < 0.3)
            for _ in range(3):  # heal: repeated rounds along the edges (b forwards between a and c)
                for left, right in edges:
                    await _transfer(nodes[left], nodes[right], rng, duplicate=rng.random() < 0.3)
            prints = [await node.fingerprint() for node in nodes]
            assert prints[0] == prints[1] == prints[2]
            for node in nodes:
                async with node.database.session() as session:
                    assert (await session.scalars(select(SyncPending))).all() == []

    with tempfile.TemporaryDirectory() as directory:
        run(scenario(directory))


# --- protocol over links -----------------------------------------------------------------------------------


def test_live_push_and_transitive_forwarding_reach_a_node_that_is_never_connected_to_the_origin(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a", "b", "c"]) as (engines, _):
            a, b, c = engines["a"], engines["b"], engines["c"]
            connect(a, b)
            connect(b, c)
            assert await a.node.coordinator.wait_ready(b.identity.node_id)
            assert await c.node.coordinator.wait_ready(b.identity.node_id)
            ws = await a.workspace("Forwarded")
            thread = await a.thread(ws, "via b")
            await a.message(thread, "hi c")
            fingerprint = await converged(a, b, c)
            assert thread in fingerprint["threads"] and len(fingerprint["messages"]) == 1
            assert a.identity.node_id not in c.peers.links  # truly transitive

    run(scenario())


def test_catch_up_is_batched_acknowledged_and_resumable_after_a_partition(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a", "b"]) as (engines, _):
            a, b = engines["a"], engines["b"]
            ws = await a.workspace("Bulk")
            thread = await a.thread(ws)
            for index in range(25):
                await a.message(thread, f"m{index}")
            for state in (a.node.coordinator, b.node.coordinator):
                state.batch_ops = 4
            la, lb = connect(a, b)
            await asyncio.sleep(0.02)  # a few batches flow, then the link is cut mid catch-up
            la.drop = lb.drop = True
            await la.close()
            a.node.on_link_closed(b.identity.node_id)
            b.node.on_link_closed(a.identity.node_id)
            la2, lb2 = connect(a, b)  # a fresh link resumes from the version vectors
            fingerprint = await converged(a, b)
            assert len(fingerprint["messages"]) == 25
            sizes = [len(env.data["ops"]) for ch, env in la2.sent + la.sent if env.type == "sync.ops"]
            assert sizes and max(sizes) <= 4
            acks = [env for ch, env in lb2.sent + lb.sent if env.type == "sync.ack"]
            assert acks and all({"batch", "origin", "seq"} <= set(env.data) for env in acks)

    run(scenario())


def test_hive_id_mismatch_closes_the_session_and_nothing_is_synced(tmp_path):
    async def scenario():
        identities = [NodeIdentity.generate(), NodeIdentity.generate()]
        entries = make_entries(identities[0], (identities[1], "engine"))
        a = MemEngine(tmp_path, "a", identities[0], entries, hive_id="hive-1")
        b = MemEngine(tmp_path, "b", identities[1], entries, hive_id="hive-2")
        await a.start()
        await b.start()
        try:
            await a.workspace("secret of hive 1")
            la, lb = connect(a, b)
            await until(lambda: la.closed.is_set() and lb.closed.is_set())
            assert (await b.fingerprint())["workspaces"] == {}
        finally:
            await a.stop()
            await b.stop()

    run(scenario())


def test_stored_hive_id_blocks_a_different_account_and_reset_local_clears_it(tmp_path):
    async def scenario():
        identity = NodeIdentity.generate()
        entries = make_entries(identity)
        first = MemEngine(tmp_path, "x", identity, entries, hive_id="hive-1")
        await first.start()
        ws = await first.workspace("Mine")
        await first.stop()

        again = MemEngine(tmp_path, "x", identity, entries, hive_id="hive-2")
        await again.database.initialize()
        assert not await again.node.start("hive-2")
        assert again.engine.blocked == "hive_mismatch" and not again.engine.recording
        report = await again.engine.apply([])
        assert report.accepted == []
        from httpx import ASGITransport, AsyncClient

        class StubService:
            state, detail, node = "hive_mismatch", "This data directory belongs to a different hive.", None

        again.app.state.hive_service = StubService()
        async with AsyncClient(transport=ASGITransport(app=again.app), base_url="http://t",
                               headers={"Authorization": "Bearer secret-token"}) as client:
            status = (await client.get("/api/v1/hive/sync/status")).json()
        assert status["state"] == "hive_mismatch" and "different hive" in status["detail"]
        # local data is untouched while blocked, and a reset lets the machine join another hive
        await again.workspace("Still works locally")
        await again.engine.reset_local()
        assert await again.engine.get_meta("hive_id") is None
        assert await again.node.start("hive-2")
        names = {v[0] for v in (await again.fingerprint())["workspaces"].values()}
        assert names == {"Mine", "Still works locally"} and ws in (await again.fingerprint())["workspaces"]
        await again.stop()

    run(scenario())


def test_thin_clients_cannot_use_sync_frames(tmp_path):
    from subconscious_engine.hive import authz

    assert not authz.authorize_frame(authz.THIN_CLIENT, "sync.hello")
    assert authz.authorize_frame(authz.HIVE_PEER, "sync.hello")

    async def scenario():
        from hive_testkit import MemThin

        async with mesh(tmp_path, ["a"], thin=["t"]) as (engines, thins):
            a = engines["a"]
            thin = MemThin(a, thins["t"])
            await a.workspace("hidden")
            await thin.send("sync.hello", {"hive_id": "hive-1", "vv": {}, "schema_version": 1})
            await until(lambda: thin.of_type("error"))
            assert not thin.of_type("sync.ops") and not thin.of_type("sync.hello")

    run(scenario())


# --- tombstones and snapshots ---------------------------------------------------------------------------------


def test_tombstones_hide_deleted_rows_and_are_purged_after_retention(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a", "b"]) as (engines, _):
            a, b = engines["a"], engines["b"]
            ws = await a.workspace("Keep")
            doomed = await a.thread(ws, "doomed")
            await a.message(doomed, "bye")
            await b.engine.apply(await a.engine.read_ops({}))
            await a.delete_thread(doomed)
            await b.engine.apply(await a.engine.read_ops(await b.engine.version_vector()))
            for node in (a, b):
                fingerprint = await node.fingerprint()
                assert fingerprint["threads"][doomed][4] is True
            from httpx import ASGITransport, AsyncClient

            async with AsyncClient(transport=ASGITransport(app=b.app), base_url="http://t",
                                   headers={"Authorization": "Bearer secret-token"}) as client:
                assert (await client.get(f"/api/v1/workspaces/{ws}/threads")).json() == []
                assert (await client.get(f"/api/v1/threads/{doomed}/messages")).json() == []
            assert await a.engine.purge_tombstones(now=time.time() + 5 * 86400) == 0
            assert await a.engine.purge_tombstones(now=time.time() + 31 * 86400) >= 2
            fingerprint = await a.fingerprint()
            assert doomed not in fingerprint["threads"] and fingerprint["messages"] == {}
            assert (await a.engine.floor())[a.identity.node_id] > 0

    run(scenario())


def test_peer_behind_the_tombstone_horizon_gets_a_snapshot_and_drops_deleted_entities(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a", "b"]) as (engines, _):
            a, b = engines["a"], engines["b"]
            ws = await a.workspace("Snap")
            keep = await a.thread(ws, "keep")
            gone = await a.thread(ws, "gone")
            await a.message(gone, "old")
            await a.message(keep, "stays")
            await b.engine.apply(await a.engine.read_ops({}))  # b is in sync, then goes offline
            await a.delete_thread(gone)
            late = await a.thread(ws, "created while b was away")
            await a.engine.purge_tombstones(now=time.time() + 40 * 86400)
            assert await a.engine.needs_snapshot(await b.engine.version_vector())
            connect(a, b)
            await until(lambda: any(s.phase == "ready" for s in a.node.coordinator.peers.values()))

            async def live_state(node):
                # Tombstones are purged per node on their own schedule, so a node that purged
                # ``gone`` may legitimately differ from one still holding the tombstone.
                # Convergence is about live entities.
                fp = await node.fingerprint()
                threads = {k: v for k, v in fp["threads"].items() if not v[4]}
                messages = {k: v for k, v in fp["messages"].items() if not v[3] and v[0] in threads}
                return threads, messages

            async def same_live():
                return await live_state(a) == await live_state(b)

            await until(same_live)
            fingerprint = await b.fingerprint()
            assert gone not in fingerprint["threads"] or fingerprint["threads"][gone][4] is True
            assert keep in fingerprint["threads"] and late in fingerprint["threads"]
            # the stale replica must not resurrect the purged thread on the origin
            assert gone not in (await a.fingerprint())["threads"]

    run(scenario())
