import asyncio
from unittest.mock import patch

from pydantic_ai import Tool
from pydantic_ai.models.test import TestModel

from subconscious_engine.agents import AgentManager
from subconscious_engine.configuration.models import ModelConfig
from subconscious_engine.tool_events import bounded, tool_call_event, tool_kind


def run(coro):
    return asyncio.run(coro)


def test_kinds_follow_name_then_operation():
    assert tool_kind("read_filesystem_file") == "read"
    assert tool_kind("write_filesystem_file") == "edit"
    assert tool_kind("delete_filesystem_path") == "delete"
    assert tool_kind("move_filesystem_path") == "move"
    assert tool_kind("search_knowledge") == "search"
    assert tool_kind("run_command") == "execute"
    assert tool_kind("kiro__run_thing") == "execute"
    assert tool_kind("mystery") == "edit"  # unknown names classify as update


def test_payloads_are_bounded_and_flagged():
    value, truncated = bounded("x" * 20, limit=5)
    assert value == "xxxxx" and truncated
    event = tool_call_event(tool_call_id="1", tool_name="read_file", status="completed",
                            output="y" * 9000)
    assert event["output_truncated"] is True and len(event["output"]) == 8000


def test_approved_tool_reports_pending_in_progress_completed_once_each():
    async def scenario():
        events = []

        async def sink(event):
            events.append(event)

        async def action() -> str:
            return "ok"

        async def approve(_call) -> bool:
            return True

        tool = Tool(action, name="action", description="t", requires_approval=True)
        config = ModelConfig(id="test", provider="openai", model="test")
        with patch.object(AgentManager, "_model",
                          return_value=TestModel(call_tools=["action"], custom_output_text="done")):
            await AgentManager().execute(config, "go", [], [tool], approve, event_sink=sink)
        calls = [e for e in events if e["type"] == "tool.call"]
        assert [e["status"] for e in calls] == ["pending", "in_progress", "completed"]
        assert len({e["tool_call_id"] for e in calls}) == 1
        assert calls[-1]["output"] == "ok"

    run(scenario())


def test_denied_tool_reports_failed():
    async def scenario():
        events = []

        async def sink(event):
            events.append(event)

        async def action() -> str:
            return "never"

        async def deny(_call) -> bool:
            return False

        tool = Tool(action, name="action", description="t", requires_approval=True)
        config = ModelConfig(id="test", provider="openai", model="test")
        with patch.object(AgentManager, "_model",
                          return_value=TestModel(call_tools=["action"], custom_output_text="done")):
            await AgentManager().execute(config, "go", [], [tool], deny, event_sink=sink)
        statuses = [e["status"] for e in events if e["type"] == "tool.call"]
        assert statuses[0] == "pending" and statuses[-1] == "failed"

    run(scenario())
