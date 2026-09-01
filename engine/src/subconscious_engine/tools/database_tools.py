"""Workspace-scoped database-backed built-in tool definitions."""

from datetime import datetime
from typing import Any, Callable

from sqlalchemy import delete, func, select

from subconscious_engine.storage.models import (Contact, Note, TodoItem, Workspace,
                                                 WorkspaceMemory, utc_now)

ToolFactory = Callable[[Any], Any]
ToolEntry = tuple[str, str, str, ToolFactory]


async def _workspace_id(context: Any, session: Any) -> int:
    identifier = await session.scalar(select(Workspace.id).where(Workspace.uuid == context.workspace_uuid))
    if identifier is None:
        raise ValueError("The current workspace no longer exists.")
    return int(identifier)


def _todo_factory(context: Any, action: str) -> Any:
    async def add_todo(title: str, notes: str = "", priority: str = "normal",
                       due_date: str | None = None) -> dict[str, Any]:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            row = TodoItem(workspace_id=workspace_id, thread_id=context.thread_id, title=title,
                notes=notes, priority=priority, status="open",
                due_date=datetime.fromisoformat(due_date) if due_date else None)
            session.add(row)
            await session.commit()
            return {"status": "success", "todo": _todo(row)}

    async def list_todos(status: str | None = None,
                         priority: str | None = None) -> dict[str, Any]:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            query = select(TodoItem).where(TodoItem.workspace_id == workspace_id)
            if status:
                query = query.where(TodoItem.status == status)
            if priority:
                query = query.where(TodoItem.priority == priority)
            rows = (await session.scalars(query.order_by(TodoItem.created_at.desc()))).all()
            return {"todos": [_todo(row, include_created=True) for row in rows]}

    async def update_todo(todo_id: int, title: str | None = None, notes: str | None = None,
                          status: str | None = None, priority: str | None = None,
                          due_date: str | None = None) -> dict[str, Any]:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            row = await session.scalar(select(TodoItem).where(
                TodoItem.id == todo_id, TodoItem.workspace_id == workspace_id))
            if row is None:
                return {"status": "error", "message": "Todo not found"}
            if title:
                row.title = title
            if notes is not None:
                row.notes = notes
            if status:
                row.status = status
            if priority:
                row.priority = priority
            if due_date is not None:
                row.due_date = datetime.fromisoformat(due_date) if due_date else None
            row.updated_at = utc_now()
            await session.commit()
            return {"status": "success", "todo": _todo(row)}

    async def complete_todo(todo_id: int) -> dict[str, Any]:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            row = await session.scalar(select(TodoItem).where(
                TodoItem.id == todo_id, TodoItem.workspace_id == workspace_id))
            if row is None:
                return {"status": "error", "message": "Todo not found"}
            row.status = "done"
            row.updated_at = utc_now()
            await session.commit()
            return {"status": "success", "message": f"Todo #{todo_id} marked as done"}

    async def delete_todo(todo_id: int) -> dict[str, Any]:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            row = await session.scalar(select(TodoItem).where(
                TodoItem.id == todo_id, TodoItem.workspace_id == workspace_id))
            if row is None:
                return {"status": "error", "message": "Todo not found"}
            await session.delete(row)
            await session.commit()
            return {"status": "success", "message": f"Todo #{todo_id} deleted"}

    return {"add": add_todo, "list": list_todos, "update": update_todo,
            "complete": complete_todo, "delete": delete_todo}[action]


def _todo(row: TodoItem, include_created: bool = False) -> dict[str, Any]:
    value = {"id": row.id, "title": row.title, "notes": row.notes,
             "priority": row.priority, "status": row.status,
             "due_date": row.due_date.date().isoformat() if row.due_date else None}
    if include_created:
        value["created_at"] = row.created_at.strftime("%Y-%m-%d %H:%M:%S")
    return value


def _memory_factory(context: Any, action: str) -> Any:
    async def remember(key: str, value: str) -> str:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            row = await session.scalar(select(WorkspaceMemory).where(
                WorkspaceMemory.workspace_id == workspace_id, WorkspaceMemory.key == key))
            if row is None:
                row = WorkspaceMemory(workspace_id=workspace_id, key=key, value=value,
                                      source_thread_id=context.thread_id)
                session.add(row)
            else:
                row.value = value
                row.updated_at = utc_now()
            await session.commit()
            return f"Remembered {key} = {value}"

    async def recall(key: str) -> str:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            value = await session.scalar(select(WorkspaceMemory.value).where(
                WorkspaceMemory.workspace_id == workspace_id, WorkspaceMemory.key == key))
            return value if value is not None else f"No memory found for key '{key}'"

    async def list_memories() -> str:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            rows = (await session.scalars(select(WorkspaceMemory).where(
                WorkspaceMemory.workspace_id == workspace_id).order_by(WorkspaceMemory.key))).all()
            return "\n".join(f"{row.key} = {row.value}" for row in rows) or "No memories stored."

    async def forget(key: str) -> str:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            row = await session.scalar(select(WorkspaceMemory).where(
                WorkspaceMemory.workspace_id == workspace_id, WorkspaceMemory.key == key))
            if row is None:
                return f"No memory found for key '{key}'"
            await session.delete(row)
            await session.commit()
            return f"Forgot {key}"

    async def forget_all() -> str:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            result = await session.execute(delete(WorkspaceMemory).where(
                WorkspaceMemory.workspace_id == workspace_id))
            await session.commit()
            return f"Cleared {result.rowcount or 0} memories from workspace."

    return {"remember": remember, "recall": recall, "list": list_memories,
            "forget": forget, "clear": forget_all}[action]


def _notes_factory(context: Any, action: str) -> Any:
    async def save_note(title: str, content: str, tags: str = "") -> dict[str, Any]:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            row = Note(workspace_id=workspace_id, title=title, content=content, tags=tags)
            session.add(row)
            await session.commit()
            return {"status": "success", "note": {"id": row.id, "title": row.title,
                "tags": row.tags, "created_at": row.created_at.strftime("%Y-%m-%d %H:%M:%S")}}

    async def list_notes(tag: str | None = None) -> dict[str, Any]:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            query = select(Note).where(Note.workspace_id == workspace_id)
            if tag:
                query = query.where(Note.tags.contains(tag))
            rows = (await session.scalars(query.order_by(Note.created_at.desc()))).all()
            return {"notes": [{"id": row.id, "title": row.title, "tags": row.tags,
                "created_at": row.created_at.strftime("%Y-%m-%d %H:%M:%S")} for row in rows]}

    async def get_note(note_id: int) -> dict[str, Any]:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            row = await session.scalar(select(Note).where(
                Note.id == note_id, Note.workspace_id == workspace_id))
            if row is None:
                return {"status": "error", "message": "Note not found"}
            return {"status": "success", "note": {"id": row.id, "title": row.title,
                "content": row.content, "tags": row.tags,
                "created_at": row.created_at.strftime("%Y-%m-%d %H:%M:%S"),
                "updated_at": row.updated_at.strftime("%Y-%m-%d %H:%M:%S")}}

    async def delete_note(note_id: int) -> dict[str, Any]:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            row = await session.scalar(select(Note).where(
                Note.id == note_id, Note.workspace_id == workspace_id))
            if row is None:
                return {"status": "error", "message": "Note not found"}
            await session.delete(row)
            await session.commit()
            return {"status": "success", "message": f"Note #{note_id} deleted"}

    return {"save": save_note, "list": list_notes, "get": get_note, "delete": delete_note}[action]


def _contacts_factory(context: Any, action: str) -> Any:
    async def add_contact(name: str, email: str = "", phone: str = "",
                          notes: str = "") -> dict[str, Any]:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            row = Contact(workspace_id=workspace_id, name=name, email=email, phone=phone, notes=notes)
            session.add(row)
            await session.commit()
            return {"status": "success", "contact": _contact(row)}

    async def list_contacts() -> dict[str, Any]:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            rows = (await session.scalars(select(Contact).where(
                Contact.workspace_id == workspace_id).order_by(Contact.name))).all()
            return {"contacts": [_contact(row) for row in rows]}

    async def find_contact(query: str) -> dict[str, Any]:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            term = f"%{query.casefold()}%"
            rows = (await session.scalars(select(Contact).where(Contact.workspace_id == workspace_id,
                func.lower(Contact.name).like(term) | func.lower(Contact.email).like(term)))).all()
            return {"contacts": [_contact(row) for row in rows]}

    async def update_contact(contact_id: int, name: str | None = None,
                             email: str | None = None, phone: str | None = None,
                             notes: str | None = None) -> dict[str, Any]:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            row = await session.scalar(select(Contact).where(
                Contact.id == contact_id, Contact.workspace_id == workspace_id))
            if row is None:
                return {"status": "error", "message": "Contact not found"}
            if name:
                row.name = name
            if email is not None:
                row.email = email
            if phone is not None:
                row.phone = phone
            if notes is not None:
                row.notes = notes
            row.updated_at = utc_now()
            await session.commit()
            return {"status": "success", "contact": _contact(row)}

    async def delete_contact(contact_id: int) -> dict[str, Any]:
        async with context.database.session() as session:
            workspace_id = await _workspace_id(context, session)
            row = await session.scalar(select(Contact).where(
                Contact.id == contact_id, Contact.workspace_id == workspace_id))
            if row is None:
                return {"status": "error", "message": "Contact not found"}
            await session.delete(row)
            await session.commit()
            return {"status": "success", "message": f"Contact #{contact_id} deleted"}

    return {"add": add_contact, "list": list_contacts, "find": find_contact,
            "update": update_contact, "delete": delete_contact}[action]


def _contact(row: Contact) -> dict[str, Any]:
    return {"id": row.id, "name": row.name, "email": row.email,
            "phone": row.phone, "notes": row.notes}


def _bind(factory: Callable[[Any, str], Any], action: str) -> ToolFactory:
    def create(context: Any) -> Any:
        return factory(context, action)
    return create


def database_tool_entries() -> list[ToolEntry]:
    todo = [
        ("todo", "add_todo", "Create a new to-do item in the current workspace.", "add"),
        ("todo", "list_todos", "List to-do items in the current workspace.", "list"),
        ("todo", "update_todo", "Update one or more fields of an existing to-do item.", "update"),
        ("todo", "complete_todo", "Mark a to-do item as done.", "complete"),
        ("todo", "delete_todo", "Permanently delete a to-do item by ID.", "delete"),
    ]
    memory = [
        ("memory", "remember", "Store or replace a workspace fact.", "remember"),
        ("memory", "recall", "Retrieve a workspace fact by key.", "recall"),
        ("memory", "list_memories", "List all workspace facts.", "list"),
        ("memory", "forget", "Delete a workspace fact by key.", "forget"),
        ("memory", "forget_all", "Clear all workspace memory.", "clear"),
    ]
    notes = [
        ("notes", "save_note", "Create a note in the current workspace.", "save"),
        ("notes", "list_notes", "List notes, optionally filtered by tag.", "list"),
        ("notes", "get_note", "Retrieve a note by ID.", "get"),
        ("notes", "delete_note", "Permanently delete a note by ID.", "delete"),
    ]
    contacts = [
        ("contacts", "add_contact", "Save a workspace contact.", "add"),
        ("contacts", "list_contacts", "List workspace contacts.", "list"),
        ("contacts", "find_contact", "Find contacts by name or email.", "find"),
        ("contacts", "update_contact", "Update a workspace contact.", "update"),
        ("contacts", "delete_contact", "Permanently delete a contact by ID.", "delete"),
    ]
    entries: list[ToolEntry] = []
    entries.extend((slug, name, doc, _bind(_todo_factory, action))
                   for slug, name, doc, action in todo)
    entries.extend((slug, name, doc, _bind(_memory_factory, action))
                   for slug, name, doc, action in memory)
    entries.extend((slug, name, doc, _bind(_notes_factory, action))
                   for slug, name, doc, action in notes)
    entries.extend((slug, name, doc, _bind(_contacts_factory, action))
                   for slug, name, doc, action in contacts)
    return entries
