"""Pydantic AI model construction, history conversion, and approval resumption."""

from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
from typing import Any

from pydantic_ai import Agent, DeferredToolRequests, DeferredToolResults, Tool, UsageLimits
from pydantic_ai.messages import (ModelMessage, ModelRequest, ModelResponse, SystemPromptPart,
                                  TextPart, ToolReturnPart, UserPromptPart)
from pydantic_ai.models.openai import OpenAIModel
from pydantic_ai.providers.openai import OpenAIProvider

from subconscious_engine.configuration.models import ModelConfig

ApprovalCallback = Callable[[Any], Awaitable[bool]]


@dataclass(frozen=True, slots=True)
class AgentExecutionResult:
    text: str
    tool_records: list[dict[str, Any]]


class AgentManager:
    MAX_TOOL_ROUNDS = 8

    async def execute(self, config: ModelConfig, prompt: str,
                      history: Sequence[tuple[str, str]], tools: Sequence[Tool[Any]],
                      approve: ApprovalCallback) -> AgentExecutionResult:
        if config.id.casefold() == "echo" or config.provider.casefold() == "subconscious":
            return AgentExecutionResult(prompt, [])
        model = self._model(config)
        agent = Agent(model, output_type=[str, DeferredToolRequests],
                      system_prompt=config.system_prompt or (), tools=tools)
        messages = self._history(history)
        deferred: DeferredToolResults | None = None
        user_prompt: str | None = prompt
        records: list[dict[str, Any]] = []
        seen_returns: set[str] = set()
        for _ in range(self.MAX_TOOL_ROUNDS):
            result = await agent.run(user_prompt, message_history=messages,
                deferred_tool_results=deferred,
                usage_limits=UsageLimits(request_limit=8, tool_calls_limit=64))
            self._collect_returns(result.new_messages(), records, seen_returns)
            if isinstance(result.output, str):
                return AgentExecutionResult(result.output, records)
            requests = result.output
            deferred = DeferredToolResults()
            for call in requests.approvals:
                approved = await approve(call)
                deferred.approvals[call.tool_call_id] = approved
                records.append({"toolName": call.tool_name, "input": call.args_as_dict(),
                                "approval": "approved" if approved else "denied"})
            for call in requests.calls:
                deferred.calls[call.tool_call_id] = "External tool execution is unavailable."
            messages = result.all_messages()
            user_prompt = None
        raise RuntimeError("The model exceeded the maximum of eight tool-call rounds.")

    @staticmethod
    def _model(config: ModelConfig) -> OpenAIModel:
        provider_name = config.provider.casefold().replace("_", "-")
        supported = {"openai", "openai-compatible", "openrouter", "ollama", "lmstudio", "vllm", "local"}
        if provider_name not in supported:
            raise ValueError(f"Unsupported Pydantic AI provider: {config.provider}")
        if provider_name != "openai" and not config.base_url:
            raise ValueError(f"Provider '{config.provider}' requires an OpenAI-compatible base URL.")
        provider = OpenAIProvider(base_url=config.base_url, api_key=config.api_key or "not-required")
        return OpenAIModel(config.model, provider=provider)

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
    def _collect_returns(messages: Sequence[ModelMessage], records: list[dict[str, Any]],
                         seen: set[str]) -> None:
        for message in messages:
            for part in message.parts:
                if isinstance(part, ToolReturnPart) and part.tool_call_id not in seen:
                    seen.add(part.tool_call_id)
                    records.append({"toolName": part.tool_name, "output": part.content,
                                    "outcome": getattr(part, "outcome", "success")})
