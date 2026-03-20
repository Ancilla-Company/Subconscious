"""
To-do list tools — create, list, update, complete and delete tasks.
Backed by the TodoItem table in the Subconscious database.
All operations are scoped to the current workspace.
"""

from typing import Optional
from datetime import datetime
from sqlalchemy import select
from pydantic_ai import RunContext

from . import EngineContext
from ..db.models import TodoItem


async def add_todo(
  ctx: RunContext[EngineContext],
  title: str,
  notes: str = "",
  priority: str = "normal",
  due_date: Optional[str] = None,
) -> dict:
  """
  Create a new to-do item in the current workspace.

  Args:
    title: Short description of the task (required).
    notes: Optional longer description or context.
    priority: One of 'low', 'normal', 'high', 'urgent' (default 'normal').
    due_date: Optional ISO date string 'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM'.
  """
  valid_priorities = {"low", "normal", "high", "urgent"}
  if priority not in valid_priorities:
    return {"error": f"Invalid priority '{priority}'. Use: {', '.join(valid_priorities)}"}

  due = None
  if due_date:
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d"):
      try:
        due = datetime.strptime(due_date, fmt)
        break
      except ValueError:
        pass
    if not due:
      return {"error": f"Could not parse due_date '{due_date}'. Use 'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM'."}

  async with ctx.deps.db.get_session() as session:
    item = TodoItem(
      workspace_id=ctx.deps.workspace_id,
      thread_id=ctx.deps.thread_id or None,
      title=title,
      notes=notes or None,
      priority=priority,
      due_date=due,
      status="open",
    )
    session.add(item)
    await session.commit()
    await session.refresh(item)
    return {"id": item.id, "title": item.title, "status": item.status, "priority": item.priority}


async def list_todos(
  ctx: RunContext[EngineContext],
  status: Optional[str] = None,
  priority: Optional[str] = None,
) -> list[dict]:
  """
  List to-do items in the current workspace.
  Optionally filter by status ('open', 'in_progress', 'done', 'cancelled')
  or priority ('low', 'normal', 'high', 'urgent').

  Args:
    status:   Filter by status (optional, returns all statuses if omitted).
    priority: Filter by priority (optional).
  """
  async with ctx.deps.db.get_session() as session:
    stmt = select(TodoItem).where(TodoItem.workspace_id == ctx.deps.workspace_id)
    if status:
      stmt = stmt.where(TodoItem.status == status)
    if priority:
      stmt = stmt.where(TodoItem.priority == priority)
    stmt = stmt.order_by(TodoItem.created_at.desc())
    rows = await session.scalars(stmt)
    items = rows.all()

  if not items:
    return [{"message": "No to-do items found."}]

  return [
    {
      "id":        i.id,
      "title":     i.title,
      "status":    i.status,
      "priority":  i.priority,
      "notes":     i.notes,
      "due_date":  i.due_date.strftime("%Y-%m-%d %H:%M") if i.due_date else None,
      "created":   i.created_at.strftime("%Y-%m-%d %H:%M") if i.created_at else None,
    }
    for i in items
  ]


async def update_todo(
  ctx: RunContext[EngineContext],
  todo_id: int,
  title: Optional[str] = None,
  notes: Optional[str] = None,
  priority: Optional[str] = None,
  status: Optional[str] = None,
  due_date: Optional[str] = None,
) -> dict:
  """
  Update one or more fields of an existing to-do item.
  Only provided fields are changed; omitted fields stay as they are.

  Args:
    todo_id:  The numeric ID of the to-do item.
    title:    New title (optional).
    notes:    New notes (optional).
    priority: New priority: 'low', 'normal', 'high', 'urgent' (optional).
    status:   New status: 'open', 'in_progress', 'done', 'cancelled' (optional).
    due_date: New due date 'YYYY-MM-DD' (optional, pass empty string to clear).
  """
  async with ctx.deps.db.get_session() as session:
    item = await session.get(TodoItem, todo_id)
    if not item:
      return {"error": f"To-do item {todo_id} not found."}
    if item.workspace_id != ctx.deps.workspace_id:
      return {"error": "Access denied: item belongs to a different workspace."}

    if title   is not None: item.title    = title    # type: ignore[assignment]
    if notes   is not None: item.notes    = notes    # type: ignore[assignment]
    if priority is not None: item.priority = priority  # type: ignore[assignment]
    if status  is not None: item.status   = status   # type: ignore[assignment]
    if due_date is not None:
      if due_date == "":
        item.due_date = None   # type: ignore[assignment]
      else:
        for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d"):
          try:
            item.due_date = datetime.strptime(due_date, fmt)  # type: ignore[assignment]
            break
          except ValueError:
            pass

    await session.commit()
    return {"id": item.id, "title": item.title, "status": item.status, "priority": item.priority}


async def complete_todo(ctx: RunContext[EngineContext], todo_id: int) -> str:
  """
  Mark a to-do item as done.

  Args:
    todo_id: The numeric ID of the to-do item.
  """
  async with ctx.deps.db.get_session() as session:
    item = await session.get(TodoItem, todo_id)
    if not item:
      return f"To-do item {todo_id} not found."
    if item.workspace_id != ctx.deps.workspace_id:
      return "Access denied."
    item.status = "done"  # type: ignore[assignment]
    await session.commit()
    return f"✓ Marked as done: '{item.title}'"


async def delete_todo(ctx: RunContext[EngineContext], todo_id: int) -> str:
  """
  Permanently delete a to-do item by ID.

  Args:
    todo_id: The numeric ID of the to-do item to delete.
  """
  async with ctx.deps.db.get_session() as session:
    item = await session.get(TodoItem, todo_id)
    if not item:
      return f"To-do item {todo_id} not found."
    if item.workspace_id != ctx.deps.workspace_id:
      return "Access denied."
    await session.delete(item)
    await session.commit()
    return f"Deleted to-do: '{item.title}'"


TOOLS = [add_todo, list_todos, update_todo, complete_todo, delete_todo]
