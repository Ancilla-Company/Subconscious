"""Compile declarative schemas into stable ``pydantic-graph`` nodes and graphs."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any, ClassVar

from pydantic_graph import BaseNode, End, Graph, GraphRunContext

from .schema import (
    ConditionNode,
    EndNode,
    GraphSchema,
    LlmNode,
    NodeSchema,
    ToolNode,
    predicate_matches,
    render_state_template,
)


@dataclass(slots=True)
class GraphRuntimeState:
    values: dict[str, Any] = field(default_factory=dict)
    output: str = ""


@dataclass(frozen=True, slots=True)
class NodeResult:
    output: str = ""
    state_updates: dict[str, Any] = field(default_factory=dict)


LlmExecutor = Callable[[LlmNode, str, GraphRuntimeState], Awaitable[NodeResult]]
ToolExecutor = Callable[[ToolNode, GraphRuntimeState], Awaitable[NodeResult]]
EventSink = Callable[[dict[str, Any]], Awaitable[None]]


async def _discard_event(_: dict[str, Any]) -> None:
    return None


@dataclass(slots=True)
class GraphDependencies:
    execute_llm: LlmExecutor
    execute_tool: ToolExecutor
    emit: EventSink = _discard_event


class DeclarativeNode(BaseNode[GraphRuntimeState, GraphDependencies, str]):
    definition: ClassVar[NodeSchema]
    next_nodes: dict[str, "DeclarativeNode"]

    def __init__(self) -> None:
        self.next_nodes = {}

    async def run(
        self, ctx: GraphRunContext[GraphRuntimeState, GraphDependencies]
    ) -> BaseNode[GraphRuntimeState, GraphDependencies, str] | End[str]:
        node = self.definition
        await ctx.deps.emit({"type": "node.started", "node_id": node.id})
        if isinstance(node, EndNode):
            await ctx.deps.emit({"type": "node.completed", "node_id": node.id})
            return End(ctx.state.output)
        if isinstance(node, LlmNode):
            prompt = render_state_template(node.system_prompt, ctx.state.values)
            result = await ctx.deps.execute_llm(node, prompt, ctx.state)
        elif isinstance(node, ToolNode):
            result = await ctx.deps.execute_tool(node, ctx.state)
        elif isinstance(node, ConditionNode):
            result = NodeResult()
        else:  # pragma: no cover - schema discrimination makes this unreachable
            raise TypeError(f"Unsupported graph node: {type(node).__name__}")
        if result.output:
            ctx.state.output = result.output
            ctx.state.values["last_output"] = result.output
        ctx.state.values.update(result.state_updates)
        await ctx.deps.emit({"type": "node.completed", "node_id": node.id})
        for transition in node.transitions:
            if predicate_matches(transition.when, ctx.state.values):
                return self.next_nodes[transition.target]
        raise RuntimeError(f"No transition matched after node '{node.id}'.")


@dataclass(frozen=True, slots=True)
class CompiledGraph:
    schema: GraphSchema
    graph: Graph[GraphRuntimeState, GraphDependencies, str]
    start_node: DeclarativeNode
    nodes: dict[str, DeclarativeNode]

    async def run(
        self, state: GraphRuntimeState, dependencies: GraphDependencies
    ) -> str:
        result = await self.graph.run(self.start_node, state=state, deps=dependencies)
        return result.output


class GraphCompiler:
    """Creates a distinct ``BaseNode`` subclass for every schema node."""

    def compile(self, schema: GraphSchema | dict[str, Any] | str) -> CompiledGraph:
        if isinstance(schema, str):
            definition = GraphSchema.model_validate_json(schema)
        elif isinstance(schema, dict):
            definition = GraphSchema.model_validate(schema)
        else:
            definition = schema
        instances: dict[str, DeclarativeNode] = {}
        classes: list[type[DeclarativeNode]] = []
        for node in definition.nodes:
            node_id = node.id

            @classmethod
            def get_node_id(cls: type[DeclarativeNode], value: str = node_id) -> str:
                return value

            node_class = type(
                f"Declarative_{node_id.replace('-', '_')}",
                (DeclarativeNode,),
                {"definition": node, "get_node_id": get_node_id},
            )
            classes.append(node_class)
            instances[node_id] = node_class()
        for node in definition.nodes:
            instances[node.id].next_nodes = {
                transition.target: instances[transition.target]
                for transition in node.transitions
            }
        graph = Graph(
            nodes=classes,
            name=definition.graph_id,
            state_type=GraphRuntimeState,
            run_end_type=str,
        )
        return CompiledGraph(
            schema=definition,
            graph=graph,
            start_node=instances[definition.entry_node],
            nodes=instances,
        )
