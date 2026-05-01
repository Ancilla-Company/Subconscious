"""
Contact management tools — backed by the Contact ORM table.

Each tool is scoped to ctx.deps.workspace_id so contacts are private
to the active workspace.
"""

import logging
from typing import Optional
from sqlalchemy import select
from pydantic_ai import RunContext

from . import EngineContext
from ..db.models import Contact


logger = logging.getLogger("subconscious")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _contact_to_dict(c: Contact) -> dict:
  return {
    "id":    c.id,
    "name":  c.name,
    "email": c.email or "",
    "phone": c.phone or "",
    "notes": c.notes or "",
  }


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

async def add_contact(
  ctx: RunContext[EngineContext],
  name:  str,
  email: str = "",
  phone: str = "",
  notes: str = "",
) -> dict:
  """
  Save a new contact for the current workspace.

  Args:
    name:  Full name (required).
    email: Email address (optional).
    phone: Phone number (optional).
    notes: Freeform notes about this contact (optional).

  Returns:
    The saved contact record as a dict.
  """
  try:
    async with ctx.deps.db.get_session() as session:
      contact = Contact(
        workspace_id=ctx.deps.workspace_id,
        name=name.strip(),
        email=email.strip() or None,
        phone=phone.strip() or None,
        notes=notes.strip() or None,
      )
      session.add(contact)
      await session.commit()
      await session.refresh(contact)
      result = _contact_to_dict(contact)
    return {"status": "ok", "contact": result}
  except Exception as exc:
    logger.error(f"add_contact error: {exc}")
    return {"status": "error", "message": str(exc)}


async def list_contacts(
  ctx: RunContext[EngineContext],
) -> dict:
  """
  Return all contacts saved for the current workspace.

  Returns:
    A dict with a 'contacts' list; each item has id, name, email, phone, notes.
  """
  try:
    async with ctx.deps.db.get_session() as session:
      rows = (
        await session.execute(
          select(Contact)
          .where(Contact.workspace_id == ctx.deps.workspace_id)
          .order_by(Contact.name)
        )
      ).scalars().all()
    return {"status": "ok", "contacts": [_contact_to_dict(c) for c in rows]}
  except Exception as exc:
    logger.error(f"list_contacts error: {exc}")
    return {"status": "error", "message": str(exc)}


async def find_contact(
  ctx: RunContext[EngineContext],
  query: str,
) -> dict:
  """
  Search for contacts by name or email (case-insensitive substring match).

  Args:
    query: Search string to match against name or email fields.

  Returns:
    Matching contacts as a list of dicts.
  """
  try:
    q = f"%{query.lower()}%"
    async with ctx.deps.db.get_session() as session:
      rows = (
        await session.execute(
          select(Contact).where(
            Contact.workspace_id == ctx.deps.workspace_id,
          )
        )
      ).scalars().all()
      # Filter in Python to avoid dialect-specific LOWER() issues
      matched = [
        c for c in rows
        if query.lower() in (c.name or "").lower()
        or query.lower() in (c.email or "").lower()
      ]
    return {"status": "ok", "contacts": [_contact_to_dict(c) for c in matched]}
  except Exception as exc:
    logger.error(f"find_contact error: {exc}")
    return {"status": "error", "message": str(exc)}


async def update_contact(
  ctx: RunContext[EngineContext],
  contact_id: int,
  name:  Optional[str] = None,
  email: Optional[str] = None,
  phone: Optional[str] = None,
  notes: Optional[str] = None,
) -> dict:
  """
  Update one or more fields on an existing contact.

  Args:
    contact_id: ID of the contact to update.
    name:       New name (leave blank to keep current).
    email:      New email (leave blank to keep current).
    phone:      New phone (leave blank to keep current).
    notes:      New notes (leave blank to keep current).

  Returns:
    The updated contact dict or an error message.
  """
  try:
    async with ctx.deps.db.get_session() as session:
      contact = await session.get(Contact, contact_id)
      if not contact or contact.workspace_id != ctx.deps.workspace_id:
        return {"status": "error", "message": f"Contact #{contact_id} not found."}
      if name  is not None: contact.name  = name.strip()
      if email is not None: contact.email = email.strip() or None
      if phone is not None: contact.phone = phone.strip() or None
      if notes is not None: contact.notes = notes.strip() or None
      await session.commit()
      result = _contact_to_dict(contact)
    return {"status": "ok", "contact": result}
  except Exception as exc:
    logger.error(f"update_contact error: {exc}")
    return {"status": "error", "message": str(exc)}


async def delete_contact(
  ctx: RunContext[EngineContext],
  contact_id: int,
) -> dict:
  """
  Permanently delete a contact by ID.

  Args:
    contact_id: ID of the contact to delete.

  Returns:
    Confirmation dict or error.
  """
  try:
    async with ctx.deps.db.get_session() as session:
      contact = await session.get(Contact, contact_id)
      if not contact or contact.workspace_id != ctx.deps.workspace_id:
        return {"status": "error", "message": f"Contact #{contact_id} not found."}
      await session.delete(contact)
      await session.commit()
    return {"status": "ok", "message": f"Contact #{contact_id} deleted."}
  except Exception as exc:
    logger.error(f"delete_contact error: {exc}")
    return {"status": "error", "message": str(exc)}


# List that ToolRegistry will discover
TOOLS = [add_contact, list_contacts, find_contact, update_contact, delete_contact]
