import asyncio
import logging
from sqlalchemy import select

from .agent import AgentManager
from .db.session import Database
from .db.models import Workspace
from .config import Config, log_config


# Logging setup
logger = logging.getLogger("subconscious")


class Engine:
  """ Subconscious Engine Core """
  async def init_system(self):
    """ Initialize system components (DB, Default Workspace) """
    await self.db.init_models()

    async with self.db.get_session() as session:
      # Check if default workspace exists
      workspace = await session.scalar(
        select(Workspace).where(
          Workspace.uuid == self.config.default_workspace,
          Workspace.subconscious_id == self.config.subconscious_id
        )
      )
      
      if not workspace:
        logger.debug("Creating default 'General' workspace.")
        workspace = Workspace(
          name="General",
          subconscious_id=self.config.subconscious_id,
          uuid=self.config.default_workspace
        )
        session.add(workspace)
        await session.commit()
      else:
        logger.debug("Default workspace found.")

  async def start_engine(self, config: Config):
    """ Engine startup logic """
    # Initialize Database
    self.db = Database(config)
    self.config = config
    await self.init_system()

    # Initialize Agent Manager (load keys etc)
    self.agent_manager = AgentManager(config)

    # Pre-warm or just verify we can create an agent
    try:
      if config.model_provider and config.model_name:
        self.agent = self.agent_manager.get_agent()
        logger.debug(f"Agent system initialized with provider: {config.model_provider}")
      else:
        self.agent = None
        logger.debug("Agent system not initialized: model_provider or model_name missing.")
    except Exception as e:
      self.agent = None
      logger.error(f"Failed to initialize agent system: {e}")

  async def run_agent_stream(self, message: str):
    """ Runs the agent in streaming mode. """
    if not self.agent:
      raise ValueError("Agent not configured. Use 'set_model <provider> <model_name>' and ensures keys are set with 'add_key'.")
    async with self.agent.run_stream(message) as result:
      async for chunk in result.stream_output():
        yield chunk
