"""Pydantic AI model construction, history conversion, and approval resumption."""

from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
import os
from typing import Any

from pydantic_ai import Agent, DeferredToolRequests, DeferredToolResults, Tool, UsageLimits
from pydantic_ai.messages import (ModelMessage, ModelRequest, ModelResponse, SystemPromptPart,
                                  TextPart, ToolReturnPart, UserPromptPart)
from pydantic_ai.models import Model
from pydantic_ai.models.bedrock import BedrockConverseModel
from pydantic_ai.models.openai import OpenAIModel
from pydantic_ai.providers.bedrock import BedrockProvider
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
                text = result.output
                if not text.strip():
                    text = self._latest_response_text(result.new_messages())
                if not text.strip():
                    raise RuntimeError("The model completed without an assistant response.")
                return AgentExecutionResult(text, records)
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
                if isinstance(part, ToolReturnPart) and part.tool_call_id not in seen:
                    seen.add(part.tool_call_id)
                    records.append({"toolName": part.tool_name, "output": part.content,
                                    "outcome": getattr(part, "outcome", "success")})
