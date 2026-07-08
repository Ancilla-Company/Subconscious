import uuid
import logging
from sqlalchemy import text, NullPool
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker

from .models import Base
from ..config import Config


logger = logging.getLogger("subconscious")


class Database:
  """ Database session manager. """
  def __init__(self, config: Config):
    """ Initialize the database engine and session maker. """
    # NullPool disables connection pooling entirely. Each session opens and
    # closes its own connection, so dispose() returns immediately and there
    # is no background pool thread to hang on shutdown.
    self.engine = create_async_engine(
      config.db_path,
      echo=False,
      poolclass=NullPool,
    )
    self.async_session = async_sessionmaker(
      self.engine, class_=AsyncSession, expire_on_commit=False
    )

  async def init_models(self):
    """ Create tables if they don't exist and handle migrations. """
    async with self.engine.begin() as conn:
      await conn.run_sync(Base.metadata.create_all)
    
    # Column migrations – add columns that didn't exist in older DB versions
    async with self.engine.begin() as conn:
      # threads.updated_at
      result = await conn.execute(text("PRAGMA table_info(threads)"))
      columns = {row[1] for row in result.fetchall()}
      if "updated_at" not in columns:
        await conn.execute(text("ALTER TABLE threads ADD COLUMN updated_at DATETIME"))
      if "default_model_id" not in columns:
        await conn.execute(text("ALTER TABLE threads ADD COLUMN default_model_id VARCHAR"))
      if "tools_config" not in columns:
        await conn.execute(text("ALTER TABLE threads ADD COLUMN tools_config TEXT"))
      if "skills_config" not in columns:
        await conn.execute(text("ALTER TABLE threads ADD COLUMN skills_config TEXT"))
      if "uuid" not in columns:
        await conn.execute(text("ALTER TABLE threads ADD COLUMN uuid VARCHAR"))

      # messages.uuid – stable cross-peer identity for sync
      result = await conn.execute(text("PRAGMA table_info(messages)"))
      msg_columns = {row[1] for row in result.fetchall()}
      if "uuid" not in msg_columns:
        await conn.execute(text("ALTER TABLE messages ADD COLUMN uuid VARCHAR"))

      # workspaces.tools_config / skills_config
      result = await conn.execute(text("PRAGMA table_info(workspaces)"))
      ws_columns = {row[1] for row in result.fetchall()}
      if "tools_config" not in ws_columns:
        await conn.execute(text("ALTER TABLE workspaces ADD COLUMN tools_config TEXT"))
      if "skills_config" not in ws_columns:
        await conn.execute(text("ALTER TABLE workspaces ADD COLUMN skills_config TEXT"))
      if "directories" not in ws_columns:
        await conn.execute(text("ALTER TABLE workspaces ADD COLUMN directories TEXT"))

    # Backfill UUIDs for rows created before the uuid columns existed. SQLite
    # can't generate per-row UUIDs in pure SQL, so do it in Python.
    async with self.engine.begin() as conn:
      for table in ("threads", "messages", "workspaces"):
        rows = await conn.execute(
          text(f"SELECT id FROM {table} WHERE uuid IS NULL OR uuid = ''")
        )
        for (row_id,) in rows.fetchall():
          await conn.execute(
            text(f"UPDATE {table} SET uuid = :u WHERE id = :id"),
            {"u": str(uuid.uuid4()), "id": row_id},
          )

  def get_session(self) -> AsyncSession:
    """ Get a new async database session. """
    return self.async_session()

  async def close(self):
    """ Close the database engine. """
    await self.engine.dispose()
