import asyncio
from unittest.mock import patch

from pydantic_ai import Tool
from pydantic_ai.messages import ModelResponse, TextPart, ToolCallPart, ToolReturnPart
from pydantic_ai.models.function import FunctionModel
from pydantic_ai.models.test import TestModel

from subconscious_engine.agents import AgentManager
from subconscious_engine.configuration.models import ModelConfig
from subconscious_engine.tools.filesystem_tools import filesystem_tool_entries


def run(coro):
    return asyncio.run(coro)


def test_approved_tool_resumes_the_agent_and_produces_a_final_response():
    async def scenario():
        events: list[str] = []

        async def approved_action() -> str:
            events.append("tool")
            return "tool-returned"

        async def approve(call) -> bool:
            assert call.tool_name == "approved_action"
            assert events == []
            events.append("approval")
            return True

        tool = Tool(approved_action, name="approved_action",
                    description="A test tool.", requires_approval=True)
        config = ModelConfig(id="test", provider="openai", model="test")
        with patch.object(AgentManager, "_model", return_value=TestModel(
            call_tools=["approved_action"], custom_output_text="completed"
        )):
            result = await AgentManager().execute(config, "do the action", [], [tool], approve)

        assert result.text == "completed"
        assert events == ["approval", "tool"]
        assert result.tool_records[0] == {
            "toolName": "approved_action", "input": {}, "approval": "approved",
        }
        assert any(record.get("toolName") == "approved_action"
                   and record.get("output") == "tool-returned"
                   for record in result.tool_records)

    run(scenario())


def test_denied_tool_does_not_run_and_the_agent_still_completes_its_turn():
    async def scenario():
        tool_calls = 0

        async def denied_action() -> str:
            nonlocal tool_calls
            tool_calls += 1
            return "should not run"

        async def deny(call) -> bool:
            assert call.tool_name == "denied_action"
            return False

        tool = Tool(denied_action, name="denied_action",
                    description="A test tool.", requires_approval=True)
        config = ModelConfig(id="test", provider="openai", model="test")
        with patch.object(AgentManager, "_model", return_value=TestModel(
            call_tools=["denied_action"], custom_output_text="completed"
        )):
            result = await AgentManager().execute(config, "do the action", [], [tool], deny)

        assert result.text == "completed"
        assert tool_calls == 0
        assert result.tool_records[0] == {
            "toolName": "denied_action", "input": {}, "approval": "denied",
        }
        assert any(record.get("toolName") == "denied_action"
                   and record.get("output") == "The tool call was denied."
                   for record in result.tool_records)

    run(scenario())


def test_binary_file_read_failure_is_returned_to_model_and_turn_continues(tmp_path):
    async def scenario():
        pdf = tmp_path / "document.pdf"
        pdf.write_bytes(b"%PDF-1.7\n\xff\xfe\x00binary\n%%EOF")
        read_factory = next(
            factory for _, name, _, factory in filesystem_tool_entries()
            if name == "read_filesystem_file"
        )
        read_tool = Tool(read_factory(None), name="read_filesystem_file",
                         description="Read a text file.")
        calls = 0

        def model(messages, _info):
            nonlocal calls
            calls += 1
            if calls == 1:
                return ModelResponse(parts=[ToolCallPart(
                    "read_filesystem_file", {"path": str(pdf)}, "read-pdf"
                )])
            returns = [
                part for message in messages for part in message.parts
                if isinstance(part, ToolReturnPart) and part.tool_call_id == "read-pdf"
            ]
            assert len(returns) == 1
            assert returns[0].content["status"] == "error"
            assert "error" in returns[0].content
            return ModelResponse(parts=[TextPart("I could not read the PDF, but can still rename it.")])

        config = ModelConfig(id="test", provider="openai", model="test")
        with patch.object(AgentManager, "_model", return_value=FunctionModel(model)):
            result = await AgentManager().execute(
                config, "Inspect and rename the PDF", [], [read_tool],
                lambda _call: asyncio.sleep(0, result=True),
            )

        assert calls == 2
        assert result.text == "I could not read the PDF, but can still rename it."
        assert any(
            record.get("toolName") == "read_filesystem_file"
            and record.get("output", {}).get("status") == "error"
            for record in result.tool_records
        )

    run(scenario())
