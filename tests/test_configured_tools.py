"""Configured tools: tool-registry config/validation/test endpoint and the chat-time runtime."""

import asyncio
import json
import logging
import os
import signal
import sys
import time
from pathlib import Path
from uuid import uuid4

import pytest
from sqlalchemy import select

from subconscious_engine.agents import AgentExecutionResult
from subconscious_engine.api.websocket import WebSocketSession
from subconscious_engine.approval import ApprovalConfig
from subconscious_engine.services.configured_tools import (
    ConfiguredToolRuntime,
    split_arguments,
    unique_name,
)
from subconscious_engine.storage import Database
from subconscious_engine.storage.models import ToolRegistryRecord, Workspace, Network

from test_api import FakeRag, FakeStore, api_client, auth, run

FIXTURE = str(Path(__file__).parent / "fixtures" / "echo_mcp_server.py")


def mcp_config(**extra):
    return json.dumps({"command": sys.executable, "args": [FIXTURE], **extra})


def py_cli(code):
    return json.dumps({"command": sys.executable, "args": ["-c", code]})


async def add_row(database, alias, tool_type, config_json=None, status="active", **fields):
    async with database.session() as session:
        identifier = str(uuid4())
        session.add(ToolRegistryRecord(uuid=identifier, name=alias.lower(), alias=alias, tool_type=tool_type,
                                       config_json=config_json, status=status, **fields))
        await session.commit()
    return identifier


class Creds:
    async def get_tool_auth_config(self, identifier):
        return None


class Runtime:
    """A runtime on a scratch database, always closed (kills any MCP server)."""

    def __init__(self, tmp_path, **options):
        self.database = Database(tmp_path / "rt.db")
        self.options = options

    async def __aenter__(self):
        await self.database.initialize()
        self.runtime = ConfiguredToolRuntime(self.database, Creds(), **self.options)
        return self.database, self.runtime

    async def __aexit__(self, *exc):
        await self.runtime.close()
        await self.database.close()


def by_name(tools):
    return {tool.name: tool for tool in tools}


# --- MCP runtime -----------------------------------------------------------------------------


def test_mcp_tools_are_prefixed_classified_called_and_the_connection_is_reused(tmp_path):
    async def scenario():
        async with Runtime(tmp_path) as (database, runtime):
            await add_row(database, "Echo Box", "mcp", mcp_config(env={"TEST_MARKER": "hello"}))
            tools = by_name(await runtime.tools_for_turn(ApprovalConfig(read=False)))
            assert {"echo_box__echo", "echo_box__shout", "echo_box__server_info"} <= set(tools)
            assert all(len(name) <= 64 for name in tools)
            # readOnlyHint -> read (approval off here); no hint + classify("shout") -> update (asks).
            assert tools["echo_box__echo"].requires_approval is False
            assert tools["echo_box__shout"].requires_approval is True
            assert "text" in tools["echo_box__echo"].function_schema.json_schema["properties"]
            assert await tools["echo_box__echo"].function(text="hi") == "hi"
            assert await tools["echo_box__shout"].function(text="hi") == "HI"
            first = (await tools["echo_box__server_info"].function()).split(":")
            # A second turn builds new tools but must reuse the same server process (state is kept).
            again = by_name(await runtime.tools_for_turn(ApprovalConfig()))
            second = (await again["echo_box__server_info"].function()).split(":")
            assert first[0] == second[0] and int(second[1]) == int(first[1]) + 1
            assert second[2] == "hello"  # configured env reaches the server
            with pytest.raises(RuntimeError, match="boom"):
                await tools["echo_box__explode"].function()

    run(scenario())


def test_invalidate_and_a_dead_process_restart_the_server(tmp_path):
    async def scenario():
        async with Runtime(tmp_path) as (database, runtime):
            uuid = await add_row(database, "Echo", "mcp", mcp_config())

            async def pid():
                tools = by_name(await runtime.tools_for_turn(ApprovalConfig()))
                return (await tools["echo__server_info"].function()).split(":")[0]

            first = await pid()
            assert await pid() == first
            await runtime.invalidate(uuid)
            second = await pid()
            assert second != first
            os.kill(int(second), signal.SIGTERM)
            await asyncio.sleep(0.5)
            assert await pid() not in {first, second}

    run(scenario())


def test_a_broken_server_is_skipped_with_a_warning_naming_the_tool(tmp_path, caplog):
    async def scenario():
        async with Runtime(tmp_path, mcp_start_timeout=20) as (database, runtime):
            await add_row(database, "Broken Box", "mcp", json.dumps({"command": "definitely-not-a-command-xyz"}))
            await add_row(database, "Good", "mcp", mcp_config())
            with caplog.at_level(logging.INFO):
                tools = by_name(await runtime.tools_for_turn(ApprovalConfig()))
            assert "good__echo" in tools and not any(name.startswith("broken_box") for name in tools)

    run(scenario())
    problems = [r for r in caplog.records if r.levelno == logging.WARNING and "Broken Box" in r.getMessage()]
    assert problems and any("error=" in r.getMessage() for r in problems)
    assert any("mcp.server.connected" in r.getMessage() for r in caplog.records)


def test_inactive_rows_and_other_types_are_ignored_and_names_are_unique(tmp_path):
    async def scenario():
        async with Runtime(tmp_path) as (database, runtime):
            await add_row(database, "Off", "mcp", mcp_config(), status="inactive")
            await add_row(database, "Meta", "script")
            await add_row(database, "Dup", "cli", py_cli("print(1)"))
            await add_row(database, "dup", "cli", py_cli("print(2)"))
            names = [tool.name for tool in await runtime.tools_for_turn(ApprovalConfig(), reserved={"run_dup"})]
            assert len(names) == len(set(names)) == 2 and "run_dup" not in names
            assert all(name.startswith("run_dup") for name in names)
        assert unique_name("a" * 70, set()) == "a" * 64
        used = {"x"}
        assert unique_name("x", used) == "x_2" and unique_name("x", used) == "x_3"

    run(scenario())


# --- CLI runtime -----------------------------------------------------------------------------


def test_cli_tool_runs_without_a_shell_with_fixed_args_first(tmp_path):
    async def scenario():
        async with Runtime(tmp_path) as (database, runtime):
            await add_row(database, "Py Tool", "cli", py_cli("import sys;print('hi',sys.argv[1:]);sys.exit(3)"),
                          description="Runs python.")
            tool = (await runtime.tools_for_turn(ApprovalConfig()))[0]
            assert tool.name == "run_py_tool" and tool.requires_approval is True
            assert tool.description.startswith("Runs python.") and "arguments" in tool.description
            assert (await runtime.tools_for_turn(ApprovalConfig(update=False)))[0].requires_approval is False
            result = await tool.function(arguments="a 'b c' ; echo no-shell")
            assert result["exitCode"] == 3 and result["truncated"] is False
            assert result["stdout"].strip() == "hi ['a', 'b c', ';', 'echo', 'no-shell']"
            assert (await tool.function())["stdout"].strip() == "hi []"

    run(scenario())


def test_cli_timeout_kills_and_output_is_capped(tmp_path):
    async def scenario():
        async with Runtime(tmp_path, cli_timeout=1.0) as (database, runtime):
            await add_row(database, "Slow", "cli", py_cli("import time;time.sleep(60)"))
            await add_row(database, "Loud", "cli", py_cli("print('x'*50000)"))
            tools = by_name(await runtime.tools_for_turn(ApprovalConfig()))
            started = time.monotonic()
            result = await tools["run_slow"].function()
            assert time.monotonic() - started < 20
            assert result["exitCode"] == -1 and "Timed out" in result["stderr"]
            loud = await tools["run_loud"].function()
            assert len(loud["stdout"]) == 20000 and loud["truncated"] is True and loud["exitCode"] == 0

    run(scenario())


def test_cli_with_missing_command_is_skipped_and_split_arguments_strip_windows_quotes():
    assert split_arguments('one "two words" three') == ["one", "two words", "three"]

    async def scenario(tmp_path):
        async with Runtime(tmp_path) as (database, runtime):
            await add_row(database, "Ghost", "cli", json.dumps({"command": "no-such-binary-xyz"}))
            assert await runtime.tools_for_turn(ApprovalConfig()) == []

    import tempfile
    with tempfile.TemporaryDirectory() as directory:
        run(scenario(Path(directory)))


# --- API ---------------------------------------------------------------------------------------


def test_registry_stores_config_validates_it_and_reports_transport(tmp_path):
    async def scenario():
        async with api_client(tmp_path) as (client, app):
            async def post(body):
                return await client.post("/api/v1/tool-registry", headers=auth(), json=body)

            cli = await post({"alias": "Git", "toolType": "cli", "command": "git", "args": ["status"],
                              "cwd": str(tmp_path)})
            assert cli.status_code == 201, cli.text
            assert cli.json()["command"] == "git" and cli.json()["args"] == ["status"]
            assert cli.json()["cwd"] == str(tmp_path) and cli.json()["transport"] is None
            stdio = await post({"alias": "S", "toolType": "mcp", "command": "x", "args": ["a"],
                                "env": {"A_1": "v"}})
            assert stdio.status_code == 201 and stdio.json()["transport"] == "stdio"
            assert stdio.json()["env"] == {"A_1": "v"}
            http = await post({"alias": "H", "toolType": "mcp", "endpointUrl": "https://example.test/mcp"})
            assert http.status_code == 201 and http.json()["transport"] == "http"
            assert http.json()["command"] is None and http.json()["args"] is None
            fetched = (await client.get(f"/api/v1/tool-registry/{stdio.json()['uuid']}", headers=auth())).json()
            assert fetched["command"] == "x" and fetched["transport"] == "stdio"
            async with app.state.database.session() as session:
                row = await session.scalar(select(ToolRegistryRecord).where(ToolRegistryRecord.alias == "S"))
                assert json.loads(row.config_json)["env"] == {"A_1": "v"}

            for body in (
                {"alias": "x", "toolType": "mcp"},
                {"alias": "x", "toolType": "mcp", "command": "c", "endpointUrl": "https://example.test"},
                {"alias": "x", "toolType": "mcp", "endpointUrl": "https://example.test", "args": ["a"]},
                {"alias": "x", "toolType": "mcp", "endpointUrl": "ftp://example.test"},
                {"alias": "x", "toolType": "cli"},
                {"alias": "x", "toolType": "cli", "command": "c", "endpointUrl": "https://example.test"},
                {"alias": "x", "toolType": "cli", "command": "c", "authType": "api_key"},
                {"alias": "x", "toolType": "script", "command": "c"},
                {"alias": "x", "toolType": "mcp", "command": "c", "env": {"1BAD": "v"}},
                {"alias": "x", "toolType": "mcp", "command": "c", "env": {"has space": "v"}},
                {"alias": "x", "toolType": "mcp", "command": "c", "env": {"A": "v" * 5000}},
                {"alias": "x", "toolType": "mcp", "command": "c", "args": ["a"] * 65},
                {"alias": "x", "toolType": "mcp", "command": "c", "args": ["a" * 5000]},
                {"alias": "x", "toolType": "mcp", "command": "c", "env": {f"K{i}": "v" for i in range(65)}},
            ):
                bad = await post(body)
                assert bad.status_code == 400 and bad.json()["error"], body
            assert (await post({"alias": "x", "toolType": "mcp", "command": "c", "args": [1]})).status_code == 400
            assert (await post({"alias": "x", "toolType": "mcp", "command": "c", "env": {"A": 1}})).status_code == 400

    run(scenario())


def test_test_endpoint_for_cli_script_and_unknown_tools(tmp_path):
    async def scenario():
        async with api_client(tmp_path) as (client, app):
            async def create(body):
                return (await client.post("/api/v1/tool-registry", headers=auth(), json=body)).json()["uuid"]

            async def test(uuid):
                return await client.post(f"/api/v1/tool-registry/{uuid}/test", headers=auth())

            good = await test(await create({"alias": "Py", "toolType": "cli", "command": sys.executable}))
            assert good.status_code == 200
            assert good.json() == {"ok": True, "error": None, "needsAuth": False, "tools": [
                {"name": "run_py", "description": good.json()["tools"][0]["description"], "operation": "update"}]}
            missing = (await test(await create({"alias": "Ghost", "toolType": "cli",
                                                "command": "no-such-binary-xyz"}))).json()
            assert missing["ok"] is False and missing["tools"] == [] and "no-such-binary-xyz" in missing["error"]
            script = (await test(await create({"alias": "S", "toolType": "script", "scriptPath": "a.py"}))).json()
            assert script == {"ok": False, "tools": [], "needsAuth": False,
                              "error": "This tool type is not executed by the engine."}
            assert (await test("missing")).status_code == 404

    run(scenario())


def test_test_endpoint_lists_mcp_tools_reuses_the_connection_and_updates_drop_it(tmp_path):
    async def scenario():
        async with api_client(tmp_path) as (client, app):
            try:
                body = {"alias": "Echo", "toolType": "mcp", "command": sys.executable, "args": [FIXTURE]}
                created = (await client.post("/api/v1/tool-registry", headers=auth(), json=body)).json()
                url = f"/api/v1/tool-registry/{created['uuid']}/test"
                first = await client.post(url, headers=auth())
                assert first.status_code == 200 and first.json()["ok"] is True
                operations = {t["name"]: t["operation"] for t in first.json()["tools"]}
                assert operations["echo__echo"] == "read" and operations["echo__shout"] == "update"
                assert "echo__shout" in operations and all(t["description"] for t in first.json()["tools"])
                runtime = app.state.configured_tools
                connection = runtime._connections[created["uuid"]]
                assert (await client.post(url, headers=auth())).json()["ok"] is True
                assert runtime._connections[created["uuid"]] is connection  # reused, not restarted
                body["alias"] = "Echo2"
                assert (await client.put(f"/api/v1/tool-registry/{created['uuid']}",
                                         headers=auth(), json=body)).status_code == 200
                assert created["uuid"] not in runtime._connections  # change drops the live server
                await client.post(url, headers=auth())
                assert created["uuid"] in runtime._connections
                assert (await client.delete(f"/api/v1/tool-registry/{created['uuid']}", headers=auth())).status_code == 204
                assert created["uuid"] not in runtime._connections
            finally:
                await app.state.configured_tools.close()

    run(scenario())


def test_test_endpoint_reports_a_broken_mcp_command_without_a_500(tmp_path):
    async def scenario():
        async with api_client(tmp_path) as (client, app):
            created = (await client.post("/api/v1/tool-registry", headers=auth(), json={
                "alias": "Bad", "toolType": "mcp", "command": "no-such-binary-xyz"})).json()
            response = await client.post(f"/api/v1/tool-registry/{created['uuid']}/test", headers=auth())
            assert response.status_code == 200
            assert response.json()["ok"] is False and response.json()["error"] and response.json()["tools"] == []
            await app.state.configured_tools.close()

    run(scenario())


# --- a real chat turn --------------------------------------------------------------------------


class RecordingAgent:
    def __init__(self):
        self.tools, self.system_prompt = [], None

    async def execute(self, config, prompt, history, tools, approve, system_prompt=None, event_sink=None):
        self.tools, self.system_prompt = list(tools), system_prompt
        return AgentExecutionResult("ok", [])


class RecordingGraph:
    def __init__(self):
        self.tools, self.state = [], None

    async def run_conscious(self, model, prompt, history, tools, approve, state=None, event_sink=None):
        self.tools, self.state = list(tools), state
        return AgentExecutionResult("ok", [])


class TurnSocket:
    def __init__(self, app):
        self.app, self.sent, self.client = app, [], None

    async def send_json(self, value):
        self.sent.append(value)


async def turn_fixture(tmp_path, *, graph=None, skills_config=None, skill_dir=None):
    from subconscious_engine.api.app import create_app
    from subconscious_engine.auth import EngineAuthToken

    database = Database(tmp_path / "turn.db")
    await database.initialize()
    agent = RecordingAgent()
    app = create_app(database, EngineAuthToken("t"), model_configuration_store=FakeStore(), rag_service=FakeRag(),
                     agent_manager=agent, graph_engine=graph, dev_models=True)
    async with database.session() as session:
        network = Network(uuid="n", name="net")
        session.add(network)
        await session.flush()
        session.add(Workspace(name="W", uuid="ws", network_id=network.id, skills_config=skills_config,
                              approval_config=json.dumps({"read": False, "update": False})))
        await session.commit()
    await add_row(database, "Py", "cli", py_cli("print('ran')"))
    return database, app, agent


def test_chat_turn_gets_configured_tools_and_read_skill_on_the_non_graph_path(tmp_path):
    from subconscious_engine.services.skills import SkillService
    from subconscious_engine.api.extra_schemas import UpsertSkillRequest

    async def scenario():
        database, app, agent = await turn_fixture(tmp_path)
        try:
            async with database.session() as session:
                await SkillService(session).create(UpsertSkillRequest(
                    name="deploy", sourceType="text", instructions="Run the deploy checklist.\nStep 1."))
            session = WebSocketSession(TurnSocket(app))
            outcome = await session._run_turn("turn-1", {"content": "hi", "workspace_uuid": "ws"})
            assert outcome == ("done", None), session.socket.sent
            names = [tool.name for tool in agent.tools]
            assert "run_py" in names and "read_skill" in names
            read_skill = next(t for t in agent.tools if t.name == "read_skill")
            assert read_skill.requires_approval is False  # read=False in the workspace approval config
            assert "- deploy: Run the deploy checklist." in agent.system_prompt
            assert read_skill.function(name="deploy").startswith("Run the deploy checklist.")
            # tools disabled -> neither configured tools nor read_skill
            await session._run_turn("turn-2", {"content": "hi", "workspace_uuid": "ws", "tools_enabled": False})
            assert "run_py" not in [t.name for t in agent.tools] and agent.system_prompt is None
        finally:
            await app.state.configured_tools.close()
            await database.close()

    run(scenario())


def test_chat_turn_passes_the_skills_index_through_the_graph_path_and_honours_skills_config(tmp_path):
    from subconscious_engine.services.skills import SkillService
    from subconscious_engine.api.extra_schemas import UpsertSkillRequest

    async def scenario():
        graph = RecordingGraph()
        database, app, _ = await turn_fixture(tmp_path, graph=graph)
        try:
            async with database.session() as session:
                service = SkillService(session)
                for name in ("alpha", "beta"):
                    await service.create(UpsertSkillRequest(name=name, sourceType="text", instructions=f"{name} body"))
                await service.create(UpsertSkillRequest(name="off", sourceType="text", instructions="x", enabled=False))
            socket_session = WebSocketSession(TurnSocket(app))

            async def turn():
                outcome = await socket_session._run_turn("t", {"content": "hi", "workspace_uuid": "ws"})
                assert outcome == ("done", None)
                return graph.state["active_skills"], [t.name for t in graph.tools]

            def user_part(text):  # the built-in managing-tools skill is always offered with tools
                lines = text.splitlines()
                assert lines[-1].startswith("- managing-tools: ")
                return "\n".join(lines[:-1])

            index, names = await turn()
            assert user_part(index) == "- alpha: alpha body\n- beta: beta body"  # disabled skills are never listed
            assert "read_skill" in names and "run_py" in names
            for raw, expected in (('["beta"]', "- beta: beta body"), ("[]", user_part(index)),
                                  ("not json", user_part(index)), ('{"a": 1}', user_part(index))):
                async with database.session() as session:
                    workspace = await session.scalar(select(Workspace))
                    workspace.skills_config = raw
                    await session.commit()
                assert user_part((await turn())[0]) == expected
            async with database.session() as session:
                for skill in await SkillService(session).list():
                    await SkillService(session).delete(skill.uuid)
            index, names = await turn()
            assert user_part(index) == "" and "read_skill" in names  # only the built-in skill remains
        finally:
            await app.state.configured_tools.close()
            await database.close()

    run(scenario())
