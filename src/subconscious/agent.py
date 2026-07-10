import os
import asyncio
import logging
from pydantic_ai import Agent
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.ollama import OllamaProvider
from pydantic_ai.providers.bedrock import BedrockProvider
from typing import Optional, Callable, TYPE_CHECKING, Any, cast
from pydantic_ai.models.bedrock import BedrockConverseModel, BedrockModelSettings
from pydantic_ai.messages import ModelMessage, ModelRequest, UserPromptPart, ModelResponse, TextPart

from .config import Config
from .tools import EngineContext


# Logging setup
logger = logging.getLogger("subconscious")


# Map provider display names (as stored in settings) to pydantic-ai prefixes and env-var names
_PROVIDER_MAP = {
  # Native pydantic-ai providers
  "openai":                           ("openai",      "OPENAI_API_KEY"),
  "anthropic":                        ("anthropic",   "ANTHROPIC_API_KEY"),
  "gemini":                           ("google-gla",  "GOOGLE_API_KEY"),
  "groq":                             ("groq",        "GROQ_API_KEY"),
  "mistral":                          ("mistral",     "MISTRAL_API_KEY"),
  "xai":                              ("xai",         "XAI_API_KEY"),
  # Bedrock credentials are passed directly to BedrockProvider in build_agent,
  # so no env-var is set here (the stored api_key is a Bedrock bearer token,
  # not an AWS_ACCESS_KEY_ID).
  "bedrock":                          ("bedrock",     None),
  "cerebras":                         ("cerebras",    "CEREBRAS_API_KEY"),
  "cohere":                           ("cohere",      "CO_API_KEY"),
  "hugging face":                     ("huggingface", "HUGGINGFACEHUB_API_TOKEN"),
  "openrouter":                       ("openrouter",  "OPENROUTER_API_KEY"),
  # OpenAI-compatible providers (use openai prefix with custom base_url)
  "alibaba cloud model studio":       ("openai",      "DASHSCOPE_API_KEY"),
  "azure ai foundry":                 ("openai",      "AZURE_OPENAI_API_KEY"),
  "deepseek":                         ("deepseek",    "DEEPSEEK_API_KEY"),
  "fireworks ai":                     ("openai",      "FIREWORKS_API_KEY"),
  "github models":                    ("openai",      "GITHUB_TOKEN"),
  "litellm":                          ("openai",      "LITELLM_API_KEY"),
  "nebius ai studio":                 ("openai",      "NEBIUS_API_KEY"),
  "ollama":                           ("ollama",      None),              # no API key needed for local
  "lm studio":                        ("openai",      None),              # no API key needed for local
  "custom":                           ("openai",      None),              # no API key needed for local
  "perplexity":                       ("openai",      "PERPLEXITY_API_KEY"),
  "sambanova":                        ("openai",      "SAMBANOVA_API_KEY"),
  "together ai":                      ("openai",      "TOGETHER_API_KEY"),
}


def custom_endpoints(provider: str) -> str:
  """ Returns to assumed local endpoint for the passed in provider.
      Ofcourse, users can edit it for different or remote endpoints
  """
  endpoints = {
    "ollama": "http://localhost:11434/v1",
    "lm studio": "http://127.0.0.1:1234/v1"
  }
  return endpoints.get(provider, "")


def _provider_prefix(provider: str) -> str:
  """Return the pydantic-ai model-string prefix for a provider name."""
  return _PROVIDER_MAP.get(provider.lower(), (provider.lower(), None))[0]


def _provider_env_var(provider: str) -> Optional[str]:
  """Return the environment-variable name that holds the API key for this provider."""
  return _PROVIDER_MAP.get(provider.lower(), (None, None))[1]


class AgentManager:
  """Manages AI agents built from the encrypted model configs."""

  def __init__(self, config: Config):
    self.config = config

  # ------------------------------------------------------------------
  # Public helpers
  # ------------------------------------------------------------------

  def set_env_for_model(self, model_cfg: dict) -> None:
    """
    Given one model-config dict (as stored in secrets["models"]),
    set the appropriate environment variable so pydantic-ai can authenticate.
    model_cfg keys: provider, model, api_key, (optional) system_prompt
    """
    provider = (model_cfg.get("provider") or "").strip()
    api_key  = (model_cfg.get("api_key")  or "").strip()
    env_var  = _provider_env_var(provider)

    if env_var and api_key:
      os.environ[env_var] = api_key
      logger.debug(f"Set {env_var} for provider '{provider}'")
    elif not api_key:
      logger.warning(f"No api_key stored for provider '{provider}' (model id={model_cfg.get('id')})")

  def build_agent(
    self,
    model_cfg: dict,
    tools: Optional[list[Callable]] = None,
    ambient_context: Optional[str] = None,
  ) -> Agent:
    """
    Construct a pydantic-ai Agent from a stored model config dict.
    Ensures the matching env-var is set first.

    Args:
      model_cfg:       Provider/model/key dict as stored in secrets["models"].
      tools:           Optional list of pydantic-ai tool callables to attach.
                       When provided, EngineContext is used as the deps type so
                       tools receive the DB session and workspace context.
      ambient_context: Optional ambient context block (e.g. system information)
                       to append to the model-configured system prompt. When
                       non-empty it is appended after the model prompt; when
                       None or empty the prompt is left unchanged. A valid Agent
                       is always returned regardless of this value.
    """
    self.set_env_for_model(model_cfg)

    provider = (model_cfg.get("provider") or "").strip()
    raw_model = (model_cfg.get("model") or "").strip()
    system_prompt = (model_cfg.get("system_prompt") or "You are a helpful assistant.").strip()
    if ambient_context:
      system_prompt = f"{system_prompt}\n\n{ambient_context}"
    base_url = (model_cfg.get("base_url") or "").strip()

    prefix = _provider_prefix(provider)

    # Build fully-qualified model string, e.g. "openai:gpt-4o"
    if ":" in raw_model:
      full_model_str = raw_model          # already qualified
    elif raw_model:
      full_model_str = f"{prefix}:{raw_model}"
    else:
      raise ValueError(f"Model name is empty in config for provider '{provider}'")

    logger.debug(f"Building agent with model: {full_model_str}, tools: {len(tools or [])} attached")

    # For Ollama, use OpenAIChatModel with OllamaProvider to allow a custom base_url
    model_instance: Any = full_model_str
    if provider.lower() in ["ollama", "lm studio", "custom"]:
      custom_base_url = (base_url or custom_endpoints(provider.lower())).rstrip("/")
      if not custom_base_url.endswith("/v1"):
        custom_base_url += "/v1"
      model_instance = OpenAIChatModel(raw_model, provider=OllamaProvider(base_url=custom_base_url))
      logger.debug(f"Custom base_url: {custom_base_url}")
    elif provider.lower() == "bedrock":
      # Use BedrockConverseModel with an explicit BedrockProvider so the stored
      # credentials/region are passed directly rather than relying solely on the
      # ambient AWS credential chain.
      model_instance = self._build_bedrock_model(raw_model, model_cfg)
    elif provider.lower() == "subconscious" and raw_model == "echo":
      return EchoProvider()

    if tools:
      agent_kwargs: Any = dict(
        model=model_instance,
        system_prompt=system_prompt,
        tools=tools,
        deps_type=EngineContext,
      )
      return cast(Agent, Agent(**agent_kwargs))

    return Agent(model=model_instance, system_prompt=system_prompt)  # type: ignore[return-value]

  @staticmethod
  def _bedrock_region(model_name: str, model_cfg: dict) -> Optional[str]:
    """Resolve the AWS region for a Bedrock model.

    Preference order:
      1. Explicit ``region`` field in the model config.
      2. ``base_url`` field (some users store the region there).
      3. Region embedded in a foundation-model / inference-profile ARN.
      4. Ambient ``AWS_REGION`` / ``AWS_DEFAULT_REGION`` env vars.
    """
    region = (model_cfg.get("region") or model_cfg.get("base_url") or "").strip()
    if not region and model_name.startswith("arn:aws:bedrock:"):
      # arn:aws:bedrock:<region>:<account>:...
      parts = model_name.split(":")
      if len(parts) > 3 and parts[3]:
        region = parts[3]
    if not region:
      region = (os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "").strip()
    return region or None

  def _build_bedrock_model(self, model_name: str, model_cfg: dict) -> BedrockConverseModel:
    """Construct a BedrockConverseModel backed by an explicit BedrockProvider.

    The stored ``api_key`` is passed straight through as a Bedrock API key
    (bearer token). If AWS access-key style credentials are present in the
    config they are forwarded too; otherwise BedrockProvider falls back to the
    standard AWS credential chain (env vars, shared config, IAM role, etc.).
    """
    api_key           = (model_cfg.get("api_key") or "").strip()
    aws_access_key    = (model_cfg.get("aws_access_key_id") or "").strip()
    aws_secret_key    = (model_cfg.get("aws_secret_access_key") or "").strip()
    aws_session_token = (model_cfg.get("aws_session_token") or "").strip()
    region            = self._bedrock_region(model_name, model_cfg)

    provider_kwargs: dict[str, Any] = {}
    if api_key:
      provider_kwargs["api_key"] = api_key
    if aws_access_key:
      provider_kwargs["aws_access_key_id"] = aws_access_key
    if aws_secret_key:
      provider_kwargs["aws_secret_access_key"] = aws_secret_key
    if aws_session_token:
      provider_kwargs["aws_session_token"] = aws_session_token
    if region:
      provider_kwargs["region_name"] = region

    logger.debug(
      f"Building Bedrock model '{model_name}' (region={region or 'default'}, "
      f"api_key={'set' if api_key else 'unset'})"
    )
    return BedrockConverseModel(model_name, provider=BedrockProvider(**provider_kwargs))

  def get_best_model_cfg(self) -> Optional[dict]:
    """Return the first usable model config from encrypted storage, or None."""
    self.config.read_keyring()
    secrets = self.config.secrets or {}
    models = secrets.get("models", {})
    for model_id, cfg in models.items():
      if cfg.get("model") and cfg.get("provider"):
        return {"id": model_id, **cfg}
    return None

  def list_model_cfgs(self) -> list[dict]:
    """ Return every stored model config as a dict (``id`` + stored fields).

        Includes the api_key — callers that expose these over the wire must
        strip it (see the /models API endpoint).
    """
    self.config.read_keyring()
    secrets = self.config.secrets or {}
    models = secrets.get("models", {})
    return [{"id": model_id, **cfg} for model_id, cfg in models.items()]

  def get_model_cfg(self, model_id: str) -> Optional[dict]:
    """Return the stored config for *model_id* (``id`` + fields), or None if unknown."""
    self.config.read_keyring()
    secrets = self.config.secrets or {}
    cfg = (secrets.get("models") or {}).get(model_id)
    return {"id": model_id, **cfg} if cfg else None


class EchoProvider(Agent):
  """ Simple echo agent for dev testing with Pydantic AI
      Inherits the Agent class to silence typing errors
  """
  text: str = ""

  async def __aenter__(self, *args, **kwargs):
    return self
  
  async def __aexit__(self, *args, **kwargs):
    return
  
  def run_stream(self, prompt, *args, **kwargs):
    self.text = prompt
    return self

  async def stream_text(self, *args, **kwargs):
    """ Fake agent generator """
    for chunk in self.text:
      yield chunk
      await asyncio.sleep(0.02)
