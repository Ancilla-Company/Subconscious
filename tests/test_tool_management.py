"""The assistant's tool/skill management tools, the built-in guidance skill and the chat wiring."""
import asyncio
import json
import sys
from pathlib import Path

import pytest

from subconscious_engine.agents import AgentExecutionResult
from subconscious_engine.api.websocket import WebSocketSession
from subconscious_engine.approval import ApprovalConfig
from subconscious_engine.services.builtin_skills import MANAGING_TOOLS_DESCRIPTION, MANAGING_TOOLS_INSTRUCTIONS
from subconscious_engine.services.skills import SkillService, build_skills_index, read_skill_tool, select_skills
from subconscious_engine.services.tool_management import FORCED_APPROVAL, READ_ONLY
from test_api import auth, run
from test_configured_tools import FIXTURE, RecordingAgent, TurnSocket, turn_fixture
from test_oauth import (CALLBACK, authorization_url, browse, callback_path, create_oauth_tool, fake_oauth_mcp,
                        oauth_app, wait_for)

NO_APPROVAL = ApprovalConfig(create=False, read=False, update=False, delete=False)


def tools_by_name(app, approval=NO_APPROVAL, reserved=()):
    return {tool.name: tool for tool in app.state.tool_management.tools(approval, reserved=reserved)}


def test_mutating_tools_always_require_approval_even_when_the_user_disabled_it(tmp_path):
    async def scenario():
        async with oauth_app(tmp_path) as (client, app, _):
            tools = tools_by_name(app)
            assert set(tools) == FORCED_APPROVAL | READ_ONLY and len(tools) == 14
            for name in FORCED_APPROVAL:
                assert tools[name].requires_approval is True, name
            for name in READ_ONLY:
                assert tools[name].requires_approval is False, name
            asking = tools_by_name(app, ApprovalConfig())  # read tools follow the user's policy
            assert all(asking[name].requires_approval is True for name in READ_ONLY)
            assert "add_mcp_server" not in tools_by_name(app, reserved={"add_mcp_server"})
            # The approval card classifies them sensibly.
            from subconscious_engine.approval import classify_operation
            assert {name: classify_operation(name) for name in (
                "add_mcp_server", "add_cli_tool", "update_configured_tool", "remove_configured_tool",
                "test_configured_tool", "connect_tool", "disconnect_tool", "list_configured_tools",
                "create_skill", "remove_skill", "get_skill_info")} == {
                "add_mcp_server": "create", "add_cli_tool": "create", "update_configured_tool": "update",
                "remove_configured_tool": "delete", "test_configured_tool": "update", "connect_tool": "update",
                "disconnect_tool": "update", "list_configured_tools": "read", "create_skill": "create",
                "remove_skill": "delete", "get_skill_info": "read"}

    run(scenario())


def test_add_update_list_get_remove_round_trip_with_names_resolved_case_insensitively(tmp_path):
    async def scenario():
        async with oauth_app(tmp_path) as (client, app, _):
            tools = tools_by_name(app)
            add_mcp, add_cli = tools["add_mcp_server"].function, tools["add_cli_tool"].function

            added = await add_mcp(name="Echo Box", command=sys.executable, args=[FIXTURE],
                                  env={"TEST_MARKER": "super-secret-looking-value"}, description="Echo server")
            assert added["ok"] is True and added["type"] == "mcp" and added["transport"] == "stdio"
            assert added["status"] == "idle" and added["enabled"] is True
            cli = await add_cli(name="Git", command="git", args=["status"], description="Git")
            assert cli["ok"] is True and cli["type"] == "cli"
            http = await add_mcp(name="Hosted", url="https://hosted.example/mcp")
            assert http["transport"] == "http" and http["authType"] is None
            mail = await add_mcp(name="Mailbox", url="https://mail.example/mcp", auth="oauth",
                                 oauth_scopes="mail.read")
            assert mail["authType"] == "oauth" and mail["oauthConnected"] is False
            assert mail["status"] == "needs_auth" and "connect_tool" in mail["next"]

            # validation lives in the REST layer and is reported as data, not raised
            assert "exactly one" in (await add_mcp(name="Bad"))["error"]
            assert "exactly one" in (await add_mcp(name="Bad", command="x", url="https://x.example"))["error"]
            assert "remote url" in (await add_mcp(name="Bad", command="x", auth="oauth"))["error"]
            assert "already exists" in (await add_cli(name="git", command="git"))["error"]
            assert (await add_mcp(name="Bad", url="ftp://x"))["ok"] is False
            assert (await add_cli(name="", command="git"))["ok"] is False

            # API keys must never travel through the model
            refused = await add_mcp(name="Keyed", url="https://k.example/mcp", auth="api_key_header")
            assert refused["ok"] is False and "Settings > Tools" in refused["error"]
            assert (await tools["update_configured_tool"].function(name="Hosted", auth="api_key_header"))["ok"] is False
            assert (await add_mcp(name="Weird", url="https://k.example/mcp", auth="magic"))["ok"] is False

            listing = await tools["list_configured_tools"].function()
            by_alias = {item["alias"]: item for item in listing}
            assert set(by_alias) == {"Echo Box", "Git", "Hosted", "Mailbox"}
            assert set(by_alias["Echo Box"]) >= {"name", "alias", "type", "transport", "enabled", "status",
                                                 "authType", "oauthConnected"}
            assert "super-secret-looking-value" not in json.dumps(listing)
            info = await tools["get_configured_tool"].function(name="echo box")
            assert info["envKeys"] == ["TEST_MARKER"] and "super-secret-looking-value" not in json.dumps(info)
            assert (await tools["get_configured_tool"].function(name=info["id"]))["alias"] == "Echo Box"
            assert (await tools["get_configured_tool"].function(name="nope"))["ok"] is False

            # test: a stdio server really starts; an OAuth tool reports needsAuth instead of waiting
            tested = await tools["test_configured_tool"].function(name="ECHO BOX")
            assert tested["ok"] is True and "echo_box__echo" in tested["tools"] and tested["needsAuth"] is False
            assert (await tools["list_configured_tools"].function())[0]["tools"]
            needs = await tools["test_configured_tool"].function(name="Mailbox")
            assert needs == {"ok": False, "tools": [], "error": "Sign-in required.", "needsAuth": True}

            # update only changes what was passed; disabling and renaming work
            updated = await tools["update_configured_tool"].function(
                name="Echo Box", description="New text", enabled=False, new_name="Echo Server")
            assert updated["ok"] is True and updated["enabled"] is False and updated["status"] == "disabled"
            assert updated["alias"] == "Echo Server"
            record = await tools["get_configured_tool"].function(name="Echo Server")
            assert record["description"] == "New text" and record["command"] == sys.executable
            assert record["envKeys"] == ["TEST_MARKER"]
            moved = await tools["update_configured_tool"].function(name="Hosted", url="https://new.example/mcp")
            assert moved["ok"] is True
            assert (await tools["get_configured_tool"].function(name="Hosted"))["url"] == "https://new.example/mcp"
            to_cmd = await tools["update_configured_tool"].function(name="Hosted", command="npx", args=["-y", "x"])
            assert to_cmd["transport"] == "stdio"
            assert (await tools["update_configured_tool"].function(name="Git", url="https://x.example"))["ok"] is False
            assert (await tools["update_configured_tool"].function(name="Git", new_name="Mailbox"))["ok"] is False

            removed = await tools["remove_configured_tool"].function(name="Echo Server")
            assert removed == {"ok": True, "removed": "Echo Server"}
            assert (await tools["remove_configured_tool"].function(name="Echo Server"))["ok"] is False
            assert len(await tools["list_configured_tools"].function()) == 3
            await app.state.configured_tools.close()

    run(scenario())


def test_ambiguous_names_list_the_matches_and_ids_disambiguate(tmp_path):
    async def scenario():
        async with oauth_app(tmp_path) as (client, app, _):
            tools = tools_by_name(app)
            ids = []
            for alias in ("First", "Second"):
                created = await client.post("/api/v1/tool-registry", headers=auth(), json={
                    "name": "shared", "alias": alias, "toolType": "cli", "command": sys.executable})
                ids.append(created.json()["uuid"])
            ambiguous = await tools["get_configured_tool"].function(name="shared")
            assert ambiguous["ok"] is False and "ambiguous" in ambiguous["error"]
            assert "First" in ambiguous["error"] and "Second" in ambiguous["error"] and ids[0] in ambiguous["error"]
            assert (await tools["get_configured_tool"].function(name=ids[1]))["alias"] == "Second"
            assert (await tools["get_configured_tool"].function(name="second"))["id"] == ids[1]

    run(scenario())


def test_connect_tool_awaits_the_user_and_returns_after_the_callback(tmp_path):
    async def scenario():
        async with fake_oauth_mcp() as fake, oauth_app(tmp_path) as (client, app, store):
            broker = app.state.oauth_broker
            frames = []

            async def notify(frame_type, data):
                frames.append((frame_type, data))

            broker.attach("turn-1", notify)
            tools = tools_by_name(app)
            added = await tools["add_mcp_server"].function(name="Mailbox", url=fake.url, auth="oauth")
            assert added["ok"] is True
            call = asyncio.ensure_future(tools["connect_tool"].function(name="mailbox"))
            await wait_for(lambda: broker.pending_for_tool(added["id"]) is not None)
            assert not call.done()  # it is waiting for the person
            assert frames[0][0] == "oauth.request" and frames[0][1]["tool_name"] == "Mailbox"
            location = await browse(frames[0][1]["url"])
            assert (await client.get(callback_path(location))).status_code == 200
            result = await asyncio.wait_for(call, 15)
            assert result["connected"] is True and result["tools"] == ["mailbox__ping"]
            assert "next message" in result["note"]
            assert [kind for kind, _ in frames] == ["oauth.request", "oauth.resolved"]
            listed = (await tools["list_configured_tools"].function())[0]
            assert listed["status"] == "connected" and listed["oauthConnected"] is True
            assert listed["tools"] == ["mailbox__ping"]
            assert "tokens" in await store.get_tool_oauth(added["id"])

            forgotten = await tools["disconnect_tool"].function(name="Mailbox")
            assert forgotten["ok"] is True and "tokens" not in await store.get_tool_oauth(added["id"])
            assert (await tools["list_configured_tools"].function())[0]["status"] == "needs_auth"
            plain = await tools["add_cli_tool"].function(name="Plain", command=sys.executable)
            assert "OAuth" in (await tools["connect_tool"].function(name="Plain"))["error"]
            assert (await tools["disconnect_tool"].function(name="Plain"))["ok"] is False
            assert plain["ok"] is True

    run(scenario())


def test_connect_tool_reports_denial_timeout_and_cancels_when_the_turn_is_cancelled(tmp_path):
    async def scenario():
        async with fake_oauth_mcp() as fake, oauth_app(tmp_path) as (client, app, _):
            broker = app.state.oauth_broker
            tools = tools_by_name(app)
            uuid = (await tools["add_mcp_server"].function(name="Mailbox", url=fake.url, auth="oauth"))["id"]

            call = asyncio.ensure_future(tools["connect_tool"].function(name="Mailbox"))
            await wait_for(lambda: broker.pending_for_tool(uuid) is not None)
            state = parse_state(broker.pending_for_tool(uuid).url)
            denied = await client.get(f"/api/v1/oauth/callback?state={state}&error=access_denied")
            assert denied.status_code == 200
            result = await asyncio.wait_for(call, 15)
            assert result["connected"] is False and "denied" in result["error"]

            call = asyncio.ensure_future(tools["connect_tool"].function(name="Mailbox"))
            await wait_for(lambda: broker.pending_for_tool(uuid) is not None)
            call.cancel()  # the chat turn was cancelled
            with pytest.raises(asyncio.CancelledError):
                await call
            await wait_for(lambda: broker.pending_for_tool(uuid) is None)
            assert (await client.get("/api/v1/oauth/pending", headers=auth())).json() == []
            await wait_for(lambda: uuid not in app.state.configured_tools._flows)

            broker.timeout = 0.3
            result = await asyncio.wait_for(tools["connect_tool"].function(name="Mailbox"), 15)
            assert result == {"connected": False, "error": "Sign-in was not completed in time."}

    run(scenario())


def parse_state(url):
    from urllib.parse import parse_qs, urlsplit
    return parse_qs(urlsplit(url).query)["state"][0]


# --- skills ------------------------------------------------------------------------------------------
def test_skill_tools_and_the_builtin_managing_tools_skill(tmp_path):
    async def scenario():
        async with oauth_app(tmp_path) as (client, app, _):
            tools = tools_by_name(app)
            assert (await tools["list_skills"].function()) == [{
                "name": "managing-tools", "description": MANAGING_TOOLS_DESCRIPTION,
                "enabled": True, "type": "builtin", "valid": True}]
            created = await tools["create_skill"].function(
                name="deploy", description="Deploy checklist", instructions="Step 1\nStep 2")
            assert created == {"ok": True, "name": "deploy"}
            assert (await tools["create_skill"].function(name="deploy", description="x", instructions="y"))["ok"] is False
            assert (await tools["create_skill"].function(name="managing-tools", description="x",
                                                         instructions="y"))["ok"] is False
            assert (await tools["create_skill"].function(name="big", description="x",
                                                         instructions="z" * 20001))["ok"] is False
            assert (await tools["create_skill"].function(name="bad name!", description="x", instructions="y"))["ok"] is False
            info = await tools["get_skill_info"].function(name="DEPLOY")
            assert info["instructions"] == "Step 1\nStep 2" and info["type"] == "text"
            assert (await tools["get_skill_info"].function(name="managing-tools"))["instructions"] \
                == MANAGING_TOOLS_INSTRUCTIONS
            updated = await tools["update_skill"].function(name="deploy", description="New", enabled=False)
            assert updated["ok"] is True
            info = await tools["get_skill_info"].function(name="deploy")
            assert info["description"] == "New" and info["enabled"] is False and info["instructions"] == "Step 1\nStep 2"
            assert (await tools["update_skill"].function(name="deploy", instructions="z" * 20001))["ok"] is False
            assert (await tools["update_skill"].function(name="managing-tools", description="x"))["ok"] is False
            assert (await tools["update_skill"].function(name="ghost", description="x"))["ok"] is False
            assert (await tools["remove_skill"].function(name="managing-tools"))["ok"] is False
            assert (await tools["remove_skill"].function(name="deploy")) == {"ok": True, "removed": "deploy"}
            assert (await tools["remove_skill"].function(name="deploy"))["ok"] is False

            # Built-in skills are not part of the REST list and cannot be deleted through it.
            assert (await client.get("/api/v1/skills", headers=auth())).json() == []

            async with app.state.database.session() as session:
                snapshots = await SkillService(session).snapshots()
            assert [s.name for s in snapshots] == ["managing-tools"]
            index = build_skills_index(select_skills(snapshots))
            assert index.startswith("- managing-tools: ")
            reader = read_skill_tool(select_skills(snapshots, '["something-else"]'), NO_APPROVAL)
            assert reader.function(name="managing-tools") == MANAGING_TOOLS_INSTRUCTIONS.strip()
            for needle in ("connect_tool", "api key", "Settings > Tools", "next message", "approval",
                           "remote", "stdio", "never ask the user to paste secrets"):
                assert needle.casefold() in MANAGING_TOOLS_INSTRUCTIONS.casefold().replace("\n", " "), needle

    run(scenario())


def test_a_user_skill_with_the_same_name_replaces_the_builtin(tmp_path):
    async def scenario():
        async with oauth_app(tmp_path) as (client, app, _):
            from subconscious_engine.api.extra_schemas import UpsertSkillRequest
            async with app.state.database.session() as session:
                await SkillService(session).create(UpsertSkillRequest(
                    name="Managing-Tools", sourceType="text", instructions="mine"))
                snapshots = await SkillService(session).snapshots()
            assert [(s.name, s.instructions) for s in snapshots] == [("Managing-Tools", "mine")]

    run(scenario())


# --- chat turn wiring ---------------------------------------------------------------------------------
class SigningInAgent(RecordingAgent):
    """An agent whose 'tool call' starts an OAuth sign-in while the turn is running."""

    def __init__(self, app):
        super().__init__()
        self.app = app

    async def execute(self, config, prompt, history, tools, approve, system_prompt=None, event_sink=None):
        broker = self.app.state.oauth_broker
        redirect_handler, _ = broker.handlers("tool-1", "Mail")
        await redirect_handler(authorization_url("turn-state"))
        await broker.complete("turn-state", "code")
        return await super().execute(config, prompt, history, tools, approve, system_prompt, event_sink)


def test_chat_turn_offers_management_tools_with_forced_approval_and_forwards_oauth_frames(tmp_path):
    async def scenario():
        database, app, agent = await turn_fixture(tmp_path)
        try:
            app.state.agent_manager = SigningInAgent(app)
            app.state.oauth_broker.set_port(51516)
            session = WebSocketSession(TurnSocket(app))
            outcome = await session._run_turn("turn-1", {"content": "hi", "workspace_uuid": "ws"})
            assert outcome == ("done", None), session.socket.sent
            names = {tool.name: tool for tool in app.state.agent_manager.tools}
            # the workspace turned approval OFF for read+update; management tools ignore that
            assert names["add_mcp_server"].requires_approval is True
            assert names["connect_tool"].requires_approval is True
            assert names["list_configured_tools"].requires_approval is False
            assert "run_py" in names and "read_skill" in names
            frames = [frame for frame in session.socket.sent if frame["type"].startswith("oauth.")]
            assert [frame["type"] for frame in frames] == ["oauth.request", "oauth.resolved"]
            request, resolved = frames
            assert request["id"] == "turn-1"
            thread_uuid = next(f["data"]["thread_uuid"] for f in session.socket.sent if f["type"] == "chat.done")
            assert set(request["data"]) == {"auth_id", "tool_uuid", "tool_name", "url", "redirect_uri",
                                            "expires_in", "thread_uuid"}
            assert request["data"]["thread_uuid"] == thread_uuid and request["data"]["tool_uuid"] == "tool-1"
            assert request["data"]["redirect_uri"] == CALLBACK
            assert resolved["data"] == {"auth_id": request["data"]["auth_id"], "tool_uuid": "tool-1",
                                        "status": "authorized"}
            assert app.state.oauth_broker._listeners == {}  # detached when the turn ended

            # tools disabled: no management tools
            await session._run_turn("turn-2", {"content": "hi", "workspace_uuid": "ws", "tools_enabled": False})
            assert "add_mcp_server" not in [t.name for t in app.state.agent_manager.tools]
        finally:
            await app.state.configured_tools.close()
            await database.close()

    run(scenario())


def test_tools_for_turn_never_waits_for_a_person_even_with_a_sign_in_in_flight(tmp_path):
    async def scenario():
        async with fake_oauth_mcp() as fake, oauth_app(tmp_path) as (client, app, _):
            runtime = app.state.configured_tools
            uuid = (await create_oauth_tool(client, fake.url))["uuid"]
            started = (await client.post(f"/api/v1/tool-registry/{uuid}/authorize", headers=auth())).json()
            assert started["status"] == "pending"
            began = asyncio.get_running_loop().time()
            assert await runtime.tools_for_turn(ApprovalConfig()) == []  # the interactive start holds the row
            result = await runtime.test(uuid)
            assert result["needsAuth"] is True
            assert asyncio.get_running_loop().time() - began < 2
            # editing the row while the card is open cancels the sign-in instead of hanging
            body = {"alias": "Mail", "toolType": "mcp", "endpointUrl": fake.url, "authType": "oauth",
                    "description": "changed"}
            assert (await asyncio.wait_for(client.put(f"/api/v1/tool-registry/{uuid}", headers=auth(), json=body),
                                           10)).status_code == 200
            assert app.state.oauth_broker.pending_for_tool(uuid) is None

    run(scenario())
