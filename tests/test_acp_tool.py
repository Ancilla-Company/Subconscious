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
            result = await tool.function(None, prompt="hi")  # no run context outside an agent run
            assert result["output"] == "echo: hi" and result["stopReason"] == "end_turn"
            with pytest.raises(ValueError):
                await tool.function(None, prompt="  ")
            with pytest.raises(ValueError):
                await tool.function(None, prompt="hi", cwd=str(tmp_path / "missing"))
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


def test_subagent_steps_reach_the_turn_progress_sink_and_the_result_is_unchanged(tmp_path):
    from types import SimpleNamespace
    from subconscious_engine.tool_events import progress_sink

    async def scenario():
        events = []

        async def sink(event):
            events.append(event)

        async with Runtime(tmp_path, acp_timeout=30) as (database, runtime):
            await add_row(database, "Helper Agent", "acp", acp_config(permissions="allow_all"))
            tool = by_name(await runtime.tools_for_turn(ApprovalConfig()))["ask_helper_agent"]
            token = progress_sink.set(sink)
            try:
                result = await tool.function(SimpleNamespace(tool_call_id="call-7"), prompt="read")
            finally:
                progress_sink.reset(token)
        assert '"optionId": "a"' in result["output"]
        assert events and all(e["type"] == "tool.progress" and e["tool_call_id"] == "call-7" for e in events)
        steps = [e["step"] for e in events]
        tool_step = next(s for s in steps if s["kind"] == "tool")
        assert tool_step["id"] == "tool-c1" and tool_step["title"] == "read file" and tool_step["tool_kind"] == "read"
        message = [s for s in steps if s["kind"] == "message"][-1]
        assert "outcome=" in message["text"]  # the final message step carries the whole reply

    run(scenario())


def test_subagent_progress_throttles_chunks_but_always_sends_the_last_one():
    from subconscious_engine.services.subagent_progress import SubAgentProgress

    async def scenario():
        sent = []

        async def sink(event):
            sent.append(event["step"])

        now = [0.0]
        progress = SubAgentProgress(sink, "c", clock=lambda: now[0])
        chunk = lambda text: {"sessionUpdate": "agent_message_chunk", "content": {"text": text}}
        await progress.on_update(chunk("a"))      # first chunk goes out at once
        await progress.on_update(chunk("b"))      # 0s later: held back
        now[0] = 0.1
        await progress.on_update(chunk("c"))      # still inside the interval
        assert [s["text"] for s in sent] == ["a"]
        await progress.finish()
        assert [s["text"] for s in sent] == ["a", "abc"]
        # a tool call closes the message; the next text is a new step
        await progress.on_update({"sessionUpdate": "tool_call", "toolCallId": "t", "title": "x", "kind": "read"})
        now[0] = 5.0
        await progress.on_update(chunk("d"))
        assert sent[-1] == {"id": "message-1", "kind": "message", "text": "d"}
        # no sink or no call id: inert
        assert SubAgentProgress(None, "c").active is False and SubAgentProgress(sink, None).active is False

    run(scenario())
