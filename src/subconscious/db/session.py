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

  def get_session(self) -> AsyncSession:
    """ Get a new async database session. """
    return self.async_session()

  async def close(self):
    """ Close the database engine. """
    await self.engine.dispose()
