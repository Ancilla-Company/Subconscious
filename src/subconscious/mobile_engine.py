"""
Mobile Engine - A stripped-down version of Engine for Android/iOS.

Excludes:
  - AgentManager / pydantic-ai (not available on Flet's mobile PyPI index)
  - desktop_notifier (desktop-only)
  - ToolRegistry (tools depend on desktop APIs)
  - File-processing imports (docx, pypdf, openpyxl) to reduce bundle size

Provides the core DB, workspace, thread and message operations that the
mobile UI needs.  AI features will be added once pydantic-core wheels are
available for Android on pypi.flet.dev.
"""

import asyncio
import logging
import pathlib
from datetime import datetime
from typing import Optional

from sqlalchemy import select
from sqlalchemy import update as sql_update

from .config import Config
from .constants import VERSION
from .db.session import Database
from .db.models import (
  Workspace, Thread, Message, AppState, Networks,
)

logger = logging.getLogger("subconscious")


class MobileEngine:
  """Subconscious Engine Core — mobile/Android/iOS variant."""

  update_available = None

  # ------------------------------------------------------------------
  # Startup / shutdown
  # ------------------------------------------------------------------

  async def init_settings(self):
    """Initialize default AppState settings if not already present."""
    try:
      system_settings = {
        "mode": ["auto", "light", "dark"],
        "language": ["en"],
        "position": ["x", "y"],
        "size": ["width", "height"],
        "maximized": [False, True],
      }
      async with self.db.get_session() as session:
        for key, value in system_settings.items():
          exists = await session.scalar(
            select(AppState).where(AppState.key == key)
          )
          if not exists:
            session.add(AppState(key=key, value=str(value[0]), tag="system"))
        await session.commit()
    except Exception as e:
      logger.error(f"Failed to initialize settings: {e}")

  async def init_system(self):
    """Initialize DB and default workspace."""
    await self.db.init_models()
    await self.init_settings()

    async with self.db.get_session() as session:
      self.current_network = await session.scalar(
        select(AppState).where(AppState.key == "current_network")
      )

      network = None
      if self.current_network:
        network = await session.scalar(
          select(Networks).where(Networks.uuid == self.current_network.value)
        )

      if not network:
        network = Networks(name="Local", uuid=str(__import__("uuid").uuid4()))
        session.add(network)
        await session.flush()

        workspace = Workspace(
          network_id=network.id,
          name="Default",
          uuid=str(__import__("uuid").uuid4()),
        )
        session.add(workspace)
        await session.flush()
        network.default_workspace_uuid = workspace.uuid

      workspace = await session.scalar(
        select(Workspace).where(
          Workspace.uuid == network.default_workspace_uuid,
          Workspace.network_id == network.id,
        )
      )
      if not workspace:
        workspace = Workspace(
          network_id=network.id,
          name="Default",
          uuid=str(__import__("uuid").uuid4()),
        )
        session.add(workspace)
        await session.flush()
        network.default_workspace_uuid = workspace.uuid

      if not self.current_network:
        session.add(AppState(key="current_network", value=network.uuid, tag="system"))
      elif self.current_network.value != network.uuid:
        self.current_network.value = network.uuid

      await session.commit()

  async def start_engine(self, config: Config):
    """Start the mobile engine (DB only — no agent, no tools)."""
    self.config = config
    self.config.load()
    self.db = Database(config)
    await self.init_system()
    self._heartbeat_task = asyncio.create_task(self.heartbeat())
    logger.info("MobileEngine started.")

  async def stop_engine(self):
    """Clean up resources."""
    if hasattr(self, "_heartbeat_task") and not self._heartbeat_task.done():
      self._heartbeat_task.cancel()
      try:
        await self._heartbeat_task
      except asyncio.CancelledError:
        pass
    if hasattr(self, "db"):
      await self.db.close()
    logger.debug("MobileEngine stopped.")

  async def heartbeat(self):
    try:
      while True:
        await asyncio.sleep(60)
        logger.debug("MobileEngine heartbeat.")
    except asyncio.CancelledError:
      pass

  # ------------------------------------------------------------------
  # Settings
  # ------------------------------------------------------------------

  async def update_setting(self, key: str, value: str, tag: str = "system"):
    """Persist a setting."""
    async with self.db.get_session() as session:
      existing = await session.scalar(
        select(AppState).where(AppState.key == key, AppState.tag == tag)
      )
      if existing:
        existing.value = value
      else:
        session.add(AppState(key=key, value=value, tag=tag))
      await session.commit()

  async def get_setting(self, key: str, tag: str = "system") -> Optional[str]:
    """Retrieve a setting."""
    async with self.db.get_session() as session:
      row = await session.scalar(
        select(AppState).where(AppState.key == key, AppState.tag == tag)
      )
      return row.value if row else None

  # ------------------------------------------------------------------
  # Threads & Messages
  # ------------------------------------------------------------------

  async def get_or_create_thread(
    self,
    content: str,
    workspace_id: int,
    thread_id: Optional[int] = None,
  ) -> Thread:
    async with self.db.get_session() as session:
      if thread_id:
        thread = await session.get(Thread, thread_id)
        if thread:
          return thread

      words = content.strip().split()
      title = " ".join(words[:6])
      if len(words) > 6:
        title += "…"
      if not title:
        title = "New Thread"

      thread = Thread(
        workspace_id=workspace_id,
        title=title,
        description=None,
      )
      session.add(thread)
      await session.commit()
      await session.refresh(thread)
      return thread

  async def save_message(self, thread_id: int, role: str, content: str) -> Message:
    """Persist a message and bump the thread's updated_at."""
    async with self.db.get_session() as session:
      msg = Message(thread_id=thread_id, role=role, content=content)
      session.add(msg)
      await session.execute(
        sql_update(Thread)
        .where(Thread.id == thread_id)
        .values(updated_at=datetime.now())
      )
      await session.commit()
      await session.refresh(msg)
      return msg

  async def load_thread_messages(self, thread_id: int) -> list[Message]:
    """Return all messages for a thread in chronological order."""
    async with self.db.get_session() as session:
      result = await session.scalars(
        select(Message)
        .where(Message.thread_id == thread_id)
        .order_by(Message.created_at)
      )
      return list(result.all())

  async def update_thread_title(self, thread_id: int, title: str) -> None:
    async with self.db.get_session() as session:
      await session.execute(
        sql_update(Thread).where(Thread.id == thread_id).values(title=title)
      )
      await session.commit()
