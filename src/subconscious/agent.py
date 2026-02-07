import os
import logging
from pydantic_ai import Agent

from .config import Config, KeyManager


# Logging setup
logger = logging.getLogger("subconscious")
logger.info(__name__)


class AgentManager:
  """ Manages AI agents and their configurations. """
  def __init__(self, config: Config):
    self.config = config
    self._setup_env()

  def _setup_env(self):
    """Retrieves keys from keyring and sets environment variables."""
    if not self.config.model_provider:
      logger.debug("No model provider configured. Key loading skipped.")
      return

    provider = self.config.model_provider.lower()
    key = KeyManager.get_key(provider)
    
    if key:
      # Map common providers to their expected env vars
      if 'openai' in provider:
        os.environ['OPENAI_API_KEY'] = key
      elif 'anthropic' in provider:
        os.environ['ANTHROPIC_API_KEY'] = key
      elif 'gemini' in provider or 'google' in provider:
        os.environ['GOOGLE_API_KEY'] = key # Common for Gemini
      elif 'mistral' in provider:
        os.environ['MISTRAL_API_KEY'] = key
      elif 'groq' in provider:
        os.environ['GROQ_API_KEY'] = key
        
      logger.info(f"Loaded API key for {provider}")
    else:
      logger.warning(f"No API key found in keyring for provider: {provider}. Please set it using the CLI.")

  def get_agent(self, system_prompt: str = "") -> Agent:
    """Creates and returns a configured Agent instance."""
    # Construct model string if not fully specified
    # e.g. "openai:gpt-4o"
    model_name = self.config.model_name
    provider = self.config.model_provider
    
    if ':' not in model_name:
      # If the model name doesn't contain a colon, assume we need to prepend the provider
      # but pydantic-ai might handle just "gpt-4o" if OPENAI_API_KEY is set.
      # Safest to be explicit: "openai:gpt-4o"
      full_model_str = f"{provider}:{model_name}"
    else:
      full_model_str = model_name

    logger.debug(f"Initializing agent with model: {full_model_str}")
    
    return Agent(
      model=full_model_str,
      system_prompt=system_prompt or "You are a helpful assistant serving the Subconscious network."
    )
