"""
Shared pytest fixtures for tool unit tests.

An in-memory SQLite database is created per test session and all ORM tables
are initialised in it.  Each test receives a fresh EngineContext whose DB
field points at that in-memory database.

The fake RunContext helper lets tool functions be called directly without
standing up a real pydantic-ai agent.
"""

import pytest
import pytest_asyncio
from dataclasses import dataclass
from typing import Any

from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker

from subconscious.db.models import Base
from subconscious.tools import EngineContext


# ---------------------------------------------------------------------------
# In-memory database (one engine shared across the whole test session)
# ---------------------------------------------------------------------------

@pytest_asyncio.fixture(scope="session")
async def async_engine():
  engine = create_async_engine("sqlite+aiosqlite:///:memory:", echo=False)
  async with engine.begin() as conn:
    await conn.run_sync(Base.metadata.create_all)
  yield engine
  await engine.dispose()


# ---------------------------------------------------------------------------
# Fake Database wrapper that matches the .get_session() interface
# ---------------------------------------------------------------------------

class FakeDatabase:
  """Minimal Database-like object using a real in-memory SQLite engine."""

  def __init__(self, session_factory):
    self._session_factory = session_factory

  def get_session(self) -> AsyncSession:
    return self._session_factory()


@pytest_asyncio.fixture
async def db(async_engine):
  """Return a FakeDatabase bound to the shared in-memory engine."""
  factory = async_sessionmaker(async_engine, class_=AsyncSession, expire_on_commit=False)
  return FakeDatabase(factory)


# ---------------------------------------------------------------------------
# EngineContext fixture
# ---------------------------------------------------------------------------

@pytest_asyncio.fixture
async def engine_ctx(db):
  """Return an EngineContext wired to the in-memory DB with workspace_id=1."""
  return EngineContext(db=db, workspace_id=1, thread_id=1, data_dir="")


# ---------------------------------------------------------------------------
# Fake RunContext — wraps EngineContext so tool functions can be called directly
# ---------------------------------------------------------------------------

@dataclass
class FakeRunContext:
  """Minimal stand-in for pydantic_ai.RunContext[EngineContext]."""
  deps: EngineContext


@pytest.fixture
def ctx(engine_ctx):
  """Return a FakeRunContext whose .deps is the in-memory EngineContext."""
  return FakeRunContext(deps=engine_ctx)
