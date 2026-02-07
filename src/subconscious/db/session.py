from sqlalchemy.orm import sessionmaker
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession

from .models import Base
from ..config import Config


class Database:
  """ Database session manager. """
  def __init__(self, config: Config):
    """ Initialize the database engine and session maker. """
    self.engine = create_async_engine(config.db_path, echo=False)
    self.async_session = sessionmaker(
      self.engine, class_=AsyncSession, expire_on_commit=False
    )

  async def init_models(self):
    """Create tables if they don't exist."""
    async with self.engine.begin() as conn:
      await conn.run_sync(Base.metadata.create_all)

  def get_session(self) -> AsyncSession:
    """ Get a new async database session. """
    return self.async_session()
