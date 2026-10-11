import asyncio

import pytest

from subconscious_engine.agents import AgentExecutionResult
from subconscious_engine.configuration.models import ModelConfig
from subconscious_engine.graph_engine import GraphEngine
from subconscious_engine.graphs import (
    GraphCompiler, GraphDependencies, GraphKind, GraphRuntimeState,
    GraphSchema, NodeResult, load_graph_schema, render_state_template,
)
from subconscious_engine.telemetry import TelemetryStore
from subconscious_engine.tool_registry import PortableToolRegistry, ToolRegistryConfig


def run(coro):
    return asyncio.run(coro)


def schema(prompt="Context: {{ state.user_context }}"):
    return GraphSchema.model_validate({
        "schema_version": 1,
        "graph_id": "test.graph",
        "kind": "foreground",
        "entry_node": "answer",
        "nodes": [
            {"id": "answer", "type": "llm", "system_prompt": prompt,
             "tools": [], "transitions": [{"target": "done"}]},
            {"id": "done", "type": "end"},
        ],
    })


def test_schema_templates_defaults_and_scope_validation():
    assert render_state_template("Hi {{ state.person.name }}", {"person": {"name": "Ada"}}) == "Hi Ada"
    with pytest.raises(ValueError, match="missing"):
        render_state_template("{{ state.missing }}", {})
    with pytest.raises(ValueError, match="only supports"):
        schema("{{ arbitrary_code() }}")
    conscious = load_graph_schema(GraphKind.FOREGROUND)
    subconscious = load_graph_schema(GraphKind.SUBCONSCIOUS)
    assert conscious.graph_id == "subconscious.conscious.default"
    assert subconscious.graph_id == "subconscious.meta.daily"
    assert subconscious.nodes[0].tools[0].startswith("subconscious:")


def test_compiler_runs_dynamic_pydantic_graph_nodes():
    async def scenario():
        compiled = GraphCompiler().compile(schema())

        async def llm(node, system_prompt, state):
            assert node.id == "answer"
            assert system_prompt == "Context: portable"
            return NodeResult(output="complete")

        async def tool(node, state):
            raise AssertionError("no tool node expected")

        result = await compiled.run(
            GraphRuntimeState({"user_context": "portable"}),
            GraphDependencies(llm, tool),
        )
        assert result == "complete"
        assert set(compiled.nodes) == {"answer", "done"}
    run(scenario())


class FakeAgentManager:
    prompts = []

    async def execute(self, config, prompt, history, tools, approve,
                      system_prompt=None, event_sink=None):
        self.prompts.append(system_prompt)
        if event_sink is not None:
            await event_sink({"type": "model.delta", "delta": "foreground result"})
        return AgentExecutionResult(
            "foreground result",
            [{"toolName": "search", "input": {"q": "x"}, "outcome": "success"}],
            12,
            4,
        )


def test_foreground_runner_saves_node_and_tool_telemetry(tmp_path):
    async def scenario():
        telemetry = TelemetryStore(tmp_path / "telemetry.db")
        await telemetry.initialize()
        engine = GraphEngine(
            telemetry,
            PortableToolRegistry(ToolRegistryConfig()),
            schema(),
            GraphSchema.model_validate({
                "schema_version": 1, "graph_id": "meta", "kind": "subconscious",
                "entry_node": "done", "nodes": [{"id": "done", "type": "end"}],
            }),
            FakeAgentManager(),
        )
        events = []

        async def event_sink(event):
            events.append(event)

        result = await engine.run_conscious(
            ModelConfig(id="fake", provider="subconscious", model="fake"),
            "hello", [], [], lambda call: asyncio.sleep(0, result=True),
            state={"user_context": "test", "active_skills": []},
            event_sink=event_sink,
        )
        assert result.text == "foreground result"
        assert not await telemetry.needs_reflection(result.run_id)
        rows = await telemetry.read_runs([result.run_id])
        assert rows[0]["final_status"] == "SUCCESS"
        assert rows[0]["tool_invocations"][0]["tool_name"] == "search"
        assert {event["type"] for event in events} >= {
            "run.started", "node.started", "node.completed", "run.completed"
        }
    run(scenario())


def test_context_policy_uses_selected_models_context_window():
    node = schema().nodes[0]
    history = [("user", "a" * 4000), ("assistant", "b" * 4000)]
    fitted = GraphEngine._fit_history(
        ModelConfig(
            id="small", provider="subconscious", model="small", context_window=2048
        ),
        node,
        "short system prompt",
        "short request",
        history,
    )
    assert len(fitted) < len(history)


class RoutingAgentManager:
    async def execute(self, config, prompt, history, tools, approve,
                      system_prompt=None, event_sink=None):
        if system_prompt.startswith("Classify the user's request"):
            return AgentExecutionResult("coding", [], 3, 1)
        assert "implementation-focused coding assistant" in system_prompt
        return AgentExecutionResult("validated code result", [], 8, 4)


def test_default_conscious_graph_routes_to_specialist_without_streaming_classifier(tmp_path):
    async def scenario():
        telemetry = TelemetryStore(tmp_path / "routing.db")
        await telemetry.initialize()
        conscious = load_graph_schema(GraphKind.FOREGROUND)
        assert {node.id for node in conscious.nodes} == {
            "route_request", "general", "deep_research", "coding", "goal", "done"
        }
        engine = GraphEngine(
            telemetry,
            PortableToolRegistry(ToolRegistryConfig()),
            conscious,
            GraphSchema.model_validate({
                "schema_version": 1, "graph_id": "meta", "kind": "subconscious",
                "entry_node": "done", "nodes": [{"id": "done", "type": "end"}],
            }),
            RoutingAgentManager(),
        )
        events = []
        result = await engine.run_conscious(
            ModelConfig(id="fake", provider="subconscious", model="fake"),
            "Fix and test this code", [], [],
            lambda call: asyncio.sleep(0, result=True),
            event_sink=lambda event: asyncio.sleep(0, result=events.append(event)),
        )
        assert result.text == "validated code result"
        assert not any(event.get("type") == "model.delta" and
                       event.get("node_id") == "route_request" for event in events)
        rows = await telemetry.read_runs([result.run_id])
        assert [trace["node_id"] for trace in rows[0]["node_traces"]] == [
            "route_request", "coding"
        ]
    run(scenario())
