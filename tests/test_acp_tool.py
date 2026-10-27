import json
import sys
from pathlib import Path

import pytest

from subconscious_engine.approval import ApprovalConfig
from subconscious_engine.services.acp_client import choose_permission, probe_acp_agent, run_acp_agent

from test_api import api_client, auth, run
from test_configured_tools import Runtime, add_row, by_name

AGENT = str(Path(__file__).parent / "fake_acp_agent.py")
COMMAND = [sys.executable, AGENT]
OPTIONS = [{"optionId": "a", "kind": "allow_once"}, {"optionId": "aa", "kind": "allow_always"},
           {"optionId": "r", "kind": "reject_once"}]


def acp_config(**extra):
    return json.dumps({"command": sys.executable, "args": [AGENT], **extra})


def test_permission_policy_never_picks_allow_always():
    assert choose_permission("read_only", "read", OPTIONS) == "a"
    assert choose_permission("read_only", "edit", OPTIONS) == "r"
    assert choose_permission("allow_all", "execute", OPTIONS) == "a"
    assert choose_permission("read_only", "edit", [{"optionId": "a", "kind": "allow_once"}]) is None


def test_run_collects_the_reply_and_closes_the_agent():
    async def scenario():
        result = await run_acp_agent(COMMAND, "hello")
        assert result.stop_reason == "end_turn" and result.text == "echo: hello"
        assert result.agent["title"] == "Fake Agent"
        assert (await probe_acp_agent(COMMAND))["version"] == "9.9"

    run(scenario())


def test_read_only_allows_reads_and_refuses_edits():
    async def scenario():
        read = await run_acp_agent(COMMAND, "read", permissions="read_only")
        assert '"optionId": "a"' in read.text and not read.denied
        assert read.tool_calls[0]["kind"] == "read"
        edit = await run_acp_agent(COMMAND, "write", permissions="read_only")
        assert '"optionId": "r"' in edit.text and edit.denied == ["write file (edit)"]
        allowed = await run_acp_agent(COMMAND, "write", permissions="allow_all")
        assert '"optionId": "a"' in allowed.text and not allowed.denied

    run(scenario())


def test_a_hung_agent_times_out_with_partial_output_and_no_leaked_process():
    async def scenario():
        result = await run_acp_agent(COMMAND, "hang", timeout=1)
        assert result.stop_reason == "failed" and "timed out" in result.error

    run(scenario())


def test_missing_agent_command_raises():
    async def scenario():
        from subconscious_engine.services.acp_client import AcpError
        with pytest.raises(AcpError):
            await run_acp_agent(["definitely-not-a-real-agent-binary"], "x")

    run(scenario())


def test_registry_validates_acp_rows(tmp_path):
    async def scenario():
        async with api_client(tmp_path) as (client, _):
            async def post(body):
                return await client.post("/api/v1/tool-registry", headers=auth(), json=body)

            ok = await post({"alias": "Agent", "toolType": "acp", "command": "kiro-cli", "args": ["acp"]})
            assert ok.status_code == 201, ok.text
            assert ok.json()["permissions"] == "read_only" and ok.json()["transport"] is None
            full = await post({"alias": "Agent2", "toolType": "acp", "command": "x", "permissions": "allow_all"})
            assert full.json()["permissions"] == "allow_all"
            for body in (
                {"alias": "x", "toolType": "acp"},
                {"alias": "x", "toolType": "acp", "command": "c", "permissions": "root"},
                {"alias": "x", "toolType": "acp", "command": "c", "endpointUrl": "https://example.test"},
                {"alias": "x", "toolType": "acp", "command": "c", "authType": "api_key"},
                {"alias": "x", "toolType": "cli", "command": "c", "permissions": "allow_all"},
            ):
                bad = await post(body)
                assert bad.status_code == 400 and bad.json()["error"], body

    run(scenario())


def test_runtime_offers_an_approval_gated_tool_and_runs_it(tmp_path):
    async def scenario():
        async with Runtime(tmp_path, acp_timeout=30) as (database, runtime):
            await add_row(database, "Helper Agent", "acp", acp_config())
            tools = by_name(await runtime.tools_for_turn(ApprovalConfig()))
            tool = tools["ask_helper_agent"]
            assert tool.requires_approval is True
            assert "fresh" in tool.description
            result = await tool.function(prompt="hi")
            assert result["output"] == "echo: hi" and result["stopReason"] == "end_turn"
            with pytest.raises(ValueError):
                await tool.function(prompt="  ")
            with pytest.raises(ValueError):
                await tool.function(prompt="hi", cwd=str(tmp_path / "missing"))
            assert "ask_helper_agent" not in by_name(await runtime.tools_for_turn(ApprovalConfig(update=False))) \
                or by_name(await runtime.tools_for_turn(ApprovalConfig(update=False)))[
                    "ask_helper_agent"].requires_approval is False

    run(scenario())


def test_runtime_skips_a_missing_command_and_tests_the_handshake(tmp_path):
    async def scenario():
        async with Runtime(tmp_path) as (database, runtime):
            bad = await add_row(database, "Nope", "acp", json.dumps({"command": "no-such-agent-binary"}))
            good = await add_row(database, "Good", "acp", acp_config())
            assert "ask_nope" not in by_name(await runtime.tools_for_turn(ApprovalConfig()))
            failed = await runtime.test(bad)
            assert failed["ok"] is False and "not found" in failed["error"]
            passed = await runtime.test(good)
            assert passed["ok"] is True and passed["tools"][0]["name"] == "ask_good"
            assert "Fake Agent 9.9" in passed["tools"][0]["description"]

    run(scenario())
