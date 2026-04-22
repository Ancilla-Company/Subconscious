"""
Notes tools — save, list, retrieve and delete workspace-scoped notes.
Backed by the Note table. Notes are free-form text documents with optional tags.
"""

from typing import Optional
from sqlalchemy import select
from pydantic_ai import RunContext

from . import EngineContext
from ..db.models import Note


async def save_note(
  ctx: RunContext[EngineContext],
  title: str,
  content: str,
  tags: str = "",
) -> dict:
  """
  Create a new note in the current workspace.
  If a note with the same title already exists it will be updated.

  Args:
    title:   Short title for the note.
    content: The body of the note (plain text or markdown).
    tags:    Optional comma-separated tags, e.g. 'recipe, vegetarian'.
  """
  async with ctx.deps.db.get_session() as session:
    existing = await session.scalar(
      select(Note).where(Note.workspace_id == ctx.deps.workspace_id, Note.title == title)
    )
    if existing:
      existing.content = content  # type: ignore[assignment]
      existing.tags    = tags or None  # type: ignore[assignment]
      await session.commit()
      return {"id": existing.id, "title": existing.title, "action": "updated"}
    else:
      note = Note(
        workspace_id=ctx.deps.workspace_id,
        title=title,
        content=content,
        tags=tags or None,
      )
      session.add(note)
      await session.commit()
      await session.refresh(note)
      return {"id": note.id, "title": note.title, "action": "created"}


async def list_notes(
  ctx: RunContext[EngineContext],
  tag: Optional[str] = None,
) -> list[dict]:
  """
  List all notes in the current workspace.
  Optionally filter by a tag substring.

  Args:
    tag: If provided, only notes whose tags contain this string are returned.
  """
  async with ctx.deps.db.get_session() as session:
    stmt = select(Note).where(Note.workspace_id == ctx.deps.workspace_id)
    if tag:
      stmt = stmt.where(Note.tags.contains(tag))  # type: ignore[attr-defined]
    stmt = stmt.order_by(Note.updated_at.desc())
    rows = await session.scalars(stmt)
    notes = rows.all()

  if not notes:
    return [{"message": "No notes found."}]

  return [
    {
      "id":       n.id,
      "title":    n.title,
      "tags":     n.tags,
      "updated":  n.updated_at.strftime("%Y-%m-%d %H:%M") if n.updated_at else None,
      "preview":  str(n.content)[:120] + ("…" if n.content and len(n.content) > 120 else ""),
    }
    for n in notes
  ]


async def get_note(ctx: RunContext[EngineContext], note_id: int) -> dict:
  """
  Retrieve the full content of a note by its ID.

  Args:
    note_id: The numeric ID of the note.
  """
  async with ctx.deps.db.get_session() as session:
    note = await session.get(Note, note_id)
  if not note or note.workspace_id != ctx.deps.workspace_id:
    return {"error": f"Note {note_id} not found."}
  return {
    "id":      note.id,
    "title":   note.title,
    "content": note.content,
    "tags":    note.tags,
    "updated": note.updated_at.strftime("%Y-%m-%d %H:%M") if note.updated_at else None,
  }


async def delete_note(ctx: RunContext[EngineContext], note_id: int) -> str:
  """
  Permanently delete a note by its ID.

  Args:
    note_id: The numeric ID of the note to delete.
  """
  async with ctx.deps.db.get_session() as session:
    note = await session.get(Note, note_id)
    if not note or note.workspace_id != ctx.deps.workspace_id:
      return f"Note {note_id} not found."
    title = note.title
    await session.delete(note)
    await session.commit()
  return f"Deleted note: '{title}'"


TOOLS = [save_note, list_notes, get_note, delete_note]
