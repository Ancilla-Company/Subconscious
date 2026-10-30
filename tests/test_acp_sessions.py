"""Persistent ACP agent sessions: context kept between prompts, idle timeout, ending, process cleanup."""

import asyncio
import re
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

from subconscious_engine.approval import ApprovalConfig
from subconscious_engine.services.acp_sessions import AcpSessionError, AcpSessionManager, SessionSpec
from subconscious_engine.services.process_tree import descendants, is_alive, stop_tree
from subconscious_engine.tool_events import progress_sink

from test_api import run
from test_configured_tools import Runtime, add_row, by_name

AGENT = str(Path(__file__).parent / "fake_acp_agent.py")


def spec(permissions="read_only", label="Fake"):
    return SessionSpec("row-1", label, [sys.executable, AGENT], None, None, permissions)


def manager(**kwargs):
    return AcpSessionManager(**{"idle_default": 5.0, "idle_min": 0.1, "idle_max": 60.0, "prompt_timeout": 30.0, **kwargs})


async def wait_until(predicate, seconds=8.0):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        await asyncio.sleep(0.05)
    return predicate()


def number(pattern, text):
    return int(re.search(pattern, text).group(1))


def test_a_session_keeps_one_agent_and_its_memory_across_prompts():
    async def scenario():
        sessions = manager()
        session = await sessions.start(spec())
        try:
            await session.prompt("remember apples")
            await session.prompt("remember pears")
            recalled = await session.prompt("recall")
            assert recalled.text == "memory=apples,pears" and recalled.stop_reason == "end_turn"
            first = number(r"pid=(\d+)", (await session.prompt("pid")).text)
            second = number(r"pid=(\d+)", (await session.prompt("pid")).text)
            assert first == second  # the same agent process served every prompt
            assert session.prompts == 5 and session.state == "idle"
            assert session.info()["agent"] == "Fake" and session.info()["idleExpiresInSeconds"] <= 5
        finally:
            await sessions.close_all()

    run(scenario())


def test_an_idle_session_ends_by_itself_and_its_process_is_gone():
    async def scenario():
        sessions = manager(idle_default=0.5)
        session = await sessions.start(spec())
        pid = number(r"pid=(\d+)", (await session.prompt("pid")).text)
        assert is_alive(pid)
        assert await wait_until(lambda: session.state == "closed")
        assert "idle" in session.closed_reason
        assert sessions.live() == []
        assert await wait_until(lambda: not is_alive(pid))
        with pytest.raises(AcpSessionError):
            await session.prompt("hello")
        with pytest.raises(AcpSessionError):
            sessions.get(session.handle)

    run(scenario())


def test_the_idle_timer_does_not_run_while_waiting_for_the_agent_and_restarts_after():
    async def scenario():
        sessions = manager(idle_default=0.4)
        session = await sessions.start(spec())
        try:
            reply = await session.prompt("slow")  # takes ~1s: longer than the idle timeout
            assert reply.text == "slow done"
            assert session.state == "idle"  # it was not ended while the engine was waiting
            assert (await session.prompt("recall")).text == "memory="  # still the same live session
            assert await wait_until(lambda: session.state == "closed")  # the timer ran once it was idle
            assert sessions.live() == []
        finally:
            await sessions.close_all()

    run(scenario())


def test_each_prompt_restarts_the_idle_timer():
    async def scenario():
        sessions = manager(idle_default=0.8)
        session = await sessions.start(spec())
        try:
            for _ in range(4):
                await asyncio.sleep(0.4)  # 1.6s in total, twice the idle timeout
                await session.prompt("recall")
                assert session.state == "idle"
        finally:
            await sessions.close_all()

    run(scenario())


def test_the_assistant_can_end_a_session_and_ending_twice_is_harmless():
    async def scenario():
        sessions = manager()
        session = await sessions.start(spec())
        pid = number(r"pid=(\d+)", (await session.prompt("pid")).text)
        summary = await sessions.end(session.handle, "the assistant ended it")
        assert summary["ok"] is True and summary["prompts"] == 1 and summary["endedBecause"] == "the assistant ended it"
        assert await wait_until(lambda: not is_alive(pid))
        again = await session.end("again")
        assert again["endedBecause"] == "the assistant ended it"
        with pytest.raises(AcpSessionError):
            await sessions.end(session.handle, "x")

    run(scenario())


def test_ending_a_session_also_stops_helper_processes_that_outlive_the_agent():
    async def scenario():
        sessions = manager()
        session = await sessions.start(spec())
        child = number(r"child=(\d+)", (await session.prompt("spawn")).text)
        assert is_alive(child)
        await session.end("done")
        assert await wait_until(lambda: not is_alive(child)), "the detached helper kept running"

    run(scenario())


def test_an_agent_that_exits_on_its_own_ends_the_session():
    async def scenario():
        import os
        import signal
        sessions = manager()
        session = await sessions.start(spec())
        pid = number(r"pid=(\d+)", (await session.prompt("pid")).text)
        os.kill(pid, signal.SIGTERM)
        assert await wait_until(lambda: session.state == "closed")
        assert session.closed_reason == "the agent exited" and sessions.live() == []

    run(scenario())


def test_an_agent_that_stops_answering_is_not_reused():
    async def scenario():
        sessions = manager(prompt_timeout=1.0)
        session = await sessions.start(spec())
        reply = await session.prompt("hang")
        assert reply.stop_reason == "failed" and "timed out" in reply.error
        assert session.state == "closed" and "stopped answering" in session.closed_reason

    run(scenario())


def test_one_prompt_at_a_time_and_a_session_limit():
    async def scenario():
        sessions = manager(max_sessions=1)
        session = await sessions.start(spec())
        try:
            running = asyncio.create_task(session.prompt("slow"))
            await asyncio.sleep(0.3)
            with pytest.raises(AcpSessionError, match="still working"):
                await session.prompt("recall")
            await running
            with pytest.raises(AcpSessionError, match="At most 1"):
                await sessions.start(spec())
        finally:
            await sessions.close_all()

    run(scenario())


def test_a_command_that_cannot_start_is_reported_without_leaving_a_session():
    async def scenario():
        sessions = manager()
        bad = SessionSpec("r", "Nope", ["definitely-not-a-real-agent-binary"], None, None, "read_only")
        with pytest.raises(AcpSessionError, match="Could not start"):
            await sessions.start(bad)
        assert sessions.live() == []

    run(scenario())


def test_idle_timeout_requests_are_clamped():
    sessions = manager(idle_default=600, idle_min=30, idle_max=3600)
    assert sessions.clamp_idle(None) == 600 and sessions.clamp_idle(0) == 600
    assert sessions.clamp_idle(5) == 30 and sessions.clamp_idle(99999) == 3600 and sessions.clamp_idle(120) == 120


def test_stop_tree_stops_a_process_and_a_grandchild_that_outlived_it():
    async def scenario():
        code = ("import subprocess, sys, time\n"
                "c = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'])\n"
                "print(c.pid, flush=True)\n"
                "time.sleep(120)\n")
        process = await asyncio.create_subprocess_exec(sys.executable, "-c", code, stdout=asyncio.subprocess.PIPE)
        grandchild = int((await process.stdout.readline()).decode())
        assert grandchild in descendants(process.pid)
        await stop_tree(process, grace=2.0)
        assert process.returncode is not None
        assert await wait_until(lambda: not is_alive(grandchild))

    run(scenario())


# --- the tools the assistant sees -------------------------------------------------------------


def acp_row_config(**extra):
    import json
    return json.dumps({"command": sys.executable, "args": [AGENT], **extra})


def test_tools_start_send_list_and_end_a_session_with_the_right_approvals(tmp_path):
    async def scenario():
        async with Runtime(tmp_path, acp_timeout=30) as (database, runtime):
            await add_row(database, "Helper Agent", "acp", acp_row_config(permissions="allow_all"))
            tools = by_name(await runtime.tools_for_turn(ApprovalConfig()))
            assert {"start_agent_session", "send_agent_session", "end_agent_session",
                    "list_agent_sessions", "ask_helper_agent"} <= set(tools)
            # Invoking the agent asks; stopping it and listing do not.
            assert tools["start_agent_session"].requires_approval is True
            assert tools["send_agent_session"].requires_approval is True
            assert tools["end_agent_session"].requires_approval is False
            assert tools["list_agent_sessions"].requires_approval is False
            assert "Helper Agent" in tools["start_agent_session"].description
            relaxed = by_name(await runtime.tools_for_turn(ApprovalConfig(update=False)))
            assert relaxed["start_agent_session"].requires_approval is False

            assert (await tools["start_agent_session"].function(agent="nobody"))["ok"] is False
            started = await tools["start_agent_session"].function(agent="helper agent", idle_timeout_seconds=120)
            assert started["ok"] is True and started["idleTimeoutSeconds"] == 120 and started["state"] == "idle"
            handle = started["session"]

            events = []

            async def sink(event):
                events.append(event)

            token = progress_sink.set(sink)
            try:
                first = await tools["send_agent_session"].function(SimpleNamespace(tool_call_id="call-1"), handle, "read")
            finally:
                progress_sink.reset(token)
            assert first["ok"] is True and first["sessionState"] == "idle" and first["session"] == handle
            assert any(e["tool_call_id"] == "call-1" and e["step"]["kind"] == "tool" for e in events)

            await tools["send_agent_session"].function(None, handle, "remember tea")
            recalled = await tools["send_agent_session"].function(None, handle, "recall")
            assert recalled["output"] == "memory=tea"

            listed = await tools["list_agent_sessions"].function()
            assert [item["session"] for item in listed] == [handle] and listed[0]["prompts"] == 3

            ended = await tools["end_agent_session"].function(handle)
            assert ended["ok"] is True and ended["prompts"] == 3
            assert await tools["list_agent_sessions"].function() == []
            gone = await tools["send_agent_session"].function(None, handle, "recall")
            assert gone["ok"] is False and "No open agent session" in gone["error"]
            assert (await tools["end_agent_session"].function(handle))["ok"] is False

    run(scenario())


def test_no_session_tools_without_an_acp_agent_and_unknown_cwd_is_reported(tmp_path):
    async def scenario():
        async with Runtime(tmp_path) as (database, runtime):
            assert not {"start_agent_session", "list_agent_sessions"} & set(
                by_name(await runtime.tools_for_turn(ApprovalConfig())))
            await add_row(database, "Helper Agent", "acp", acp_row_config())
            tools = by_name(await runtime.tools_for_turn(ApprovalConfig()))
            missing = await tools["start_agent_session"].function(agent="Helper Agent", cwd=str(tmp_path / "nope"))
            assert missing["ok"] is False and "does not exist" in missing["error"]

    run(scenario())


def test_changing_the_agent_or_closing_the_runtime_ends_its_sessions(tmp_path):
    async def scenario():
        async with Runtime(tmp_path) as (database, runtime):
            uuid = await add_row(database, "Helper Agent", "acp", acp_row_config())
            tools = by_name(await runtime.tools_for_turn(ApprovalConfig()))
            first = (await tools["start_agent_session"].function(agent="Helper Agent"))["session"]
            await runtime.invalidate(uuid)  # the row was edited or deleted
            assert runtime.acp_sessions.live() == []
            second = (await tools["start_agent_session"].function(agent="Helper Agent"))["session"]
            assert second != first and len(runtime.acp_sessions.live()) == 1
            await runtime.close()
            assert runtime.acp_sessions.live() == []

    run(scenario())
