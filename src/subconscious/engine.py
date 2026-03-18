import uuid
import json
import asyncio
import logging
import pathlib
from datetime import datetime
from sqlalchemy import select
from typing import AsyncIterator, Optional
from desktop_notifier import DesktopNotifier, Icon
from pydantic_ai.messages import (
  ModelMessage, ModelRequest, ModelResponse,
  UserPromptPart, TextPart,
)

from .config import Config
from .agent import AgentManager
from .db.session import Database
from .tools import ToolRegistry, EngineContext
from .db.models import Workspace, Thread, Message, AppState, Networks

_icon_path = pathlib.Path(__file__).parent / "assets" / "icon.png"
notifier = DesktopNotifier(
  app_name="Subconscious",
  app_icon=Icon(path=_icon_path),
)


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

    # start the heartbeat
    self._heartbeat_task = asyncio.create_task(self.heartbeat())

    # Initialize Agent Manager
    self.agent_manager = AgentManager(config)

    # Initialize Tool Registry
    self.tool_registry = ToolRegistry()

    # Show ready notification
    await self.show_notification("Subconscious", "Startup Complete.")


  async def get_or_create_thread(
    self,
    content: str,
    workspace_id: int,
    thread_id: Optional[int] = None,
  ) -> Thread:
    """
    If thread_id is given and the thread exists, return it.
    Otherwise create a new Thread in the given workspace with a
    placeholder title derived from the first message.
    """
    async with self.db.get_session() as session:
      if thread_id:
        thread = await session.get(Thread, thread_id)
        if thread:
          return thread

      # Auto-generate a short title from the first few words
      words = content.strip().split()
      title = " ".join(words[:6])
      if len(words) > 6:
        title += "…"
      if not title:
        title = "New Thread"

      thread = Thread(
        workspace_id=workspace_id,
        title=title,  # type: ignore[arg-type]
        description=None,
      )
      session.add(thread)
      await session.commit()
      await session.refresh(thread)
      return thread

  async def save_message(self, thread_id: int, role: str, content: str) -> Message:
    """Persist a single message and return the ORM object. Also bumps the thread's updated_at."""
    from sqlalchemy import update as sql_update
    async with self.db.get_session() as session:
      msg = Message(thread_id=thread_id, role=role, content=content)
      session.add(msg)
      # Bump the parent thread's updated_at so the list stays sorted by recent activity
      await session.execute(
        sql_update(Thread)
        .where(Thread.id == thread_id)
        .values(updated_at=datetime.now())
      )
      await session.commit()
      await session.refresh(msg)
      return msg

  async def load_thread_messages(self, thread_id: int) -> list[Message]:
    """Return all messages for a thread ordered chronologically."""
    async with self.db.get_session() as session:
      result = await session.scalars(
        select(Message)
        .where(Message.thread_id == thread_id)
        .order_by(Message.created_at)
      )
      return list(result.all())

  def _build_history(self, db_messages: list[Message]) -> list[ModelMessage]:
    """
    Convert stored Message rows into the pydantic-ai message history format
    so the LLM has full conversation context.
    """
    history: list[ModelMessage] = []
    for msg in db_messages:
      content_str = str(msg.content)
      if msg.role == "user":
        history.append(ModelRequest(parts=[UserPromptPart(content=content_str)]))
      elif msg.role in ("assistant", "agent"):
        history.append(ModelResponse(parts=[TextPart(content=content_str)]))
    return history

  async def stream_chat(
    self,
    content: str,
    thread_id: int,
    workspace_id: Optional[int] = None,
    model_cfg: Optional[dict] = None,
    enabled_tools: Optional[list[str]] = None,
  ) -> AsyncIterator[str]:
    """
    Stream an AI response for *content* given the existing thread history.
    Yields text chunks as they arrive from the LLM.

    Args:
      content:       The user message text.
      thread_id:     ID of the active thread (used to load history).
      workspace_id:  ID of the active workspace (used as tool scope).
      model_cfg:     Override model config dict; uses best available if None.
      enabled_tools: List of tool slugs to attach, e.g. ['time', 'calculator'].
                     Defaults to all registered tools when None.
    """
    # Load history (excluding the message we're about to send – it was just saved)
    db_messages = await self.load_thread_messages(thread_id)
    # Drop the last message (the user message we just persisted) so it's only
    # included as the explicit new prompt, not duplicated in history.
    history = self._build_history(db_messages[:-1])

    # Resolve model config
    if model_cfg is None:
      model_cfg = self.agent_manager.get_best_model_cfg()
    if model_cfg is None:
      raise ValueError("No model configured. Add a model in Settings → Models.")

    # Resolve tools
    slugs = enabled_tools if enabled_tools is not None else self.tool_registry.all_slugs()
    tools = self.tool_registry.get_tools(slugs)

    agent = self.agent_manager.build_agent(model_cfg, tools=tools)  # type: ignore[call-arg]

    # Build the dependency context for tools that need DB / workspace access
    ctx_deps = EngineContext(
      db=self.db,
      workspace_id=workspace_id or 0,
      thread_id=thread_id,
      data_dir=str(self.config.data_dir),
    )

    async with agent.run_stream(content, message_history=history, deps=ctx_deps) as result:  # type: ignore[call-overload]
      async for chunk in result.stream_text(delta=True):
        yield chunk

  async def update_thread_title(self, thread_id: int, title: str) -> None:
    """Update the thread title (called after the first exchange if desired)."""
    async with self.db.get_session() as session:
      thread = await session.get(Thread, thread_id)
      if thread:
        thread.title = title  # type: ignore[assignment]
        await session.commit()

  async def run_agent_stream(self, message: str):
    """ Legacy: Runs the agent in streaming mode (kept for TUI / API compatibility). """
    if not hasattr(self, 'agent') or not self.agent:
      raise ValueError("Agent not configured. Use 'set_model <provider> <model_name>' and ensures keys are set with 'add_key'.")
    async with self.agent.run_stream(message) as result:
      async for chunk in result.stream_output():
        yield chunk

  async def stop_engine(self):
    """ Cleanup engine resources """
    if hasattr(self, '_heartbeat_task') and not self._heartbeat_task.done():
      self._heartbeat_task.cancel()
      try:
        await self._heartbeat_task
      except asyncio.CancelledError:
        pass
    if hasattr(self, 'db'):
      try:
        await asyncio.wait_for(self.db.close(), timeout=1.0)
      except asyncio.TimeoutError:
        logger.warning("Engine stop_engine: db.close() timed out.")
    logger.debug("Engine stopped.")

  async def heartbeat(self):
    """ A simple heartbeat task to indicate the engine is still running normally """
    try:
      while True:
        logger.debug("heartbeat")
        await asyncio.sleep(5)
    except asyncio.CancelledError:
      pass
  
  async def show_notification(self, title, message):
    try:
      await notifier.send(
        title=title,
        message=message
      )
    except Exception as e:
      print(f"Notification error: {e}")
