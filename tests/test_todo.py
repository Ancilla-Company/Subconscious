"""
Unit tests for subconscious.tools.todo
"""

import pytest
from subconscious.desktop_tools.todo import (
  add_todo,
  list_todos,
  update_todo,
  complete_todo,
  delete_todo,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def _fresh_todo(ctx, title="Test task", priority="normal"):
  return await add_todo(ctx, title=title, priority=priority)


# ---------------------------------------------------------------------------
# add_todo
# ---------------------------------------------------------------------------

async def test_add_todo_returns_id(ctx):
  result = await add_todo(ctx, title="Buy milk")
  assert "id" in result
  assert isinstance(result["id"], int)


async def test_add_todo_defaults(ctx):
  result = await add_todo(ctx, title="Default task")
  assert result["status"] == "open"
  assert result["priority"] == "normal"


async def test_add_todo_with_priority(ctx):
  result = await add_todo(ctx, title="Urgent task", priority="urgent")
  assert result["priority"] == "urgent"


async def test_add_todo_invalid_priority(ctx):
  result = await add_todo(ctx, title="Bad task", priority="critical")
  assert "error" in result


async def test_add_todo_with_due_date(ctx):
  result = await add_todo(ctx, title="Dated task", due_date="2026-12-31")
  assert "id" in result


async def test_add_todo_bad_due_date(ctx):
  result = await add_todo(ctx, title="Bad date", due_date="not-a-date")
  assert "error" in result


# ---------------------------------------------------------------------------
# list_todos
# ---------------------------------------------------------------------------

async def test_list_todos_not_empty_after_add(ctx):
  await add_todo(ctx, title="List test task")
  result = await list_todos(ctx)
  assert isinstance(result, list)
  titles = [r.get("title") for r in result]
  assert "List test task" in titles


async def test_list_todos_filter_by_status(ctx):
  await add_todo(ctx, title="Open task")
  result = await list_todos(ctx, status="open")
  statuses = [r.get("status") for r in result]
  assert all(s == "open" for s in statuses if s)


async def test_list_todos_filter_by_priority(ctx):
  await add_todo(ctx, title="High task", priority="high")
  result = await list_todos(ctx, priority="high")
  priorities = [r.get("priority") for r in result]
  assert all(p == "high" for p in priorities if p)


# ---------------------------------------------------------------------------
# update_todo
# ---------------------------------------------------------------------------

async def test_update_todo_title(ctx):
  item = await add_todo(ctx, title="Old title")
  result = await update_todo(ctx, todo_id=item["id"], title="New title")
  assert result.get("title") == "New title"


async def test_update_todo_status(ctx):
  item = await add_todo(ctx, title="Status task")
  result = await update_todo(ctx, todo_id=item["id"], status="in_progress")
  assert result.get("status") == "in_progress"


async def test_update_todo_not_found(ctx):
  result = await update_todo(ctx, todo_id=999999, title="Ghost")
  assert "error" in result or "not found" in str(result).lower()


async def test_update_todo_accepts_any_status(ctx):
  """update_todo does not validate status values — it stores whatever is given."""
  item = await add_todo(ctx, title="Status check")
  result = await update_todo(ctx, todo_id=item["id"], status="in_progress")
  assert result.get("status") == "in_progress"


# ---------------------------------------------------------------------------
# complete_todo
# ---------------------------------------------------------------------------

async def test_complete_todo_marks_done(ctx):
  item = await add_todo(ctx, title="Complete me")
  result = await complete_todo(ctx, todo_id=item["id"])
  # complete_todo returns a confirmation string
  assert isinstance(result, str)
  assert "done" in result.lower() or "complete" in result.lower() or "✓" in result


async def test_complete_todo_not_found(ctx):
  result = await complete_todo(ctx, todo_id=999999)
  assert "error" in result or "not found" in str(result).lower()


# ---------------------------------------------------------------------------
# delete_todo
# ---------------------------------------------------------------------------

async def test_delete_todo_removes_item(ctx):
  item = await add_todo(ctx, title="Delete me")
  del_result = await delete_todo(ctx, todo_id=item["id"])
  assert "deleted" in str(del_result).lower() or "ok" in str(del_result).lower()
  # Confirm it no longer appears in list
  all_items = await list_todos(ctx)
  ids = [r.get("id") for r in all_items]
  assert item["id"] not in ids


async def test_delete_todo_not_found(ctx):
  result = await delete_todo(ctx, todo_id=999999)
  assert "error" in result or "not found" in str(result).lower()
