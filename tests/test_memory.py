"""
Unit tests for subconscious.tools.memory
"""

import pytest
from subconscious.desktop_tools.memory import (
  remember,
  recall,
  list_memories,
  forget,
  forget_all,
)


# ---------------------------------------------------------------------------
# remember / recall
# ---------------------------------------------------------------------------

async def test_remember_stores_value(ctx):
  result = await remember(ctx, key="test_key", value="test_value")
  assert "test_key" in result
  assert "test_value" in result


async def test_recall_retrieves_value(ctx):
  await remember(ctx, key="name", value="Alice")
  result = await recall(ctx, key="name")
  assert "Alice" in result


async def test_recall_missing_key(ctx):
  result = await recall(ctx, key="no_such_key_xyz")
  assert "No memory" in result or "not found" in result.lower()


async def test_remember_overwrites_existing(ctx):
  await remember(ctx, key="color", value="red")
  await remember(ctx, key="color", value="blue")
  result = await recall(ctx, key="color")
  assert "blue" in result
  assert "red" not in result


async def test_workspace_isolation(ctx, engine_ctx):
  """Memories stored for workspace 1 must not appear for workspace 2."""
  from tests.conftest import FakeRunContext
  from subconscious.desktop_tools import EngineContext

  ctx2 = FakeRunContext(deps=EngineContext(
    db=engine_ctx.db, workspace_id=2, thread_id=1
  ))
  await remember(ctx, key="secret", value="workspace1_secret")
  result = await recall(ctx2, key="secret")
  assert "workspace1_secret" not in result


# ---------------------------------------------------------------------------
# list_memories
# ---------------------------------------------------------------------------

async def test_list_memories_returns_list(ctx):
  await remember(ctx, key="list_test_key", value="list_test_val")
  result = await list_memories(ctx)
  assert isinstance(result, list)
  keys = [m.get("key") for m in result]
  assert "list_test_key" in keys


async def test_list_memories_empty_workspace(ctx, engine_ctx):
  from tests.conftest import FakeRunContext
  from subconscious.desktop_tools import EngineContext

  ctx_empty = FakeRunContext(deps=EngineContext(
    db=engine_ctx.db, workspace_id=999, thread_id=1
  ))
  result = await list_memories(ctx_empty)
  # When empty the tool returns [{'message': '...'}] rather than []
  assert isinstance(result, list)
  if result and "key" not in result[0]:
    assert "message" in result[0]  # graceful empty-state message


# ---------------------------------------------------------------------------
# forget
# ---------------------------------------------------------------------------

async def test_forget_removes_key(ctx):
  await remember(ctx, key="forget_me", value="gone")
  await forget(ctx, key="forget_me")
  result = await recall(ctx, key="forget_me")
  assert "No memory" in result or "not found" in result.lower()


async def test_forget_nonexistent_key(ctx):
  # Should not raise — just return a graceful message
  result = await forget(ctx, key="nonexistent_key_abc")
  assert isinstance(result, str)


# ---------------------------------------------------------------------------
# forget_all
# ---------------------------------------------------------------------------

async def test_forget_all_clears_workspace(ctx, engine_ctx):
  from tests.conftest import FakeRunContext
  from subconscious.desktop_tools import EngineContext

  # Use workspace 50 to avoid polluting the shared workspace 1
  ctx_50 = FakeRunContext(deps=EngineContext(
    db=engine_ctx.db, workspace_id=50, thread_id=1
  ))
  await remember(ctx_50, key="a", value="1")
  await remember(ctx_50, key="b", value="2")
  forget_msg = await forget_all(ctx_50)
  assert "2" in forget_msg or "Cleared" in forget_msg
  # After clearing, list_memories returns an empty-state message list
  result = await list_memories(ctx_50)
  # No real memory entries should remain (only the optional message placeholder)
  real_entries = [m for m in result if "key" in m]
  assert real_entries == []
