""" Pydantic AI model construction, history conversion, and approval resumption """

import os
from contextvars import ContextVar
from typing import Any
from dataclasses import dataclass, replace
from collections.abc import Awaitable, Callable, Collection, Sequence

from pydantic_ai.models import Model
from pydantic_ai.models.openai import OpenAIModel
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.providers.bedrock import BedrockProvider
from pydantic_ai.models.bedrock import BedrockConverseModel
from pydantic_ai import (
    Agent, AgentRunResultEvent, DeferredToolRequests, DeferredToolResults,
    Tool, UsageLimits,
)
from pydantic_ai.messages import (
    FunctionToolCallEvent,
    FunctionToolResultEvent,
    PartDeltaEvent,
    TextPart,
    TextPartDelta,
    ModelMessage,
    ModelRequest,
    ModelResponse,
    RetryPromptPart,
    ToolReturnPart,
    UserPromptPart,
    SystemPromptPart
)

from subconscious_engine.configuration.models import ModelConfig
from subconscious_engine.tool_events import (
    COMPLETED, FAILED, IN_PROGRESS, PENDING, TERMINAL_STATUSES, tool_call_event,
)


# Variable setup
ApprovalCallback = Callable[[Any], Awaitable[bool]]
AgentEventCallback = Callable[[dict[str, Any]], Awaitable[None]]
SteeringSource = Callable[[], Awaitable[list[str]]]

# Set by the transport for the running turn. Returns user messages that arrived while
# the agent was working; they are injected before the next model request.
steering_source: ContextVar[SteeringSource | None] = ContextVar("steering_source", default=None)


def _steering_processor(source: SteeringSource):
    async def inject(messages: list[ModelMessage]) -> list[ModelMessage]:
        texts = await source()
        if not texts:
            return messages
        part = UserPromptPart(content=(
            "The user sent additional input while you were working. "
            "Take it into account and continue the task:\n\n" + "\n\n".join(texts)))
        out = list(messages)
        if out and isinstance(out[-1], ModelRequest):
            out[-1] = replace(out[-1], parts=[*out[-1].parts, part])
        else:
            out.append(ModelRequest(parts=[part]))
        return out
    return inject


@dataclass(frozen=True, slots=True)
class AgentExecutionResult:
    text: str
    tool_records: list[dict[str, Any]]
    prompt_tokens: int = 0
    completion_tokens: int = 0


class _ToolCallReporter:
    """Turns the model stream's tool activity into ``tool.call`` events.

    One reporter lives for a whole ``execute`` call because an approved tool is reported
    across two model runs: ``pending`` before the question, then ``in_progress`` and a
    terminal status after the agent resumes. A call reports each status at most once, and
    nothing after a terminal one.
    """

    def __init__(self, sink: AgentEventCallback | None, gated: Collection[str] = ()) -> None:
        self._sink = sink
        # Tools that need approval: the model stream announces their call before it is
        # deferred, which must not read as "running".
        self._gated = frozenset(gated)
        self._approved: set[str] = set()
        self._last: dict[str, str] = {}
        self._titles: dict[str, str] = {}

    async def _emit(self, call_id: str, name: str, status: str, **fields: Any) -> None:
        if self._sink is None or self._last.get(call_id) == status \
                or self._last.get(call_id) in TERMINAL_STATUSES:
            return
        self._last[call_id] = status
        event = tool_call_event(tool_call_id=call_id, tool_name=name, status=status,
                                title=self._titles.get(call_id), **fields)
        self._titles.setdefault(call_id, event["title"])
        await self._sink(event)

    async def awaiting_approval(self, call: Any) -> None:
        await self._emit(call.tool_call_id, call.tool_name, PENDING, arguments=call.args_as_dict())

    def approve(self, call: Any) -> None:
        self._approved.add(call.tool_call_id)

    async def denied(self, call: Any) -> None:
        await self._emit(call.tool_call_id, call.tool_name, FAILED, error="The tool call was denied.")

    async def stream_event(self, event: Any) -> None:
        if isinstance(event, FunctionToolCallEvent):
            part = event.part
            if part.tool_name in self._gated and part.tool_call_id not in self._approved:
                return
            await self._emit(part.tool_call_id, part.tool_name, IN_PROGRESS,
                             arguments=part.args_as_dict())
        elif isinstance(event, FunctionToolResultEvent):
            result = event.result
            call_id, name = result.tool_call_id, result.tool_name or "tool"
            if isinstance(result, RetryPromptPart):
                await self._emit(call_id, name, FAILED, error=str(result.content))
            elif getattr(result, "outcome", "success") == "success":
                await self._emit(call_id, name, COMPLETED, output=result.content)
            else:
                await self._emit(call_id, name, FAILED, output=result.content,
                                 error=f"The tool call {getattr(result, 'outcome', 'failed')}.")


class AgentManager:
    async def execute(self, config: ModelConfig, prompt: str | Sequence[Any],
                      history: Sequence[tuple[str, str]], tools: Sequence[Tool[Any]],
                      approve: ApprovalCallback,
                      system_prompt: str | Sequence[str] | None = None,
                      event_sink: AgentEventCallback | None = None) -> AgentExecutionResult:
        """Execute one LLM node; a node prompt overrides the legacy model prompt."""
        if config.id.casefold() == "echo" or config.provider.casefold() == "subconscious":
            text = prompt if isinstance(prompt, str) else "\n".join(
                item for item in prompt if isinstance(item, str)
            )
            if event_sink is not None and text:
                await event_sink({"type": "model.delta", "delta": text})
            return AgentExecutionResult(text, [])
        model = self._model(config)
        resolved_prompt = system_prompt if system_prompt is not None else config.system_prompt
        source = steering_source.get()
        agent = Agent(model, output_type=[str, DeferredToolRequests],
                      system_prompt=resolved_prompt or (), tools=tools,
                      history_processors=[_steering_processor(source)] if source else None)
        messages = self._history(history)
        deferred: DeferredToolResults | None = None
        user_prompt: str | Sequence[Any] | None = prompt
        records: list[dict[str, Any]] = []
        seen_returns: set[str] = set()
        prompt_tokens = 0
        completion_tokens = 0
        usage_limits = UsageLimits(request_limit=None, tool_calls_limit=None)
        reporter = _ToolCallReporter(
            event_sink, [tool.name for tool in tools if getattr(tool, "requires_approval", False)])
        while True:
            run_arguments = {
                "message_history": messages,
                "deferred_tool_results": deferred,
                "usage_limits": usage_limits,
            }
            if event_sink is None:
                result = await agent.run(user_prompt, **run_arguments)
            else:
                result = None
                async for event in agent.run_stream_events(user_prompt, **run_arguments):
                    if isinstance(event, PartDeltaEvent) and isinstance(event.delta, TextPartDelta):
                        await event_sink({
                            "type": "model.delta",
                            "delta": event.delta.content_delta,
                        })
                    elif isinstance(event, AgentRunResultEvent):
                        result = event.result
                    else:
                        await reporter.stream_event(event)
                if result is None:
                    raise RuntimeError("The model stream ended without a final result.")
            usage = result.usage()
            prompt_tokens += usage.input_tokens
            completion_tokens += usage.output_tokens
            self._collect_returns(result.new_messages(), records, seen_returns)
            if isinstance(result.output, str):
                text = result.output
                if not text.strip():
                    text = self._latest_response_text(result.new_messages())
                if not text.strip():
                    raise RuntimeError("The model completed without an assistant response.")
                return AgentExecutionResult(text, records, prompt_tokens, completion_tokens)
            requests = result.output
            deferred = DeferredToolResults()
            for call in requests.approvals:
                await reporter.awaiting_approval(call)
                approved = await approve(call)
                if approved:
                    reporter.approve(call)
                else:
                    await reporter.denied(call)
                deferred.approvals[call.tool_call_id] = approved
                records.append({"toolName": call.tool_name, "input": call.args_as_dict(),
                                "approval": "approved" if approved else "denied"})
            for call in requests.calls:
                deferred.calls[call.tool_call_id] = "External tool execution is unavailable."
            messages = result.all_messages()
            user_prompt = None

    @staticmethod
    def _model(config: ModelConfig) -> Model:
        provider_name = config.provider.casefold().replace("_", "-")
        if provider_name == "bedrock":
            return AgentManager._bedrock_model(config)

        supported = {"openai", "openai-compatible", "openrouter", "ollama", "lmstudio", "vllm", "local"}
        if provider_name not in supported:
            raise ValueError(f"Unsupported Pydantic AI provider: {config.provider}")
        if provider_name != "openai" and not config.base_url:
            raise ValueError(f"Provider '{config.provider}' requires an OpenAI-compatible base URL.")
        provider = OpenAIProvider(base_url=config.base_url, api_key=config.api_key or "not-required")
        return OpenAIModel(config.model, provider=provider)

    @staticmethod
    def _bedrock_model(config: ModelConfig) -> BedrockConverseModel:
        """Build a Bedrock model using credentials stored with the model configuration."""
        provider_kwargs = {
            key: value
            for key, value in {
                "api_key": (config.api_key or "").strip(),
                "aws_access_key_id": (config.aws_access_key_id or "").strip(),
                "aws_secret_access_key": (config.aws_secret_access_key or "").strip(),
                "aws_session_token": (config.aws_session_token or "").strip(),
                "region_name": AgentManager._bedrock_region(config),
            }.items()
            if value
        }
        provider = BedrockProvider(**provider_kwargs)
        return BedrockConverseModel(config.model, provider=provider)

    @staticmethod
    def _bedrock_region(config: ModelConfig) -> str | None:
        """Resolve a Bedrock region from configuration, ARN, then AWS environment variables."""
        region = (config.region or config.base_url or "").strip()
        if not region and config.model.startswith("arn:aws:bedrock:"):
            parts = config.model.split(":")
            if len(parts) > 3:
                region = parts[3]
        if not region:
            region = (os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "").strip()
        return region or None

    @staticmethod
    def _history(history: Sequence[tuple[str, str]]) -> list[ModelMessage]:
        messages: list[ModelMessage] = []
        for role, content in history:
            if role == "system":
                messages.append(ModelRequest(parts=[SystemPromptPart(content)]))
            elif role == "user":
                messages.append(ModelRequest(parts=[UserPromptPart(content)]))
            elif role == "assistant":
                messages.append(ModelResponse(parts=[TextPart(content)]))
        return messages

    @staticmethod
    def _latest_response_text(messages: Sequence[ModelMessage]) -> str:
        for message in reversed(messages):
            if not isinstance(message, ModelResponse):
                continue
            text = "".join(
                part.content for part in message.parts if isinstance(part, TextPart)
            )
            if text.strip():
                return text
        return ""

    @staticmethod
    def _collect_returns(messages: Sequence[ModelMessage], records: list[dict[str, Any]],
                         seen: set[str]) -> None:
        for message in messages:
            for part in message.parts:
                if isinstance(part, RetryPromptPart):
                    key = f"retry:{part.tool_call_id}:{part.timestamp.isoformat()}"
                    if key in seen:
                        continue
                    seen.add(key)
                    previous = [
                        int(item.get("retryCount", 0)) for item in records
                        if item.get("toolName") == (part.tool_name or "model")
                    ]
                    records.append({
                        "toolName": part.tool_name or "model",
                        "outcome": "retry",
                        "error": str(part.content),
                        "retryCount": max(previous, default=0) + 1,
                    })
                elif isinstance(part, ToolReturnPart) and part.tool_call_id not in seen:
                    seen.add(part.tool_call_id)
                    records.append({"toolName": part.tool_name, "output": part.content,
                                    "outcome": getattr(part, "outcome", "success")})
