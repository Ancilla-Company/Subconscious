import asyncio
from datetime import timezone

import pytest
from sqlalchemy import func, inspect, select
from sqlalchemy.exc import IntegrityError

from subconscious_engine.storage.database import Database
from subconscious_engine.storage.models import (
    AppState, Contact, ConversationThread, Message, Network, Note, TodoItem,
    ToolRegistryRecord, Workspace, WorkspaceMemory, utc_now,
)


def run(coro):
    return asyncio.run(coro)


async def open_database(path):
    database = Database(path)
    await database.initialize()
    return database


def network(uuid="network"):
    return Network(uuid=uuid, name="Network", description=None,
                   default_workspace_uuid=None, passphrase=None)


def workspace(network_id, uuid="workspace"):
    return Workspace(name="Workspace", description=None, network_id=network_id, uuid=uuid,
                     tools_config=None, skills_config=None, directories=None,
                     approval_config=None, rag_config=None, default_model_id=None)


def test_database_initializes_all_tables_and_creates_parent_directory(tmp_path):
    async def scenario():
        database = await open_database(tmp_path / "nested" / "engine.db")
        try:
            async with database.engine.connect() as connection:
                tables = await connection.run_sync(lambda sync: set(inspect(sync).get_table_names()))
            assert {"networks", "workspaces", "threads", "messages", "app_state",
                    "tool_registry", "todo_items", "workspace_memory", "notes",
                    "contacts"} <= tables
            assert database.path.is_file()
        finally:
            await database.close()
    run(scenario())


def test_session_requires_commit_and_committed_rows_persist(tmp_path):
    async def scenario():
        database = await open_database(tmp_path / "sessions.db")
        try:
            async with database.session() as session:
                session.add(network("rolled-back"))
            async with database.session() as session:
                assert await session.scalar(select(func.count(Network.id))) == 0
                session.add(network("saved"))
                await session.commit()
            async with database.session() as session:
                assert await session.scalar(select(Network.uuid)) == "saved"
        finally:
            await database.close()
    run(scenario())


def test_foreign_keys_cascade_and_set_null_across_storage_models(tmp_path):
    async def scenario():
        database = await open_database(tmp_path / "cascade.db")
        try:
            async with database.session() as session:
                parent = network()
                session.add(parent)
                await session.flush()
                space = workspace(parent.id)
                session.add(space)
                await session.flush()
                thread = ConversationThread(uuid="thread", workspace_id=space.id, title=None,
                    description=None, default_model_id=None, tools_config=None,
                    skills_config=None, approval_config=None)
                session.add(thread)
                await session.flush()
                session.add_all([
                    Message(uuid="message", thread_id=thread.id, role="user", content="hello"),
                    TodoItem(workspace_id=space.id, thread_id=thread.id, title="todo",
                             notes=None, status="open", priority="normal", due_date=None),
                    WorkspaceMemory(workspace_id=space.id, key="key", value="value",
                                    source_thread_id=thread.id),
                    Note(workspace_id=space.id, title="note", content="body", tags=None),
                    Contact(workspace_id=space.id, name="name", email=None, phone=None, notes=None),
                ])
                await session.commit()
                await session.delete(thread)
                await session.commit()
            async with database.session() as session:
                assert await session.scalar(select(func.count(Message.id))) == 0
                assert await session.scalar(select(TodoItem.thread_id)) is None
                assert await session.scalar(select(WorkspaceMemory.source_thread_id)) is None
                space = await session.scalar(select(Workspace))
                await session.delete(space)
                await session.commit()
            async with database.session() as session:
                for model in (TodoItem, WorkspaceMemory, Note, Contact):
                    assert await session.scalar(select(func.count(model.id))) == 0
        finally:
            await database.close()
    run(scenario())


def test_unique_constraints_defaults_and_utc_timestamp(tmp_path):
    async def scenario():
        database = await open_database(tmp_path / "constraints.db")
        try:
            async with database.session() as session:
                session.add_all([network("duplicate"), network("duplicate")])
                with pytest.raises(IntegrityError):
                    await session.commit()
                await session.rollback()
                session.add_all([
                    AppState(key="theme", value="dark", tag="ui", client="desktop"),
                    AppState(key="theme", value="light", tag="ui", client="desktop"),
                ])
                with pytest.raises(IntegrityError):
                    await session.commit()
                await session.rollback()
                record = ToolRegistryRecord(uuid="tool", name="Tool", alias=None,
                    description=None, script_path=None, script_language=None,
                    endpoint_url=None, auth_type=None, auth_env_var=None)
                session.add(record)
                await session.commit()
                assert record.tool_type == "script" and record.status == "active"
                assert record.created_at.tzinfo is not None
        finally:
            await database.close()
    run(scenario())
    assert utc_now().tzinfo == timezone.utc


def test_invalid_foreign_keys_are_enforced(tmp_path):
    async def scenario():
        database = await open_database(tmp_path / "foreign-key.db")
        try:
            async with database.session() as session:
                session.add(workspace(999, "orphan"))
                with pytest.raises(IntegrityError):
                    await session.commit()
                await session.rollback()
        finally:
            await database.close()
    run(scenario())
