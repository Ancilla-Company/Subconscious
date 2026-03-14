import uuid
import json
import logging
import pathlib
from sqlalchemy import select

from .config import Config
from .agent import AgentManager
from .db.session import Database
from .db.models import Workspace, AppState, Networks


# Logging setup
logger = logging.getLogger("subconscious")


class Engine:
  """ Subconscious Engine Core """
  async def init_settings(self):
    """ Initialize settings from settings.json to AppState if not present """
    settings_path = pathlib.Path(__file__).parent / "gui" / "settings.json"
    if not settings_path.exists():
      return

    try:
      with open(settings_path, "r") as f:
        settings_data = json.load(f)
      
      system_settings = settings_data.get("system", {})
      
      async with self.db.get_session() as session:
        for key, value in system_settings.items():
          # Check if already in DB
          exists = await session.scalar(
            select(AppState).where(AppState.key == key, AppState.tag == "system")
          )
          
          if not exists:
            # If it's a list (options), we might want to store the first one as default
            # based on the prompt "The list next to each key outlines the possible values it can have"
            default_value = value[0] if isinstance(value, list) else value
            # Convert to string for storage in Value Column
            new_setting = AppState(key=key, value=str(default_value), tag="system")
            session.add(new_setting)
            logger.debug(f"Initialized system setting: {key}={default_value}")
        
        await session.commit()
    except Exception as e:
      logger.error(f"Failed to initialize settings: {e}")

  async def init_system(self):
    """ Initialize system components (DB, Default Workspace) """
    await self.db.init_models()
    await self.init_settings()

    async with self.db.get_session() as session:
      # Find current network inside app_state
      self.current_network = await session.scalar(
        select(AppState).where(AppState.key == "current_network")
      )
      
      network = None
      if self.current_network:
        network = await session.scalar(
          select(Networks).where(Networks.uuid == self.current_network.value)
        )
      
      if not network:
        # Load the first network in the table
        network = await session.scalar(select(Networks))
        
        # If no networks exist, create one
        if not network:
          default_workspace_uuid = str(uuid.uuid4())
          network = Networks(
            name="General Network",
            uuid=str(uuid.uuid4()),
            description="Default network created on first run",
            default_workspace_uuid=default_workspace_uuid,
          )
          session.add(network)
          await session.flush() # ensure network has id if needed
          
          # Update app state
          if self.current_network:
            self.current_network.value = network.uuid
          else:
            self.current_network = AppState(key="current_network", value=network.uuid)
            session.add(self.current_network)

          logger.debug(f"Created new default network: {network.uuid}")

      # Check if default workspace exists
      workspace = await session.scalar(
        select(Workspace).where(
          Workspace.uuid == network.default_workspace_uuid,
          Workspace.network_id == network.id
        )
      )
      
      if not workspace:
        logger.debug("Creating default 'General' workspace.")
        workspace = Workspace(
          name="General",
          network_id=network.id,
          description="Default workspace for general conversations",
          uuid=network.default_workspace_uuid
        )
        session.add(workspace)

      # If we found an existing network but app_state wasn't set, update it
      if network and not self.current_network:
        self.current_network = AppState(key="current_network", value=network.uuid)
        session.add(self.current_network)
      elif network and self.current_network.value != network.uuid:
        self.current_network.value = network.uuid

      await session.commit()

  async def start_engine(self, config: Config):
    """ Engine startup logic """
    # Initialize Database
    self.config = config
    self.config.load()
    self.db = Database(config)
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

  async def stop_engine(self):
    """ Cleanup engine resources """
    if hasattr(self, 'db'):
      await self.db.close()
