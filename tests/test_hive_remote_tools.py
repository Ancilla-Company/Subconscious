"""Phase 5 tests: remote tool calls between hive peers (webrtc.md section 8)."""

import asyncio
import hashlib
import json
import os
import re
from contextlib import asynccontextmanager
from dataclasses import replace
from types import SimpleNamespace

import pytest
from httpx import ASGITransport, AsyncClient
from pydantic_ai.messages import ToolCallPart
from sqlalchemy import func, select, text
from sqlalchemy.exc import DBAPIError

from hive_testkit import MemLink, MemThin, connect, entry, mesh, until
from subconscious_engine.agents import AgentExecutionResult
from subconscious_engine.api.websocket import WebSocketSession
from subconscious_engine.approval import DELETE, READ, ApprovalConfig, classify_operation
from subconscious_engine.config import RemoteToolsConfig, remote_tools_from_mapping
from subconscious_engine.configuration_file import (
    ConfigurationFileError,
    load_configuration,
    show_configuration,
)
from subconscious_engine.hive import authz
from subconscious_engine.hive.channels import Envelope
from subconscious_engine.hive.remote_tools import (
    RemoteToolService,
    args_sha256,
    assign_aliases,
    remote_nodes_from_config,
    sanitize_alias,
)
from subconscious_engine.hive.service import HiveService
from subconscious_engine.storage.models import (
    ConversationThread,
    Message,
    RemoteToolAudit,
    SyncLog,
    Workspace,
)
from subconscious_engine.tools.filesystem_tools import OutsideRootsError, scoped_resolver
from subconscious_engine.tools.registry import ToolSpec


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


async def local_client(engine, client_id="ui"):
    """A UI connected to ``engine`` that is registered for broadcasts."""
    session = local_session(engine.app)
    await session._handle({"type": "client.hello", "data": {"clientId": client_id}})
    return session


def of_type(session, frame_type):
    return [f for f in session.frames if f["type"] == frame_type]


@asynccontextmanager
async def pair(tmp_path, **options):
    """Owner ``a`` and executor ``b`` connected; ``la`` is a's link to b, ``lb`` b's link to a."""
    async with mesh(tmp_path, ["a", "b"], **options) as (engines, _):
        a, b = engines["a"], engines["b"]
        la, lb = connect(a, b)
        yield a, b, la, lb


async def send_call(lb, tool, args, call_id="c1", task_id="task-1", **extra):
    await lb.send("control", Envelope("tool.call", {
        "call_id": call_id, "task_id": task_id, "tool": tool, "args": args, **extra}))


async def get_result(la, call_id="c1"):
    def find():
        for _channel, envelope in la.sent:
            if envelope.type == "tool.result" and envelope.data.get("call_id") == call_id:
                return envelope.data
        return None

    await until(lambda: find() is not None)
    return find()


async def list_tools(la, lb, request_id="l1"):
    await lb.send("control", Envelope("tool.list", {}, request_id))

    def find():
        for _channel, envelope in la.sent:
            if envelope.type == "tool.list.result" and envelope.id == request_id:
                return envelope.data
        return None

    await until(lambda: find() is not None)
    return find()


async def audit_rows(engine):
    async with engine.database.session() as session:
        return (await session.scalars(select(RemoteToolAudit).order_by(RemoteToolAudit.id))).all()


def policy(engine, **changes):
    return engine.app.state.remote_tools.update(changes)


class SlowTool:
    """A cancellable tool, registered on an engine's registry for timeout/cancel/limit tests."""

    def __init__(self, engine):
        self.started, self.cancelled = asyncio.Event(), False

        async def slow_tool(seconds: float = 30.0) -> str:
            self.started.set()
            try:
                await asyncio.sleep(seconds)
            except asyncio.CancelledError:
                self.cancelled = True
                raise
            return "slept"

        engine.app.state.tool_registry._specs.append(
            ToolSpec("custom", "slow_tool", "Sleeps for a while.", lambda _context: slow_tool))


# --- defaults and policy ---------------------------------------------------------------------


def test_everything_is_off_by_default(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            assert (await list_tools(la, lb))["tools"] == []
            await send_call(lb, "calculate", {"expression": "1+1"})
            result = await get_result(la)
            assert result["ok"] is False and "not shared" in result["error"]
            rows = await audit_rows(a)
            assert [(r.direction, r.outcome, r.tool) for r in rows] == [("in", "denied", "calculate")]
            assert a.app.state.remote_tools.snapshot()["tools"] == {}

    run(scenario())


def test_allow_runs_and_list_shows_only_enabled_tools(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            policy(a, tools={"calculate": "allow", "get_current_date": "off"})
            listing = (await list_tools(la, lb))["tools"]
            assert [t["name"] for t in listing] == ["calculate"]
            entry_ = listing[0]
            assert set(entry_) == {"name", "description", "parameters_schema", "operation", "mode"}
            assert entry_["mode"] == "allow" and entry_["operation"] == READ
            assert entry_["parameters_schema"]["properties"]["expression"]["type"] == "string"
            await send_call(lb, "calculate", {"expression": "6*7"})
            assert await get_result(la) == {"call_id": "c1", "ok": True, "result": "42"}
            await send_call(lb, "get_current_date", {}, call_id="c2")  # explicitly off
            assert (await get_result(la, "c2"))["ok"] is False
            await send_call(lb, "calculate", {"expression": "__import__('os')"}, call_id="c3")
            bad = await get_result(la, "c3")
            assert bad["ok"] is False and "unsupported" in bad["error"]
            await send_call(lb, "calculate", {"expr": "1"}, call_id="c4")  # wrong argument name
            invalid = await get_result(la, "c4")
            assert invalid["ok"] is False and "Invalid arguments" in invalid["error"]

    run(scenario())


def test_context_bound_tools_are_never_exportable_and_unknown_names_are_rejected(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            names = {item["name"] for item in a.app.state.remote_tools.snapshot()["exportable"]}
            assert "calculate" in names and "add_todo" in names
            assert not names & {"list_context_files", "read_context_file", "read_attachment", "replace_active_file"}
            with pytest.raises(ValueError):
                policy(a, tools={"replace_active_file": "allow"})
            with pytest.raises(ValueError):
                policy(a, tools={"no_such_tool": "allow"})
            with pytest.raises(ValueError):
                policy(a, tools={"calculate": "sometimes"})

    run(scenario())


def test_policy_persists_and_the_file_overrides_the_configured_defaults(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            service = a.app.state.remote_tools
            policy(a, tools={"calculate": "ask"}, max_result_bytes=2048)
            again = RemoteToolService(a.app, RemoteToolsConfig(), service._store_path)
            assert again.config.modes() == {"calculate": "ask"} and again.config.max_result_bytes == 2048
            configured = RemoteToolService(a.app, RemoteToolsConfig(tools=(("calculate", "allow"),)))
            assert configured.mode_of("calculate") == "allow"  # no file: the YAML defaults apply

    run(scenario())


# --- access control ---------------------------------------------------------------------------


def test_thin_clients_cannot_use_tool_frames(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a"], thin=["phone"]) as (engines, thins):
            a = engines["a"]
            policy(a, tools={"calculate": "allow"})
            phone = MemThin(a, thins["phone"])
            for frame_type, data in (
                ("tool.list", {}), ("tool.call", {"call_id": "x", "tool": "calculate", "args": {"expression": "1"}}),
                ("tool.cancel", {"call_id": "x"}),
            ):
                before = len(phone.of_type("error"))
                await phone.send(frame_type, data, "i1")
                await until(lambda: len(phone.of_type("error")) > before)
            assert not phone.of_type("tool.result") and not phone.of_type("tool.list.result")
            assert await audit_rows(a) == []

    run(scenario())


def test_authz_allows_tool_frames_for_peers_only_and_denies_the_route():
    for frame in ("tool.list", "tool.list.result", "tool.call", "tool.result", "tool.cancel"):
        assert authz.authorize_frame(authz.HIVE_PEER, frame)
        assert not authz.authorize_frame(authz.THIN_CLIENT, frame)
    for role in authz.ROLES:
        for method in ("GET", "PUT", "POST", "DELETE"):
            assert not authz.authorize_http(role, method, "/api/v1/hive/remote-tools")


def test_unknown_and_revoked_nodes_are_rejected(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            policy(a, tools={"calculate": "allow"})
            stranger = MemLink(a.identity.node_id, "n_stranger", authz.HIVE_PEER, asyncio.get_running_loop())
            call = Envelope("tool.call", {"call_id": "s1", "tool": "calculate", "args": {"expression": "1"}})
            a.node.route(stranger, "control", call)  # no runtime for an unknown node: dropped
            await a.app.state.remote_tools.handle(stranger, call, trusted=False)
            reply = [e.data for _, e in stranger.sent if e.type == "tool.result"]
            assert len(reply) == 1 and reply[0]["ok"] is False
            await asyncio.sleep(0.1)
            assert [r.outcome for r in await audit_rows(a)] == ["denied"]

            # b is revoked in a's directory while its link is still open
            a.directory.update([entry(a.identity), entry(b.identity, approver=a.identity, status="revoked")])
            assert a.node.node_role(b.identity.node_id) is None
            assert (await list_tools(la, lb))["tools"] == []
            await send_call(lb, "calculate", {"expression": "1+1"})
            assert (await get_result(la))["ok"] is False

    run(scenario())


# --- ask mode ---------------------------------------------------------------------------------


def test_ask_approved_by_a_local_client_runs_the_tool(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            policy(a, tools={"calculate": "ask"})
            ui = await local_client(a)
            await send_call(lb, "calculate", {"expression": "2+2"}, task_id="t-9")
            await until(lambda: of_type(ui, "tool.approval.request"))
            request = of_type(ui, "tool.approval.request")[0]["data"]
            assert request["remote"] is True and request["peer_node_id"] == b.identity.node_id
            assert request["tool_name"] == "calculate" and request["arguments"] == {"expression": "2+2"}
            assert request["task_id"] == "t-9" and request["peer_name"] and request["approval_id"]
            await ui._handle({"type": "tool.approval.response",
                              "data": {"approval_id": request["approval_id"], "decision": "approve"}})
            assert (await get_result(la))["result"] == "4"
            await until(lambda: of_type(ui, "tool.approval.resolved"))
            assert a.app.state.remote_tools._approvals == {}

    run(scenario())


def test_ask_denied_timeout_and_no_client(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            policy(a, tools={"calculate": "ask"}, approval_timeout_seconds=0.3)
            # nobody connected: denied immediately
            await send_call(lb, "calculate", {"expression": "1+1"}, call_id="n1")
            none = await get_result(la, "n1")
            assert none["ok"] is False and "No one was available" in none["error"]
            ui = await local_client(a)
            await send_call(lb, "calculate", {"expression": "1+1"}, call_id="d1")
            await until(lambda: of_type(ui, "tool.approval.request"))
            first = of_type(ui, "tool.approval.request")[0]["data"]
            await ui._handle({"type": "tool.approval.response",
                              "data": {"approval_id": first["approval_id"], "decision": "deny"}})
            denied = await get_result(la, "d1")
            assert denied["ok"] is False and "denied" in denied["error"]
            await send_call(lb, "calculate", {"expression": "1+1"}, call_id="t1")  # nobody answers
            timed_out = await get_result(la, "t1")
            assert timed_out["ok"] is False and "timed out" in timed_out["error"]
            assert [r.outcome for r in await audit_rows(a)] == ["denied", "denied", "denied"]

    run(scenario())


def test_a_peer_cannot_answer_its_own_approval_and_peers_are_not_prompted(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            policy(a, tools={"calculate": "ask"}, approval_timeout_seconds=10)
            # b registers as a "client" on a, which must not make it an approver
            await lb.send("control", Envelope("client.hello", {"clientId": "sneaky"}))
            await until(lambda: any(e.type == "client.hello.ack" for _, e in la.sent))
            await send_call(lb, "calculate", {"expression": "1+1"}, call_id="x1")
            result = await get_result(la, "x1")
            assert "No one was available" in result["error"]  # peers get no prompt
            assert not any(e.type == "tool.approval.request" for _, e in la.sent)

            ui = await local_client(a)
            await send_call(lb, "calculate", {"expression": "2+2"}, call_id="x2")
            await until(lambda: of_type(ui, "tool.approval.request"))
            approval_id = of_type(ui, "tool.approval.request")[0]["data"]["approval_id"]
            await lb.send("control", Envelope(
                "tool.approval.response", {"approval_id": approval_id, "decision": "approve"}))
            await asyncio.sleep(0.3)
            assert not any(e.type == "tool.result" and e.data["call_id"] == "x2" for _, e in la.sent)
            await ui._handle({"type": "tool.approval.response",
                              "data": {"approval_id": approval_id, "decision": "deny"}})
            assert (await get_result(la, "x2"))["ok"] is False

    run(scenario())


# --- filesystem scoping -----------------------------------------------------------------------


def make_link(link, target):
    try:
        os.symlink(target, link, target_is_directory=True)
    except OSError:
        if os.name != "nt":
            pytest.skip("symlinks are not available")
        import _winapi

        _winapi.CreateJunction(str(target), str(link))


def test_scoped_resolver_confines_paths(tmp_path):
    root = tmp_path / "share"
    root.mkdir()
    (root / "a.txt").write_text("hi")
    (tmp_path / "secret.txt").write_text("no")
    (tmp_path / "share2").mkdir()
    resolve = scoped_resolver(lambda: [str(root)])
    assert resolve(str(root / "a.txt")) == (root / "a.txt").resolve()
    assert resolve("a.txt") == (root / "a.txt").resolve()  # relative: inside the first root
    assert resolve(str(root / "sub" / ".." / "a.txt")) == (root / "a.txt").resolve()
    assert resolve(str(root / "new" / "file.txt")).name == "file.txt"  # not created yet is fine
    for outside in (
        str(root / ".." / "secret.txt"), str(tmp_path / "secret.txt"), "../secret.txt",
        str(tmp_path / "share2" / "x.txt"),  # shares the prefix text "share"
        str(tmp_path),
    ):
        with pytest.raises(OutsideRootsError):
            resolve(outside)
    with pytest.raises(ValueError):
        resolve("")
    with pytest.raises(OutsideRootsError):
        scoped_resolver(lambda: [])(str(root / "a.txt"))  # no roots: nothing is reachable
    if os.name == "nt":
        assert resolve(str(root / "a.txt").upper()) == (root / "a.txt").resolve()  # case-insensitive
        assert resolve(str(root / "a.txt").lower()) == (root / "a.txt").resolve()
        for tricky in ("\\\\?\\" + str(root / "a.txt"), str(root / "a.txt") + ":hidden"):
            with pytest.raises(OutsideRootsError):
                resolve(tricky)
    else:
        with pytest.raises(OutsideRootsError):
            resolve(str(root / "A.TXT").replace("share", "SHARE"))  # case-sensitive file systems


def test_scoped_resolver_blocks_link_escapes(tmp_path):
    root, outside = tmp_path / "share", tmp_path / "outside"
    root.mkdir()
    outside.mkdir()
    (outside / "s.txt").write_text("secret")
    link = root / "link"
    make_link(link, outside)
    try:
        resolve = scoped_resolver(lambda: [str(root)])
        with pytest.raises(OutsideRootsError):
            resolve(str(link / "s.txt"))
        with pytest.raises(OutsideRootsError):
            resolve(str(link))
    finally:
        os.rmdir(link)  # removes the link only, never the target


def test_filesystem_tools_need_roots_and_stay_inside_them(tmp_path):
    async def scenario():
        root, outside = tmp_path / "share", tmp_path / "outside"
        root.mkdir()
        outside.mkdir()
        (root / "note.txt").write_text("inside")
        (outside / "secret.txt").write_text("outside")
        async with pair(tmp_path) as (a, b, la, lb):
            policy(a, tools={"read_filesystem_file": "allow", "write_filesystem_file": "allow"})
            assert (await list_tools(la, lb))["tools"] == []  # allowed, but no roots: not exportable
            await send_call(lb, "read_filesystem_file", {"path": str(root / "note.txt")})
            assert (await get_result(la))["ok"] is False
            policy(a, filesystem_roots=[str(root)])
            names = [t["name"] for t in (await list_tools(la, lb, "l2"))["tools"]]
            assert sorted(names) == ["read_filesystem_file", "write_filesystem_file"]
            await send_call(lb, "read_filesystem_file", {"path": str(root / "note.txt")}, call_id="r1")
            ok = await get_result(la, "r1")
            assert ok["ok"] is True and ok["result"]["content"] == "inside"
            for index, path in enumerate((str(outside / "secret.txt"), str(root / ".." / "outside" / "secret.txt"))):
                await send_call(lb, "read_filesystem_file", {"path": path}, call_id=f"o{index}")
                denied = await get_result(la, f"o{index}")
                assert denied["ok"] is False and "outside the shared folders" in denied["error"]
            await send_call(lb, "write_filesystem_file", {"path": str(outside / "new.txt"), "content": "x"}, call_id="w1")
            assert (await get_result(la, "w1"))["ok"] is False and not (outside / "new.txt").exists()
            await send_call(lb, "write_filesystem_file", {"path": "made.txt", "content": "ok"}, call_id="w2")
            assert (await get_result(la, "w2"))["ok"] is True and (root / "made.txt").read_text() == "ok"
            with pytest.raises(ValueError):
                policy(a, filesystem_roots=[str(tmp_path.anchor)])  # a whole drive cannot be shared
            with pytest.raises(ValueError):
                policy(a, filesystem_roots=["relative/path"])

    run(scenario())


# --- limits -------------------------------------------------------------------------------------


def test_result_size_cap(tmp_path):
    async def scenario():
        root = tmp_path / "share"
        root.mkdir()
        (root / "big.txt").write_text("x" * 5000)
        async with pair(tmp_path) as (a, b, la, lb):
            policy(a, tools={"read_filesystem_file": "allow"}, filesystem_roots=[str(root)], max_result_bytes=1024)
            await send_call(lb, "read_filesystem_file", {"path": str(root / "big.txt")})
            result = await get_result(la)
            assert result["ok"] is False and "1024 byte limit" in result["error"]
            assert [r.outcome for r in await audit_rows(a)] == ["too_large"]

    run(scenario())


def test_call_timeout(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            slow = SlowTool(a)
            policy(a, tools={"slow_tool": "allow"}, call_timeout_seconds=0.2)
            await send_call(lb, "slow_tool", {})
            result = await get_result(la)
            assert result["ok"] is False and "timed out" in result["error"]
            assert slow.cancelled and [r.outcome for r in await audit_rows(a)] == ["timeout"]

    run(scenario())


def test_cancel_stops_the_running_tool(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            slow = SlowTool(a)
            policy(a, tools={"slow_tool": "allow"})
            await send_call(lb, "slow_tool", {})
            await asyncio.wait_for(slow.started.wait(), 10)
            await lb.send("control", Envelope("tool.cancel", {"call_id": "c1"}))
            result = await get_result(la)
            assert result["ok"] is False and "cancelled" in result["error"]
            assert slow.cancelled and a.app.state.remote_tools._calls == {}
            assert a.app.state.remote_tools._active == 0
            assert [r.outcome for r in await audit_rows(a)] == ["cancelled"]

    run(scenario())


def test_concurrency_cap(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            slow = SlowTool(a)
            policy(a, tools={"slow_tool": "allow"}, max_concurrent_calls=1)
            await send_call(lb, "slow_tool", {}, call_id="c1")
            await asyncio.wait_for(slow.started.wait(), 10)
            await send_call(lb, "slow_tool", {}, call_id="c2")
            busy = await get_result(la, "c2")
            assert busy["ok"] is False and "Too many" in busy["error"]
            await send_call(lb, "slow_tool", {}, call_id="c1")  # the id of a running call is taken
            await until(lambda: len([e for _, e in la.sent if e.type == "tool.result"]) >= 2)
            await lb.send("control", Envelope("tool.cancel", {"call_id": "c1"}))
            await until(lambda: a.app.state.remote_tools._active == 0)
            policy(a, tools={"slow_tool": "allow", "calculate": "allow"})
            await send_call(lb, "calculate", {"expression": "1"}, call_id="c4")  # the slot is free again
            assert (await get_result(la, "c4"))["ok"] is True

    run(scenario())


def test_workspace_tools_need_an_existing_local_workspace(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            policy(a, tools={"add_todo": "allow", "list_todos": "allow"})
            await send_call(lb, "add_todo", {"title": "x"}, call_id="n1")
            assert "workspace" in (await get_result(la, "n1"))["error"]
            await send_call(lb, "add_todo", {"title": "x"}, call_id="n2", workspace_uuid="missing")
            assert "workspace" in (await get_result(la, "n2"))["error"]
            workspace = await a.workspace("W")
            await send_call(lb, "add_todo", {"title": "buy milk"}, call_id="n3", workspace_uuid=workspace)
            assert (await get_result(la, "n3"))["ok"] is True
            await send_call(lb, "list_todos", {}, call_id="n4", workspace_uuid=workspace)
            todos = (await get_result(la, "n4"))["result"]["todos"]
            assert [t["title"] for t in todos] == ["buy milk"]

    run(scenario())


# --- audit --------------------------------------------------------------------------------------


def test_args_hash_is_stable_and_independent_of_key_order():
    assert args_sha256({"b": 1, "a": 2}) == args_sha256({"a": 2, "b": 1})
    assert args_sha256({"a": 2, "b": 1}) == hashlib.sha256(b'{"a":2,"b":1}').hexdigest()
    assert args_sha256({"a": 1}) != args_sha256({"a": 2})


def test_audit_rows_hold_no_raw_arguments_are_append_only_and_not_synced(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            policy(a, tools={"calculate": "allow"})
            async with a.database.session() as session:
                logged = await session.scalar(select(func.count()).select_from(SyncLog))
            args = {"expression": "12345*6789"}
            await send_call(lb, "calculate", args, task_id="task-77")
            result = await get_result(la)
            rows = await audit_rows(a)
            assert len(rows) == 1
            row = rows[0]
            assert (row.direction, row.peer_node_id, row.task_id, row.tool, row.outcome) == (
                "in", b.identity.node_id, "task-77", "calculate", "ok")
            assert row.args_sha256 == args_sha256(args) and row.duration_ms >= 0 and row.ts is not None
            dump = json.dumps([[getattr(r, c.name) for c in r.__table__.columns] for r in rows], default=str)
            assert "12345*6789" not in dump and "83810205" not in dump and result["ok"] is True
            async with a.database.session() as session:
                assert await session.scalar(select(func.count()).select_from(SyncLog)) == logged
                for statement in ("UPDATE remote_tool_audit SET outcome = 'x'", "DELETE FROM remote_tool_audit"):
                    with pytest.raises(DBAPIError):
                        await session.execute(text(statement))
                    await session.rollback()
            assert await audit_rows(b) == []  # b only asked via the raw link here

    run(scenario())


# --- executor side ------------------------------------------------------------------------------


def remote_config(*nodes):
    return json.dumps({"remote": {"nodes": list(nodes)}})


async def proxies(b, a, approval=None, **options):
    return await b.app.state.remote_toolset.tools_for_turn(
        remote_config(a.identity.node_id), task_id="task-1", workspace_uuid="ws",
        approval=approval or ApprovalConfig(), **options)


def alias_of(engine, other):
    return sanitize_alias(engine.node.node_name(other.identity.node_id))


def test_alias_assignment_and_config_parsing():
    assert sanitize_alias("Work PC!") == "work_pc"
    assert sanitize_alias("  ") == "" and sanitize_alias("a.b c") == "a_b_c"
    assert assign_aliases([("n_one", "Desktop"), ("n_two", "Laptop")]) == {"n_one": "desktop", "n_two": "laptop"}
    clash = assign_aliases([("n_aaaa1111zz", "Desktop"), ("n_bbbb2222zz", "desktop!"), ("n_cccc3333zz", "Other")])
    assert clash == {"n_aaaa1111zz": "n_aaaa1111", "n_bbbb2222zz": "n_bbbb2222", "n_cccc3333zz": "other"}
    assert assign_aliases([("n_dddd4444zz", "???")]) == {"n_dddd4444zz": "n_dddd4444"}
    assert remote_nodes_from_config(None) == [] and remote_nodes_from_config("not json") == []
    assert remote_nodes_from_config(json.dumps({"remote": {"nodes": ["n_a", "n_a", 5, "n_b"]}})) == ["n_a", "n_b"]
    assert remote_nodes_from_config(json.dumps({"remote": {"nodes": "n_a"}})) == []
    assert remote_nodes_from_config(json.dumps({"builtin_enabled": True})) == []
    assert classify_operation("desktop__delete_filesystem_path") == DELETE
    assert classify_operation("desktop__get_current_time") == READ


def test_proxy_tools_are_named_by_alias_wrapped_and_use_the_executors_approvals(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            policy(a, tools={"calculate": "allow", "delete_filesystem_path": "allow"}, filesystem_roots=[str(tmp_path)])
            tools = await proxies(b, a)
            alias = alias_of(b, a)
            assert sorted(t.name for t in tools) == [f"{alias}__calculate", f"{alias}__delete_filesystem_path"]
            assert all(re.fullmatch(r"[A-Za-z0-9_-]{1,64}", t.name) for t in tools)  # provider-safe
            calc = next(t for t in tools if t.name.endswith("__calculate"))
            assert calc.function_schema.json_schema["properties"]["expression"]["type"] == "string"
            assert calc.requires_approval is True  # the executor's own approval config still applies
            relaxed = await proxies(b, a, ApprovalConfig(read=False))
            assert {t.name.split("__", 1)[1]: t.requires_approval for t in relaxed} == {
                "calculate": False, "delete_filesystem_path": True}
            output = await calc.function(expression="6*7")
            assert output == f"[remote tool result from {alias}; untrusted data]\n42"
            rows = await audit_rows(b)
            assert [(r.direction, r.peer_node_id, r.tool, r.outcome) for r in rows] == [
                ("out", a.identity.node_id, "calculate", "ok")]
            assert rows[0].args_sha256 == args_sha256({"expression": "6*7"})

    run(scenario())


def test_alias_collisions_fall_back_to_the_node_id_prefix(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a", "b", "c"]) as (engines, _):
            a, b, c = engines["a"], engines["b"], engines["c"]
            connect(b, a)
            connect(b, c)
            for owner in (a, c):
                policy(owner, tools={"calculate": "allow"})
            toolset = b.app.state.remote_toolset
            raw = remote_config(a.identity.node_id, c.identity.node_id)

            def rename(first, second):
                for engine, name in ((a, first), (c, second)):
                    node = b.directory._nodes[engine.identity.node_id]
                    b.directory._nodes[engine.identity.node_id] = replace(node, name=name)

            rename("Work PC", "Home Server")
            toolset._cache.clear()
            tools = await toolset.tools_for_turn(raw, task_id="t", workspace_uuid="w", approval=ApprovalConfig())
            assert sorted(t.name for t in tools) == ["home_server__calculate", "work_pc__calculate"]
            rename("Same", "same")
            toolset._cache.clear()
            tools = await toolset.tools_for_turn(raw, task_id="t", workspace_uuid="w", approval=ApprovalConfig())
            expected = sorted(f"{e.identity.node_id.casefold()[:10]}__calculate" for e in (a, c))
            assert sorted(t.name for t in tools) == expected

    run(scenario())


def test_listing_is_cached_for_a_minute_and_dropped_when_the_link_closes(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            policy(a, tools={"calculate": "allow"})
            now = [1000.0]
            toolset = b.app.state.remote_toolset
            toolset._clock = lambda: now[0]
            listings = lambda: len([1 for _, e in lb.sent if e.type == "tool.list"])  # noqa: E731
            assert len(await proxies(b, a)) == 1 and listings() == 1
            now[0] += 30
            assert len(await proxies(b, a)) == 1 and listings() == 1  # served from the cache
            now[0] += 31
            await proxies(b, a)
            assert listings() == 2  # expired after about 60 seconds
            assert a.identity.node_id in toolset._cache
            b.node.on_link_closed(a.identity.node_id)
            assert a.identity.node_id not in toolset._cache

    run(scenario())


def test_offline_peer_gives_the_model_a_clear_error(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            policy(a, tools={"calculate": "allow"})
            tool = (await proxies(b, a))[0]
            await lb.close()
            b.node.on_link_closed(a.identity.node_id)
            message = await tool.function(expression="1+1")
            assert message == f"[remote tool error from {alias_of(b, a)}: that node is offline]"
            assert await proxies(b, a) == []  # an offline peer contributes no tools
            assert [r.outcome for r in await audit_rows(b)] == ["offline"]

    run(scenario())


def test_denied_and_timed_out_calls_return_error_strings(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            policy(a, tools={"calculate": "allow"})
            tool = (await proxies(b, a))[0]
            alias = alias_of(b, a)
            policy(a, tools={})  # switched off after b cached the listing
            assert "not shared" in await tool.function(expression="1+1")
            assert (await tool.function(expression="1+1")).startswith(f"[remote tool error from {alias}:")
            policy(a, tools={"calculate": "allow"})
            la.drop = True  # the owner's replies never arrive
            b.app.state.remote_toolset.wait_seconds = 0.3
            assert "timed out" in await tool.function(expression="1+1")
            await until(lambda: any(e.type == "tool.cancel" for _, e in lb.sent))
            assert {r.outcome for r in await audit_rows(b)} == {"error", "timeout"}

    run(scenario())


def test_cancelling_the_turn_sends_tool_cancel_to_the_owner(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            slow = SlowTool(a)
            policy(a, tools={"slow_tool": "allow"})
            tool = (await proxies(b, a))[0]
            call = asyncio.ensure_future(tool.function())
            await asyncio.wait_for(slow.started.wait(), 10)
            call.cancel()
            with pytest.raises(asyncio.CancelledError):
                await call
            await until(lambda: any(e.type == "tool.cancel" for _, e in lb.sent))
            await until(lambda: slow.cancelled)
            assert b.app.state.remote_toolset._calls == {}

    run(scenario())


def test_results_are_only_accepted_from_the_node_that_was_called(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            toolset = b.app.state.remote_toolset
            future = asyncio.get_running_loop().create_future()
            toolset._calls["call-1"] = (a.identity.node_id, future)
            impostor = SimpleNamespace(node_id="n_impostor")
            toolset.on_frame(impostor, Envelope("tool.result", {"call_id": "call-1", "ok": True, "result": "evil"}))
            assert not future.done()
            toolset.on_frame(lb, Envelope("tool.result", {"call_id": "call-1", "ok": True, "result": "fine"}))
            assert future.result()["result"] == "fine"

    run(scenario())


def test_a_hostile_listing_cannot_create_odd_tools(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            service = a.app.state.remote_tools
            service.describe = lambda: [  # type: ignore[method-assign]
                {"name": "bad name!", "description": "x", "parameters_schema": {}, "operation": "read", "mode": "allow"},
                {"name": "ok_tool", "description": "d" * 5000, "parameters_schema": "nope", "operation": "read",
                 "mode": "allow"},
                "junk",
            ]
            tools = await proxies(b, a)
            assert [t.name.split("__", 1)[1] for t in tools] == ["ok_tool"]
            assert len(tools[0].description) < 2100
            assert tools[0].function_schema.json_schema["type"] == "object"

    run(scenario())


# --- capabilities ------------------------------------------------------------------------------


def test_presence_capabilities_do_not_list_remote_tools(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a"]) as (engines, _):
            a = engines["a"]
            policy(a, tools={"calculate": "allow"})
            service = HiveService(
                account=SimpleNamespace(), credential_store=SimpleNamespace(), data_directory=tmp_path,
                identity_store=SimpleNamespace())
            service.app = a.app
            capabilities = await service.capabilities()
            assert set(capabilities) == {"agents", "can_run_agents", "models", "protocol"}
            assert "calculate" not in json.dumps(capabilities)

    run(scenario())


# --- end to end ---------------------------------------------------------------------------------


class RemoteCallingAgent:
    """Stands in for the model: calls the remote proxy whose name ends with ``suffix``."""

    def __init__(self, suffix="__calculate", arguments=None):
        self.suffix, self.arguments = suffix, arguments or {"expression": "6*7"}
        self.tool_names: list[str] = []

    async def execute(self, config, prompt, history, tools, approve, system_prompt=None, event_sink=None):
        self.tool_names = [tool.name for tool in tools]
        tool = next(tool for tool in tools if tool.name.endswith(self.suffix))
        if tool.requires_approval and not await approve(ToolCallPart(tool_name=tool.name, args=self.arguments)):
            return AgentExecutionResult("the user refused", [])
        output = await tool.function(**self.arguments)
        return AgentExecutionResult(
            f"answer: {output}", [{"toolName": tool.name, "input": self.arguments, "output": output}])


async def configure_workspace(engine, workspace_uuid, remote_node, approval=None):
    async with engine.database.session() as session:
        row = await session.scalar(select(Workspace).where(Workspace.uuid == workspace_uuid))
        row.tools_config = remote_config(remote_node) if remote_node else None
        row.approval_config = json.dumps(approval) if approval else None
        await session.commit()


async def thread_messages(engine, thread_uuid):
    async with engine.database.session() as session:
        rows = (await session.execute(
            select(Message.role, Message.content).join(ConversationThread, ConversationThread.id == Message.thread_id)
            .where(ConversationThread.uuid == thread_uuid).order_by(Message.id))).all()
    return [(role, content) for role, content in rows]


def test_end_to_end_task_on_b_uses_a_tool_exported_by_a(tmp_path):
    async def scenario():
        agent = RemoteCallingAgent()
        async with pair(tmp_path, agent_manager=agent) as (a, b, la, lb):
            policy(a, tools={"calculate": "allow"})
            workspace = await b.workspace("W")
            await configure_workspace(b, workspace, a.identity.node_id, approval={"read": False})
            session = local_session(b.app)
            await session._handle({"type": "task.submit", "data": {
                "workspace_uuid": workspace, "content": "what is 6*7?", "client_msg_uuid": "m1"}})
            await until(lambda: of_type(session, "chat.done") or of_type(session, "chat.error"))
            assert of_type(session, "chat.done"), of_type(session, "chat.error")
            thread = of_type(session, "task.accepted")[0]["data"]["thread_uuid"]
            alias = alias_of(b, a)
            messages = await thread_messages(b, thread)
            assistant = [content for role, content in messages if role == "assistant"]
            assert assistant == [f"answer: [remote tool result from {alias}; untrusted data]\n42"]
            tool_record = json.loads(next(content for role, content in messages if role == "tool"))
            assert tool_record["toolName"] == f"{alias}__calculate"
            assert f"{alias}__calculate" in agent.tool_names
            assert (await audit_rows(a))[0].outcome == "ok" and (await audit_rows(b))[0].direction == "out"

    run(scenario())


def test_end_to_end_ask_is_answered_by_a_client_on_the_owning_node(tmp_path):
    async def scenario():
        agent = RemoteCallingAgent()
        async with pair(tmp_path, agent_manager=agent) as (a, b, la, lb):
            policy(a, tools={"calculate": "ask"})
            ui_on_a = await local_client(a)
            workspace = await b.workspace("W")
            await configure_workspace(b, workspace, a.identity.node_id)  # b's default approvals ask too
            session = local_session(b.app)
            await session._handle({"type": "task.submit", "data": {
                "workspace_uuid": workspace, "content": "compute", "client_msg_uuid": "m2"}})
            # 1) the executor's own user is asked first ...
            await until(lambda: of_type(session, "tool.approval.request"))
            mine = of_type(session, "tool.approval.request")[0]
            assert not of_type(ui_on_a, "tool.approval.request")
            await session._handle({"type": "tool.approval.response", "id": mine["id"],
                                   "data": {"approval_id": mine["data"]["approval_id"], "decision": "approve"}})
            # 2) ... then the human on the owning node
            await until(lambda: of_type(ui_on_a, "tool.approval.request"))
            theirs = of_type(ui_on_a, "tool.approval.request")[0]["data"]
            assert theirs["remote"] is True and theirs["peer_node_id"] == b.identity.node_id
            assert theirs["task_id"] == mine["id"]
            await ui_on_a._handle({"type": "tool.approval.response",
                                   "data": {"approval_id": theirs["approval_id"], "decision": "approve"}})
            await until(lambda: of_type(session, "chat.done") or of_type(session, "chat.error"))
            assert of_type(session, "chat.done"), of_type(session, "chat.error")
            thread = of_type(session, "task.accepted")[0]["data"]["thread_uuid"]
            assistant = [c for role, c in await thread_messages(b, thread) if role == "assistant"]
            assert len(assistant) == 1 and assistant[0].endswith("untrusted data]\n42")

    run(scenario())


def test_end_to_end_ask_denied_on_the_owner_reaches_the_model_as_an_error(tmp_path):
    async def scenario():
        agent = RemoteCallingAgent()
        async with pair(tmp_path, agent_manager=agent) as (a, b, la, lb):
            policy(a, tools={"calculate": "ask"})
            ui_on_a = await local_client(a)
            workspace = await b.workspace("W")
            await configure_workspace(b, workspace, a.identity.node_id, approval={"read": False})
            session = local_session(b.app)
            await session._handle({"type": "task.submit", "data": {
                "workspace_uuid": workspace, "content": "compute", "client_msg_uuid": "m3"}})
            await until(lambda: of_type(ui_on_a, "tool.approval.request"))
            request = of_type(ui_on_a, "tool.approval.request")[0]["data"]
            await ui_on_a._handle({"type": "tool.approval.response",
                                   "data": {"approval_id": request["approval_id"], "decision": "deny"}})
            await until(lambda: of_type(session, "chat.done") or of_type(session, "chat.error"))
            thread = of_type(session, "task.accepted")[0]["data"]["thread_uuid"]
            assistant = [c for role, c in await thread_messages(b, thread) if role == "assistant"]
            assert "remote tool error" in assistant[0] and "denied" in assistant[0]

    run(scenario())


# --- regression: nothing changes without ``remote`` -----------------------------------------------


class CapturingAgent:
    def __init__(self):
        self.tool_names: list[str] = []

    async def execute(self, config, prompt, history, tools, approve, system_prompt=None, event_sink=None):
        self.tool_names = [tool.name for tool in tools]
        return AgentExecutionResult("plain", [])


def test_chat_and_tools_are_unchanged_when_remote_is_not_configured(tmp_path):
    async def scenario():
        agent = CapturingAgent()
        async with pair(tmp_path, agent_manager=agent) as (a, b, la, lb):
            policy(a, tools={"calculate": "allow"})
            workspace = await b.workspace("W")
            session = local_session(b.app)
            await session._handle({"type": "chat.send", "id": "turn-1",
                                   "data": {"workspace_uuid": workspace, "content": "hello"}})
            await until(lambda: of_type(session, "chat.done"))
            builtin = {spec.name for spec in b.app.state.tool_registry.specs}
            assert builtin <= set(agent.tool_names) and not any("." in name for name in agent.tool_names)
            assert not any(e.type == "tool.list" for _, e in lb.sent)  # no peer was contacted
            assert await audit_rows(b) == []
            # a configured but unreachable / unknown node adds nothing either
            await configure_workspace(b, workspace, "n_unknown")
            await until(lambda: session.active_turn is None)
            await session._handle({"type": "chat.send", "id": "turn-2",
                                   "data": {"workspace_uuid": workspace, "content": "again"}})
            await until(lambda: len(of_type(session, "chat.done")) == 2)
            assert not any("." in name for name in agent.tool_names)
            assert not any(e.type == "tool.list" for _, e in lb.sent)
            toolset = b.app.state.remote_toolset
            assert await toolset.tools_for_turn(None, task_id="t", workspace_uuid="w", approval=ApprovalConfig()) == []

    run(scenario())


# --- configuration and routes -----------------------------------------------------------------------


def test_remote_tools_yaml_is_strict_and_versioned(tmp_path):
    path = tmp_path / "config.yaml"
    path.write_text(
        "version: 1\nengine:\n  hive:\n    remote_tools:\n      tools: {calculate: allow, add_todo: ask}\n"
        "      filesystem_roots: ['/srv/share']\n      call_timeout_seconds: 5\n      max_result_bytes: 4096\n"
        "      max_concurrent_calls: 2\n      approval_timeout_seconds: 30\n", encoding="utf-8")
    config = load_configuration(path).engine.hive.remote_tools
    assert config.modes() == {"calculate": "allow", "add_todo": "ask"}
    assert config.filesystem_roots == ("/srv/share",) and config.call_timeout_seconds == 5
    assert (config.max_result_bytes, config.max_concurrent_calls, config.approval_timeout_seconds) == (4096, 2, 30)
    assert "remote_tools" in show_configuration(path)
    defaults = load_configuration(tmp_path / "missing.yaml").engine.hive.remote_tools
    assert defaults == RemoteToolsConfig() and defaults.modes() == {} and defaults.max_result_bytes == 262144
    for bad in (
        "tools: {calculate: yes-please}", "tools: [calculate]", "bogus: 1", "filesystem_roots: /srv",
        "call_timeout_seconds: -1", "max_result_bytes: 10", "max_concurrent_calls: 0", "max_concurrent_calls: true",
    ):
        path.write_text(f"version: 1\nengine:\n  hive:\n    remote_tools:\n      {bad}\n", encoding="utf-8")
        with pytest.raises(ConfigurationFileError):
            load_configuration(path)
    path.write_text("version: 2\nengine:\n  hive:\n    remote_tools: {}\n", encoding="utf-8")
    with pytest.raises(ConfigurationFileError):
        load_configuration(path)
    with pytest.raises(ValueError):
        remote_tools_from_mapping({"tools": {"x": "maybe"}})


def test_routes_read_and_write_the_policy_with_the_local_bearer_only(tmp_path):
    async def scenario():
        async with pair(tmp_path) as (a, b, la, lb):
            headers = {"Authorization": "Bearer secret-token"}
            async with AsyncClient(transport=ASGITransport(app=a.app), base_url="http://engine") as client:
                assert (await client.get("/api/v1/hive/remote-tools")).status_code in (401, 403)
                assert (await client.put("/api/v1/hive/remote-tools", json={})).status_code in (401, 403)
                first = await client.get("/api/v1/hive/remote-tools", headers=headers)
                body = first.json()
                assert first.status_code == 200 and body["tools"] == {} and body["max_result_bytes"] == 262144
                assert all(item["mode"] == "off" for item in body["exportable"])
                updated = await client.put("/api/v1/hive/remote-tools", headers=headers, json={
                    "tools": {"calculate": "ask"}, "call_timeout_seconds": 12})
                assert updated.status_code == 200 and updated.json()["tools"] == {"calculate": "ask"}
                assert (await client.get("/api/v1/hive/remote-tools", headers=headers)).json()["call_timeout_seconds"] == 12
                round_trip = await client.put("/api/v1/hive/remote-tools", headers=headers, json=updated.json())
                assert round_trip.status_code == 200
                for bad in ({"tools": {"calculate": "yes"}}, {"tools": {"nope": "allow"}}, {"bogus": 1},
                            {"filesystem_roots": ["relative"]}, []):
                    assert (await client.put("/api/v1/hive/remote-tools", headers=headers, json=bad)).status_code == 400
                    assert (await client.get("/api/v1/hive/remote-tools", headers=headers)).json()["tools"] == {
                        "calculate": "ask"}
            assert (await list_tools(la, lb))["tools"][0]["name"] == "calculate"  # the policy is live

    run(scenario())


def test_engine_engines_start_with_the_configured_policy(tmp_path):
    async def scenario():
        from subconscious_engine.api.app import create_app
        from subconscious_engine.auth import EngineAuthToken
        from subconscious_engine.storage import Database

        database = Database(tmp_path / "configured.db")
        app = create_app(
            database, EngineAuthToken("secret-token"), model_configuration_store=SimpleNamespace(),
            remote_tools_config=RemoteToolsConfig(tools=(("calculate", "allow"),)))
        assert app.state.remote_tools.mode_of("calculate") == "allow"
        assert app.state.remote_tools.mode_of("get_current_date") == "off"
        assert app.state.remote_tools.mode_of("read_filesystem_file") == "off"

    run(scenario())
