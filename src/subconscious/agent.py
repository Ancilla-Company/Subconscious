import os
import logging
from typing import Optional, AsyncIterator
from pydantic_ai import Agent
from pydantic_ai.messages import ModelMessage, ModelRequest, UserPromptPart, ModelResponse, TextPart

from .config import Config


# Logging setup
logger = logging.getLogger("subconscious")


# Map provider display names (as stored in settings) to pydantic-ai prefixes and env-var names
_PROVIDER_MAP = {
  "openai":      ("openai",    "OPENAI_API_KEY"),
  "anthropic":   ("anthropic", "ANTHROPIC_API_KEY"),
  "google":      ("google-gla","GOOGLE_API_KEY"),
  "gemini":      ("google-gla","GOOGLE_API_KEY"),
  "groq":        ("groq",      "GROQ_API_KEY"),
  "mistralai":   ("mistral",   "MISTRAL_API_KEY"),
  "mistral":     ("mistral",   "MISTRAL_API_KEY"),
  "xai":         ("xai",       "XAI_API_KEY"),
  "deepseek":    ("deepseek",  "DEEPSEEK_API_KEY"),
  "ollama":      ("ollama",    None),            # no API key needed for local
  "hugging face":("huggingface","HUGGINGFACEHUB_API_TOKEN"),
}


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

  def build_agent(self, model_cfg: dict) -> Agent:
    """
    Construct a pydantic-ai Agent from a stored model config dict.
    Ensures the matching env-var is set first.
    """
    self.set_env_for_model(model_cfg)

    provider = (model_cfg.get("provider") or "").strip()
    raw_model = (model_cfg.get("model") or "").strip()
    system_prompt = (model_cfg.get("system_prompt") or "You are a helpful assistant.").strip()

    prefix = _provider_prefix(provider)

    # Build fully-qualified model string, e.g. "openai:gpt-4o"
    if ":" in raw_model:
      full_model_str = raw_model          # already qualified
    elif raw_model:
      full_model_str = f"{prefix}:{raw_model}"
    else:
      raise ValueError(f"Model name is empty in config for provider '{provider}'")

    logger.debug(f"Building agent with model: {full_model_str}")
    return Agent(model=full_model_str, system_prompt=system_prompt)

  def get_best_model_cfg(self) -> Optional[dict]:
    """Return the first usable model config from encrypted storage, or None."""
    self.config.read_keyring()
    secrets = self.config.secrets or {}
    models = secrets.get("models", {})
    for model_id, cfg in models.items():
      if cfg.get("model") and cfg.get("provider"):
        return {"id": model_id, **cfg}
    return None
