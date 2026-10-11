"""Validated, portable JSON schemas for executable agent graphs."""

from __future__ import annotations

from enum import Enum
import re
from typing import Any, Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


_TEMPLATE = re.compile(r"{{\s*state\.([A-Za-z_][\w.]*)\s*}}")
_UNRESOLVED = re.compile(r"{{.*?}}")


class GraphKind(str, Enum):
    FOREGROUND = "foreground"
    SUBCONSCIOUS = "subconscious"


class Predicate(BaseModel):
    model_config = ConfigDict(extra="forbid")
    path: str
    operator: Literal["equals", "not_equals", "exists", "truthy"] = "equals"
    value: Any = None


class Transition(BaseModel):
    model_config = ConfigDict(extra="forbid")
    target: str
    when: Predicate | None = None


class ContextPolicy(BaseModel):
    model_config = ConfigDict(extra="forbid")
    context_window: int = Field(default=32_768, ge=1_024)
    reserved_output_tokens: int = Field(default=4_096, ge=256)
    overflow_strategy: Literal["truncate_oldest", "summarize", "reject"] = "truncate_oldest"


class NodeSchema(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: str = Field(pattern=r"^[A-Za-z][A-Za-z0-9_-]{0,63}$")
    transitions: list[Transition] = Field(default_factory=list)


class LlmNode(NodeSchema):
    type: Literal["llm"] = "llm"
    model: str = "$request"
    system_prompt: str
    tools: list[str] = Field(default_factory=list)
    context: ContextPolicy = Field(default_factory=ContextPolicy)
    output_state: str | None = Field(default=None, pattern=r"^[A-Za-z_][A-Za-z0-9_.-]{0,63}$")
    stream: bool = True

    @model_validator(mode="after")
    def validate_template(self) -> "LlmNode":
        rendered_markers = _TEMPLATE.sub("", self.system_prompt)
        if _UNRESOLVED.search(rendered_markers):
            raise ValueError("system_prompt only supports {{ state.<dotted_path> }} templates")
        return self


class ToolNode(NodeSchema):
    type: Literal["tool"] = "tool"
    tool: str
    arguments: dict[str, Any] = Field(default_factory=dict)


class ConditionNode(NodeSchema):
    type: Literal["condition"] = "condition"


class EndNode(NodeSchema):
    type: Literal["end"] = "end"

    @model_validator(mode="after")
    def no_transitions(self) -> "EndNode":
        if self.transitions:
            raise ValueError("end nodes cannot define transitions")
        return self


GraphNode = Annotated[LlmNode | ToolNode | ConditionNode | EndNode, Field(discriminator="type")]


class GraphSchema(BaseModel):
    """Versioned graph definition that can be persisted or transported as JSON."""

    model_config = ConfigDict(extra="forbid")
    schema_version: Literal[1] = 1
    graph_id: str = Field(pattern=r"^[A-Za-z][A-Za-z0-9_.-]{0,127}$")
    kind: GraphKind
    entry_node: str
    description: str = ""
    nodes: list[GraphNode]

    @model_validator(mode="after")
    def validate_topology(self) -> "GraphSchema":
        ids = [node.id for node in self.nodes]
        if not ids:
            raise ValueError("a graph must contain at least one node")
        if len(ids) != len(set(ids)):
            raise ValueError("node ids must be unique")
        if self.entry_node not in ids:
            raise ValueError("entry_node must reference an existing node")
        known = set(ids)
        for node in self.nodes:
            for transition in node.transitions:
                if transition.target not in known:
                    raise ValueError(
                        f"node '{node.id}' targets unknown node '{transition.target}'"
                    )
            if not isinstance(node, EndNode) and not node.transitions:
                raise ValueError(f"node '{node.id}' must define at least one transition")
        if not any(isinstance(node, EndNode) for node in self.nodes):
            raise ValueError("a graph must contain an end node")
        reachable = {self.entry_node}
        changed = True
        while changed:
            changed = False
            for node in self.nodes:
                if node.id in reachable:
                    for transition in node.transitions:
                        if transition.target not in reachable:
                            reachable.add(transition.target)
                            changed = True
        unreachable = known - reachable
        if unreachable:
            raise ValueError(f"unreachable nodes: {', '.join(sorted(unreachable))}")
        if self.kind is GraphKind.FOREGROUND:
            forbidden = [
                ref
                for node in self.nodes
                for ref in ([node.tool] if isinstance(node, ToolNode) else node.tools if isinstance(node, LlmNode) else [])
                if ref.startswith("subconscious:")
            ]
            if forbidden:
                raise ValueError("foreground graphs cannot reference subconscious-only tools")
        return self

    @classmethod
    def from_json_file(cls, path: str) -> "GraphSchema":
        return cls.model_validate_json(open(path, encoding="utf-8").read())


def state_value(state: dict[str, Any], path: str) -> Any:
    value: Any = state
    for part in path.split("."):
        if isinstance(value, dict) and part in value:
            value = value[part]
        else:
            return None
    return value


def render_state_template(template: str, state: dict[str, Any]) -> str:
    """Resolve the deliberately small and non-executable state template language."""

    def replace(match: re.Match[str]) -> str:
        value = state_value(state, match.group(1))
        if value is None:
            raise ValueError(f"state template value '{match.group(1)}' is missing")
        if isinstance(value, (dict, list)):
            import json
            return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        return str(value)

    return _TEMPLATE.sub(replace, template)


def predicate_matches(predicate: Predicate | None, state: dict[str, Any]) -> bool:
    if predicate is None:
        return True
    value = state_value(state, predicate.path)
    if predicate.operator == "exists":
        return value is not None
    if predicate.operator == "truthy":
        return bool(value)
    if predicate.operator == "not_equals":
        return value != predicate.value
    return value == predicate.value
