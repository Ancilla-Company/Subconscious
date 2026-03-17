"""
Workspace memory tools — store, retrieve and forget persistent key/value facts.
Scoped to the current workspace so memories persist across all threads.
Backed by the WorkspaceMemory table.
"""

from typing import Optional
from sqlalchemy import select, delete
from pydantic_ai import RunContext
from . import EngineContext
from ..db.models import WorkspaceMemory


async def remember(
  ctx: RunContext[EngineContext],
  key: str,
  value: str,
) -> str:
  """
  Store a fact in workspace memory under a descriptive key.
  If a value already exists for this key it will be overwritten.
  Use short, descriptive keys like 'user_name', 'preferred_language', 'project_goal'.

  Args:
    key:   Short identifier for the fact, e.g. 'user_name'.
    value: The value to store, e.g. 'Alice'.
  """
  async with ctx.deps.db.get_session() as session:
    # Upsert: check existing first
    existing = await session.scalar(
      select(WorkspaceMemory).where(
        WorkspaceMemory.workspace_id == ctx.deps.workspace_id,
        WorkspaceMemory.key == key,
      )
    )
    if existing:
      existing.value = value  # type: ignore[assignment]
      existing.source_thread_id = ctx.deps.thread_id  # type: ignore[assignment]
    else:
      mem = WorkspaceMemory(
        workspace_id=ctx.deps.workspace_id,
        key=key,
        value=value,
        source_thread_id=ctx.deps.thread_id or None,
      )
      session.add(mem)
    await session.commit()
  return f"Remembered: {key} = {value}"


async def recall(ctx: RunContext[EngineContext], key: str) -> str:
  """
  Retrieve a previously stored fact by its key.
  Returns the stored value, or a message indicating it is not found.

  Args:
    key: The key to look up, e.g. 'user_name'.
  """
  async with ctx.deps.db.get_session() as session:
    mem = await session.scalar(
      select(WorkspaceMemory).where(
        WorkspaceMemory.workspace_id == ctx.deps.workspace_id,
        WorkspaceMemory.key == key,
      )
    )
  if not mem:
    return f"No memory found for key '{key}'."
  return str(mem.value)


async def list_memories(ctx: RunContext[EngineContext]) -> list[dict]:
  """
  Return all facts stored in the current workspace's memory.
  """
  async with ctx.deps.db.get_session() as session:
    rows = await session.scalars(
      select(WorkspaceMemory).where(WorkspaceMemory.workspace_id == ctx.deps.workspace_id)
    )
    mems = rows.all()

  if not mems:
    return [{"message": "No memories stored for this workspace yet."}]

  return [{"key": m.key, "value": m.value} for m in mems]


async def forget(ctx: RunContext[EngineContext], key: str) -> str:
  """
  Delete a stored memory entry by its key.

  Args:
    key: The key of the memory to remove.
  """
  async with ctx.deps.db.get_session() as session:
    result = await session.execute(
      delete(WorkspaceMemory).where(
        WorkspaceMemory.workspace_id == ctx.deps.workspace_id,
        WorkspaceMemory.key == key,
      )
    )
    await session.commit()

  if result.rowcount == 0:
    return f"No memory found for key '{key}'."
  return f"Forgotten: '{key}'"


async def forget_all(ctx: RunContext[EngineContext]) -> str:
  """
  Clear all memory for the current workspace.
  This is irreversible — use with caution.
  """
  async with ctx.deps.db.get_session() as session:
    result = await session.execute(
      delete(WorkspaceMemory).where(WorkspaceMemory.workspace_id == ctx.deps.workspace_id)
    )
    await session.commit()
  return f"Cleared {result.rowcount} memory entries for this workspace."


TOOLS = [remember, recall, list_memories, forget, forget_all]
