"""High-level dual-loop graph runner with foreground telemetry."""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
from time import perf_counter
import traceback
from pathlib import Path
from typing import Any
from uuid import uuid4

from pydantic_ai import Tool

from .agents import AgentManager, ApprovalCallback
from .configuration.models import ModelConfig
from .graphs import (
    CompiledGraph, GraphCompiler, GraphDependencies, GraphRuntimeState,
    GraphSchema, LlmNode, NodeResult, ToolNode,
)
from .telemetry import (
    AssertionResult, ExecutionTelemetry, FrictionSignal, NodeTrace, RunStatus,
    TelemetryStore, ToolInvocation,
)
from .tool_registry import PortableToolRegistry


EventSink = Callable[[dict[str, Any]], Awaitable[None]]
ModelProvider = Callable[[], Awaitable[ModelConfig | None]]
ToolNodeExecutor = Callable[[str, dict[str, Any]], Awaitable[Any]]


async def _no_event(_: dict[str, Any]) -> None:
    return None


@dataclass(frozen=True, slots=True)
class ForegroundResult:
    run_id: str
    text: str
    tool_records: list[dict[str, Any]]


class GraphEngine:
    def __init__(
        self,
        telemetry: TelemetryStore,
        registry: PortableToolRegistry,
        foreground_schema: GraphSchema,
        subconscious_schema: GraphSchema,
        agent_manager: AgentManager | None = None,
        subconscious_model_provider: ModelProvider | None = None,
        subconscious_tools: list[Tool[Any]] | None = None,
        context_directory: Path | None = None,
    ) -> None:
        self.telemetry = telemetry
        self.registry = registry
        self.agent_manager = agent_manager or AgentManager()
        compiler = GraphCompiler()
        self.foreground = compiler.compile(foreground_schema)
        self.subconscious = compiler.compile(subconscious_schema)
        self.subconscious_model_provider = subconscious_model_provider
        self.subconscious_tools = subconscious_tools or []
        self.context_directory = context_directory
        self.reflection_requested = asyncio.Event()
        self._idle = asyncio.Condition()
        self._active_foreground = 0
        self._reflection_lock = asyncio.Lock()

    async def _enter_foreground(self) -> None:
        async with self._idle:
            self._active_foreground += 1

    async def _leave_foreground(self) -> None:
        async with self._idle:
            self._active_foreground -= 1
            if self._active_foreground == 0:
                self._idle.notify_all()

    async def wait_until_idle(self) -> None:
        async with self._idle:
            await self._idle.wait_for(lambda: self._active_foreground == 0)

    async def run_conscious(
        self,
        model: ModelConfig,
        prompt: str | Sequence[Any],
        history: Sequence[tuple[str, str]],
        tools: list[Tool[Any]],
        approve: ApprovalCallback,
        *,
        state: dict[str, Any] | None = None,
        event_sink: EventSink = _no_event,
        tool_node_executor: ToolNodeExecutor | None = None,
        assertions: Sequence[AssertionResult] = (),
        friction_signals: Sequence[FrictionSignal] = (),
    ) -> ForegroundResult:
        run_id = str(uuid4())
        started = perf_counter()
        telemetry = ExecutionTelemetry(
            run_id=run_id,
            graph_id=self.foreground.schema.graph_id,
            final_status=RunStatus.SUCCESS,
            assertions=list(assertions),
            friction_signals=list(friction_signals),
        )
        records: list[dict[str, Any]] = []
        await self._enter_foreground()
        await event_sink({"type": "run.started", "run_id": run_id,
                          "graph_id": self.foreground.schema.graph_id})
        try:
            text = await self._execute_graph(
                self.foreground, model, prompt, history, tools, approve,
                state or {}, event_sink, telemetry, records, tool_node_executor,
            )
            telemetry.final_status = RunStatus.SUCCESS
            await event_sink({"type": "run.completed", "run_id": run_id})
            return ForegroundResult(run_id, text, records)
        except asyncio.CancelledError:
            telemetry.final_status = RunStatus.ABORTED
            telemetry.friction_signals.append(FrictionSignal(kind="interrupt"))
            await event_sink({"type": "run.aborted", "run_id": run_id})
            raise
        except Exception as error:
            telemetry.final_status = RunStatus.FAILED
            telemetry.error = "".join(traceback.format_exception(error))
            await event_sink({"type": "run.failed", "run_id": run_id, "error": str(error)})
            raise
        finally:
            telemetry.total_duration_ms = (perf_counter() - started) * 1000
            try:
                await self.telemetry.record(telemetry)
                if await self.telemetry.needs_reflection(run_id):
                    self.reflection_requested.set()
            finally:
                await self._leave_foreground()

    async def _execute_graph(
        self, compiled: CompiledGraph, model: ModelConfig,
        prompt: str | Sequence[Any], history: Sequence[tuple[str, str]],
        available_tools: list[Tool[Any]], approve: ApprovalCallback,
        values: dict[str, Any], event_sink: EventSink,
        telemetry: ExecutionTelemetry | None, records: list[dict[str, Any]],
        tool_node_executor: ToolNodeExecutor | None,
    ) -> str:
        runtime_state = GraphRuntimeState(values={
            "user_context": self._user_context(),
            "active_skills": [],
            **values,
        })

        async def execute_llm(node: LlmNode, system_prompt: str,
                              _: GraphRuntimeState) -> NodeResult:
            node_started = perf_counter()
            resolved_tools = self.registry.resolve_graph_tools(
                node.tools, available_tools,
                subconscious=self.subconscious_tools if compiled.schema.kind.value == "subconscious" else None,
            )
            fitted_history = self._fit_history(
                model, node, system_prompt, prompt, history
            )
            async def model_event(event: dict[str, Any]) -> None:
                if node.stream:
                    await event_sink({"node_id": node.id, **event})

            result = await self.agent_manager.execute(
                model, prompt, fitted_history, resolved_tools, approve,
                system_prompt=system_prompt,
                event_sink=model_event,
            )
            records.extend(result.tool_records)
            if telemetry is not None:
                denied = [item for item in result.tool_records
                          if str(item.get("approval", "")).casefold() == "denied"]
                telemetry.friction_signals.extend(
                    FrictionSignal(kind="rejected_tool", details=str(item.get("toolName", "unknown")))
                    for item in denied
                )
                telemetry.node_traces.append(NodeTrace(
                    node_id=node.id,
                    prompt_tokens=result.prompt_tokens,
                    completion_tokens=result.completion_tokens,
                    latency_ms=(perf_counter() - node_started) * 1000,
                    system_prompt_snapshot=system_prompt,
                ))
                telemetry.tool_invocations.extend(
                    self._tool_telemetry(item) for item in result.tool_records
                )
            updates = ({node.output_state: result.text.strip().casefold()}
                       if node.output_state else {})
            return NodeResult(output=result.text, state_updates=updates)

        async def execute_tool(node: ToolNode, state: GraphRuntimeState) -> NodeResult:
            if tool_node_executor is None:
                raise RuntimeError(f"No executor is configured for tool node '{node.id}'.")
            arguments = {
                key: self._resolve_argument(value, state.values)
                for key, value in node.arguments.items()
            }
            started = perf_counter()
            status = "ABORTED"
            error: str | None = None
            try:
                output = await tool_node_executor(node.tool, arguments)
                status = "SUCCESS"
            except Exception as exc:
                output = ""
                status = "FAILED"
                error = "".join(traceback.format_exception(exc))
                raise
            finally:
                if telemetry is not None:
                    telemetry.node_traces.append(NodeTrace(
                        node_id=node.id, latency_ms=(perf_counter() - started) * 1000,
                    ))
                    telemetry.tool_invocations.append(ToolInvocation(
                        tool_name=node.tool, arguments=arguments,
                        execution_status=status, error_stack_trace=error,
                    ))
            return NodeResult(output=str(output))

        dependencies = GraphDependencies(execute_llm, execute_tool, event_sink)
        return await compiled.run(runtime_state, dependencies)

    def _user_context(self) -> str:
        if self.context_directory is None:
            return ""
        path = self.context_directory / "USER.md"
        try:
            return path.read_text(encoding="utf-8") if path.is_file() else ""
        except OSError:
            return ""

    @staticmethod
    def _fit_history(
        model: ModelConfig, node: LlmNode, system_prompt: str,
        prompt: str | Sequence[Any], history: Sequence[tuple[str, str]],
    ) -> list[tuple[str, str]]:
        """Apply the node policy against the actual selected model context size."""
        context_window = model.context_window or node.context.context_window
        reserved = min(
            node.context.reserved_output_tokens,
            max(256, context_window // 4),
        )
        input_budget = max(1, context_window - reserved)
        # A conservative local estimate avoids an extra tokenizer/model call.
        prompt_chars = len(prompt) if isinstance(prompt, str) else sum(
            len(item) if isinstance(item, str) else len(getattr(item, "data", b""))
            for item in prompt
        )
        fixed_tokens = (len(system_prompt) + prompt_chars + 3) // 4
        if fixed_tokens > input_budget:
            raise ValueError("The system prompt and request exceed the model context window.")
        fitted = list(history)
        history_tokens = sum((len(role) + len(content) + 3) // 4 for role, content in fitted)
        if fixed_tokens + history_tokens <= input_budget:
            return fitted
        if node.context.overflow_strategy == "reject":
            raise ValueError("Conversation history exceeds the model context window.")
        while fitted and fixed_tokens + history_tokens > input_budget:
            role, content = fitted.pop(0)
            history_tokens -= (len(role) + len(content) + 3) // 4
        return fitted

    @staticmethod
    def _resolve_argument(value: Any, state: dict[str, Any]) -> Any:
        if isinstance(value, str) and value.startswith("$state."):
            current: Any = state
            for part in value[7:].split("."):
                if not isinstance(current, dict) or part not in current:
                    raise ValueError(f"Missing graph state argument '{value}'.")
                current = current[part]
            return current
        return value

    @staticmethod
    def _tool_telemetry(record: dict[str, Any]) -> ToolInvocation:
        approval = str(record.get("approval", "")).casefold()
        outcome = str(record.get("outcome", "success")).casefold()
        status = "DENIED" if approval == "denied" else "FAILED" if outcome not in {"success", ""} else "SUCCESS"
        return ToolInvocation(
            tool_name=str(record.get("toolName", "unknown")),
            arguments=record.get("input") if isinstance(record.get("input"), dict) else {},
            execution_status=status,
            error_stack_trace=str(record.get("error")) if record.get("error") else None,
            retry_count=int(record.get("retryCount", 0)),
        )

    async def run_subconscious(self, model: ModelConfig | None = None) -> bool:
        """Run only for locally-filtered candidates and only while foreground is idle."""
        candidates = await self.telemetry.claim_reflection_candidates()
        if not candidates:
            return False
        succeeded = False
        try:
            if model is None and self.subconscious_model_provider is not None:
                model = await self.subconscious_model_provider()
            if model is None:
                return False
            await self.wait_until_idle()
            async with self._reflection_lock:
                await self._execute_graph(
                    self.subconscious, model,
                    "Inspect the candidate runs and make only justified durable improvements.",
                    [], [], self._approve_background,
                    {"candidate_run_ids": candidates}, _no_event, None, [], None,
                )
            succeeded = True
            return True
        finally:
            await self.telemetry.complete_reflection(candidates, succeeded)
            self.reflection_requested.clear()

    @staticmethod
    async def _approve_background(_: Any) -> bool:
        return True
