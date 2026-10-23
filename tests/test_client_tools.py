import asyncio
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from sqlalchemy import select
from starlette.websockets import WebSocketDisconnect

from subconscious_engine.api.websocket import ClientRegistry, WebSocketSession
from subconscious_engine.approval import ApprovalConfig
from subconscious_engine.client_tools import (
    ClientToolCatalog,
    ClientToolError,
    is_schema_registration,
    parse_group,
    tool_enabled,
)
from subconscious_engine.storage.models import Workspace

from test_api import api_client, auth
from test_configured_tools import TurnSocket, turn_fixture

SCHEMA = {"type": "object", "properties": {"tab_id": {"type": "integer"}}, "required": []}


def run(coro):
    return asyncio.run(coro)


def tool(tool_id="read_page", **extra):
    return {"id": tool_id, "description": "Read.", "input_schema": SCHEMA, **extra}


def payload(*tools, group="browser", title="Browser"):
    return {"group": group, "title": title, "tools": list(tools)}


class PeerSocket:
    """A FakeSocket-style transport; ``link`` makes it a hive peer."""

    def __init__(self, link=None):
        self.app = SimpleNamespace(state=SimpleNamespace(
            client_registry=ClientRegistry(),
            event_bus=SimpleNamespace(publish=AsyncMock()),
            client_tool_catalog=ClientToolCatalog(),
        ))
        self.sent = []
        if link is not None:
            self.link = link

    async def send_json(self, value):
        self.sent.append(value)


def errors(socket):
    return [f["data"]["error"] for f in socket.sent if f["type"] == "error"]


# --- validation ---------------------------------------------------------------------------------------
def test_parse_group_normalises_operations_and_read_only():
    group = parse_group(payload(
        tool("a", operation="execute"), tool("b", operation="DELETE"), tool("c", read_only=True,
        operation="delete"), tool("d"), tool("e", timeout_seconds=5)))
    ops = {t.id: (t.operation, t.approval_operation, t.read_only) for t in group.tools}
    assert ops == {"a": ("execute", "update", False), "b": ("delete", "delete", False),
                   "c": ("read", "read", True), "d": ("update", "update", False),
                   "e": ("update", "update", False)}
    assert group.tool("e").timeout_seconds == 5.0 and group.title == "Browser"


@pytest.mark.parametrize("data, needle", [
    ({"group": "Bad", "tools": []}, "group"),
    ({"group": "1x", "tools": []}, "group"),
    ({"group": "a" * 33, "tools": []}, "group"),
    ({"group": "local", "tools": []}, "built-in"),
    (payload(tool("1bad")), "tool id"),
    (payload(tool("a" * 65)), "tool id"),
    (payload(tool("x", description="d" * 2001)), "description"),
    (payload({"id": "x", "input_schema": {"type": "array"}}), "input_schema"),
    (payload({"id": "x"}), "input_schema"),
    (payload(tool("x", operation="admin")), "operation"),
    (payload(tool("x", read_only="yes")), "read_only"),
    (payload(tool("x", timeout_seconds=301)), "timeout_seconds"),
    (payload(tool("x", timeout_seconds=0)), "timeout_seconds"),
    (payload(tool("x"), tool("x")), "duplicate"),
    (payload({"id": "x", "input_schema": {"type": "object", "x": "y" * 33_000}}), "KiB"),
    ({"group": "browser", "tools": "nope"}, "tools"),
    (payload(*[tool(f"t{i}") for i in range(65)]), "at most"),
])
def test_parse_group_rejects_invalid_payloads(data, needle):
    with pytest.raises(ClientToolError, match=needle):
        parse_group(data, reserved={"local"})


def test_schema_registration_detection_and_tool_enabled_toggles():
    assert not is_schema_registration({"tools": [{"id": "navigate_ui"}]})
    assert is_schema_registration({"group": "x", "tools": []})
    assert is_schema_registration({"tools": [{"id": "x", "input_schema": SCHEMA}]})
    assert tool_enabled({}, "browser", "a")
    assert not tool_enabled({"builtin_enabled": False}, "browser", "a")
    assert not tool_enabled({"builtin": {"browser": {"enabled": False}}}, "browser", "a")
    config = {"builtin": {"browser": {"tools": {"a": False}}}}
    assert not tool_enabled(config, "browser", "a") and tool_enabled(config, "browser", "b")


def test_catalog_remembers_after_disconnect_and_latest_wins():
    catalog = ClientToolCatalog()
    first, second = object(), object()
    catalog.register(first, parse_group(payload(tool("old"))))
    assert catalog.is_live("browser")
    catalog.register(second, parse_group(payload(tool("new", operation="execute"))))
    catalog.disconnect(first)
    assert catalog.live_groups() == {"browser"}
    catalog.disconnect(second)
    assert catalog.live_groups() == set() and not catalog.is_live("browser")
    assert catalog.catalog() == {"browser": [{"name": "new", "doc": "Read.", "operation": "execute"}]}


# --- registration over the session --------------------------------------------------------------------
def test_register_replace_unregister_and_disconnect_cleanup():
    async def scenario():
        socket = PeerSocket()
        session = WebSocketSession(socket)
        catalog = socket.app.state.client_tool_catalog
        await session._handle({"type": "tool.register", "data": payload(tool("a"), tool("b"))})
        assert [t.id for t in session.client_tool_groups["browser"].tools] == ["a", "b"]
        assert catalog.is_live("browser")
        await session._handle({"type": "tool.register", "data": payload(tool("c"))})
        assert [t.id for t in session.client_tool_groups["browser"].tools] == ["c"]
        await session._handle({"type": "tool.register", "data": payload(group="webmcp", title="Web")})
        assert set(session.client_tool_groups) == {"browser"}  # empty list never registers
        await session._handle({"type": "tool.register", "data": payload(tool("z"), group="webmcp")})
        await session._handle({"type": "tool.unregister", "data": {"group": "webmcp"}})
        assert set(session.client_tool_groups) == {"browser"} and not catalog.is_live("webmcp")
        await session._handle({"type": "tool.register", "data": payload()})  # empty list removes
        assert session.client_tool_groups == {} and not catalog.is_live("browser")
        assert errors(socket) == []
        # remembered for the catalog even though nothing is live
        assert set(catalog.catalog()) == {"browser", "webmcp"}

        await session._handle({"type": "tool.register", "data": payload(tool("a"))})
        socket.accept = AsyncMock()
        socket.receive_json = AsyncMock(side_effect=WebSocketDisconnect(code=1000))
        await session.run()
        assert session.client_tool_groups == {} and not catalog.is_live("browser")
    run(scenario())


def test_invalid_registrations_send_error_frames_and_never_raise():
    async def scenario():
        socket = PeerSocket()
        session = WebSocketSession(socket)
        await session._handle({"type": "tool.register", "data": {"group": "Bad", "tools": []}})
        await session._handle({"type": "tool.register", "data": payload(tool("x", operation="nope"))})
        await session._handle({"type": "tool.register", "data": payload(tool("a"), group="local")})
        for index in range(8):
            await session._handle({"type": "tool.register", "data": payload(tool("a"), group=f"g{index}")})
        assert len(session.client_tool_groups) == 8
        await session._handle({"type": "tool.register", "data": payload(tool("a"), group="ninth")})
        await session._handle({"type": "tool.register", "data": payload(tool("b"), group="g0")})  # replace ok
        found = errors(socket)
        assert len(found) == 4 and all(e.startswith("tool.register rejected:") for e in found)
        assert "at most 8" in found[-1]
        assert [t.id for t in session.client_tool_groups["g0"].tools] == ["b"]
    run(scenario())


def test_thin_client_links_may_register_schema_tools_but_engine_peers_may_not():
    async def scenario():
        thin = PeerSocket(link=SimpleNamespace(tier="member", role="thin_client"))
        thin_session = WebSocketSession(thin)
        await thin_session._handle({"type": "tool.register", "data": payload(tool("a"))})
        assert [t.id for t in thin_session.client_tool_groups["browser"].tools] == ["a"]
        assert errors(thin) == []
        engine = PeerSocket(link=SimpleNamespace(tier="member", role="hive_peer"))
        engine_session = WebSocketSession(engine)
        await engine_session._handle({"type": "tool.register", "data": payload(tool("a"))})
        assert engine_session.client_tool_groups == {}
        assert errors(engine) == ["Hive peers cannot register client tools with schemas."]
    run(scenario())


def test_hive_peers_cannot_register_schema_tools_but_keep_legacy_ui_tools():
    async def scenario():
        socket = PeerSocket(link=SimpleNamespace(tier="member"))
        session = WebSocketSession(socket)
        await session._handle({"type": "tool.register", "data": payload(tool("a"))})
        assert session.client_tool_groups == {}
        assert errors(socket) == ["Hive peers cannot register client tools with schemas."]
        await session._handle({"type": "tool.register", "data": {"tools": [{"id": "navigate_ui"}]}})
        assert session.client_tools == {"navigate_ui": {"id": "navigate_ui"}}
        assert not socket.app.state.client_tool_catalog.catalog()
    run(scenario())


# --- tools in a chat turn -----------------------------------------------------------------------------
async def set_workspace(database, *, tools_config=None, approval=None):
    async with database.session() as session:
        workspace = await session.scalar(select(Workspace).where(Workspace.uuid == "ws"))
        workspace.tools_config = json.dumps(tools_config) if tools_config is not None else None
        if approval is not None:
            workspace.approval_config = json.dumps(approval)
        await session.commit()


async def start(tmp_path, **options):
    database, app, agent = await turn_fixture(tmp_path)
    await set_workspace(database, **options)
    session = WebSocketSession(TurnSocket(app))
    session.client_name = "Chrome"
    return database, app, agent, session


async def turn(session, agent, **data):
    outcome = await session._run_turn("turn-1", {"content": "hi", "workspace_uuid": "ws", **data})
    assert outcome == ("done", None), session.socket.sent
    return {t.name: t for t in agent.tools}


def test_turn_builds_prefixed_tools_with_approval_from_declared_operation(tmp_path):
    async def scenario():
        database, app, agent, session = await start(tmp_path, approval={
            "read": False, "update": True, "delete": True, "create": False})
        try:
            await session._handle({"type": "tool.register", "data": payload(
                tool("read_page", operation="read"), tool("click", operation="execute"),
                tool("close_tab", operation="delete"), tool("open_tab", operation="create"),
                tool("odd.name-1", read_only=True))})
            names = await turn(session, agent)
            assert names["browser__read_page"].requires_approval is False
            assert names["browser__open_tab"].requires_approval is False
            assert names["browser__click"].requires_approval is True  # execute counts as update
            assert names["browser__close_tab"].requires_approval is True
            assert "browser__odd_name_1" in names
            assert names["browser__read_page"].description == "[Browser via Chrome] Read."
            assert names["browser__read_page"].function_schema.json_schema["properties"] == SCHEMA["properties"]
            assert session.client_tool_operations["browser__click"] == "execute"
        finally:
            await app.state.configured_tools.close()
            await database.close()
    run(scenario())


def test_turn_respects_tools_enabled_and_tools_config_toggles(tmp_path):
    async def scenario():
        database, app, agent, session = await start(tmp_path)
        try:
            await session._handle({"type": "tool.register", "data": payload(tool("a"), tool("b"))})
            await session._handle({"type": "tool.register", "data": payload(tool("c"), group="webmcp")})
            names = await turn(session, agent)
            assert {"browser__a", "browser__b", "webmcp__c"} <= set(names)
            names = await turn(session, agent, tools_enabled=False)
            assert not [n for n in names if "__" in n and n.split("__")[0] in {"browser", "webmcp"}]
            await set_workspace(database, tools_config={"builtin_enabled": False})
            assert not {"browser__a", "webmcp__c"} & set(await turn(session, agent))
            await set_workspace(database, tools_config={"builtin": {
                "browser": {"enabled": False}, "webmcp": {"tools": {"c": False}}}})
            assert not {"browser__a", "webmcp__c"} & set(await turn(session, agent))
            await set_workspace(database, tools_config={"builtin": {"browser": {"tools": {"a": False}}}})
            names = await turn(session, agent)
            assert "browser__a" not in names and "browser__b" in names and "webmcp__c" in names
        finally:
            await app.state.configured_tools.close()
            await database.close()
    run(scenario())


def test_names_are_deduplicated_and_capped_at_64_chars(tmp_path):
    async def scenario():
        database, app, agent, session = await start(tmp_path)
        try:
            long_id = "x" * 60
            await session._handle({"type": "tool.register", "data": payload(
                tool("a.b"), tool("a_b"), tool("a-b"), tool(long_id), tool("y" * 60))})
            names = await turn(session, agent)
            client = [n for n in names if n.startswith("browser__")]
            assert len(client) == 5 and len(set(client)) == 5 and all(len(n) <= 64 for n in client)
            assert {"browser__a_b", "browser__a_b_2", "browser__a_b_3"} <= set(client)
        finally:
            await app.state.configured_tools.close()
            await database.close()
    run(scenario())


def test_client_tool_round_trip_error_and_timeout(tmp_path):
    async def scenario():
        database, app, agent, session = await start(tmp_path)
        try:
            await session._handle({"type": "tool.register", "data": payload(
                tool("read_page"), tool("slow", timeout_seconds=0.05))})
            names = await turn(session, agent)
            sent = session.socket.sent

            async def answer(**result):
                request = next(f for f in reversed(sent) if f["type"] == "client.tool.request")
                await session._handle({"type": "client.tool.result", "id": "turn-1", "data": {
                    "request_id": request["data"]["request_id"], **result}})

            task = asyncio.create_task(names["browser__read_page"].function(tab_id=3))
            await asyncio.sleep(0)
            request = next(f for f in sent if f["type"] == "client.tool.request")
            assert request["id"] == "turn-1"
            assert {k: v for k, v in request["data"].items() if k != "request_id"} == {
                "tool_name": "read_page", "group": "browser", "arguments": {"tab_id": 3}}
            await answer(ok=True, result={"text": "hello"})
            assert await task == {"text": "hello"}

            task = asyncio.create_task(names["browser__read_page"].function())
            await asyncio.sleep(0)
            await answer(ok=False, error="tab is gone")
            with pytest.raises(RuntimeError, match="tab is gone"):
                await task

            with pytest.raises(RuntimeError, match="did not answer"):
                await names["browser__slow"].function()
            assert session.pending_client_tools == {}
        finally:
            await app.state.configured_tools.close()
            await database.close()
    run(scenario())


def test_approval_request_reports_the_declared_operation(tmp_path):
    async def scenario():
        database, app, agent, session = await start(tmp_path)
        try:
            await session._handle({"type": "tool.register", "data": payload(tool("close_tab", operation="delete"),
                                                                              tool("click", operation="execute"))})
            await turn(session, agent)

            class Call:
                def __init__(self, name):
                    self.tool_name = name

                def args_as_dict(self):
                    return {}

            for name, expected in (("browser__close_tab", "delete"), ("browser__click", "execute"),
                                   ("read_file", "read")):
                waiting = asyncio.create_task(session._request_approval("turn-1", "th", Call(name)))
                await asyncio.sleep(0)
                frame = [f for f in session.socket.sent if f["type"] == "tool.approval.request"][-1]
                assert frame["data"]["operation"] == expected
                await session._approval("turn-1", {"approval_id": frame["data"]["approval_id"],
                                                  "decision": "approve"})
                assert await waiting is True
        finally:
            await app.state.configured_tools.close()
            await database.close()
    run(scenario())


def test_legacy_ui_tools_still_offered_and_always_require_approval(tmp_path):
    async def scenario():
        database, app, agent, session = await start(tmp_path, approval={"read": False, "update": False})
        try:
            await session._handle({"type": "tool.register", "data": {"tools": [{"id": "navigate_ui"}]}})
            names = await turn(session, agent)
            assert names["navigate_ui"].requires_approval is True
            names = await turn(session, agent, tools_enabled=False)
            assert "navigate_ui" in names
        finally:
            await app.state.configured_tools.close()
            await database.close()
    run(scenario())


def test_workspace_tool_toggle_validation_accepts_client_groups(tmp_path):
    async def scenario():
        database, app, agent, session = await start(tmp_path)
        try:
            await session._handle({"type": "tool.register", "data": payload(tool("a"))})
            await session._handle({"type": "tool.register", "data": {"tools": [
                {"id": "set_workspace_builtin_tool_enabled"}]}})
            names = await turn(session, agent)
            toggle = names["set_workspace_builtin_tool_enabled"].function
            with pytest.raises(ValueError, match="group"):
                await toggle("nope", True)
            with pytest.raises(ValueError, match="tool"):
                await toggle("browser", True, "missing")
            task = asyncio.create_task(toggle("browser", False, "a"))
            await asyncio.sleep(0)
            request = [f for f in session.socket.sent if f["type"] == "client.tool.request"][-1]
            assert request["data"]["arguments"] == {"group": "browser", "enabled": False, "tool": "a"}
            task.cancel()
        finally:
            await app.state.configured_tools.close()
            await database.close()
    run(scenario())


def test_catalog_endpoint_lists_client_groups_after_disconnect(tmp_path):
    async def scenario():
        async with api_client(tmp_path) as (client, app):
            socket = SimpleNamespace(app=app, sent=[], client=None)
            socket.send_json = AsyncMock()
            session = WebSocketSession(socket)
            await session._handle({"type": "tool.register", "data": payload(
                tool("read_page", description="Read it.", operation="read"),
                tool("click", operation="execute"))})
            body = (await client.get("/api/v1/tools/catalog", headers=auth())).json()
            assert body["builtin"]["browser"] == [
                {"name": "read_page", "doc": "Read it.", "operation": "read"},
                {"name": "click", "doc": "Read.", "operation": "execute"}]
            assert body["builtin"]["local"][0]["name"] == "echo"
            app.state.client_tool_catalog.disconnect(session)
            body = (await client.get("/api/v1/tools/catalog", headers=auth())).json()
            assert [t["name"] for t in body["builtin"]["browser"]] == ["read_page", "click"]
            assert not app.state.client_tool_catalog.is_live("browser")
    run(scenario())


def test_approval_config_unchanged_for_unknown_operation():
    assert ApprovalConfig(read=False).requires_operation("execute") is True
