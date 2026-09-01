import asyncio
from dataclasses import dataclass

import pytest
from cryptography.fernet import Fernet

from subconscious_engine.api.extra_schemas import AppStateSettingDto, UpsertToolRegistryRequest
from subconscious_engine.api.schemas import (
    CreateThreadRequest, CreateWorkspaceRequest, SendMessageRequest, UpdateThreadRequest,
)
from subconscious_engine.configuration.store import EncryptedModelConfigurationStore
from subconscious_engine.services.messages import MessageService
from subconscious_engine.services.settings import SettingsService
from subconscious_engine.services.threads import ThreadService
from subconscious_engine.services.tool_registry import ToolRegistryService
from subconscious_engine.services.workspaces import WorkspaceService
from subconscious_engine.storage.database import Database


def run(coro):
    return asyncio.run(coro)


@dataclass
class StaticKeyProvider:
    key: str

    def get_or_create_key(self):
        return self.key


async def open_database(path):
    database = Database(path)
    await database.initialize()
    return database


def test_workspace_thread_message_and_setting_lifecycle_with_real_sqlite(tmp_path):
    async def scenario():
        database = await open_database(tmp_path / "services.db")
        try:
            async with database.session() as session:
                workspaces = WorkspaceService(session)
                threads = ThreadService(session)
                messages = MessageService(session)
                settings = SettingsService(session)

                assert await workspaces.list() == []
                workspace = await workspaces.create(CreateWorkspaceRequest(
                    name="Beta", description="initial", directories="[]"
                ))
                await workspaces.create(CreateWorkspaceRequest(name="Alpha"))
                assert [item.name for item in await workspaces.list()] == ["Alpha", "Beta"]

                assert await threads.create(CreateThreadRequest(
                    workspaceUuid="missing", title="nope"
                )) is None
                thread = await threads.create(CreateThreadRequest(
                    workspaceUuid=workspace.uuid, title="First"
                ))
                assert thread.workspace_uuid == workspace.uuid
                row = await threads.get(thread.uuid)
                updated = await threads.update(row, UpdateThreadRequest(title="Renamed"))
                assert updated.title == "Renamed"
                assert [item.uuid for item in await threads.list(workspace.uuid)] == [thread.uuid]

                assert await messages.create(SendMessageRequest(
                    threadUuid="missing", role="user", content="ignored"
                )) is None
                first = await messages.create(SendMessageRequest(
                    threadUuid=thread.uuid, role="user", content="hello"
                ))
                second = await messages.create(SendMessageRequest(
                    threadUuid=thread.uuid, role="assistant", content="world"
                ))
                assert [(item.uuid, item.content) for item in await messages.list(thread.uuid)] == [
                    (first.uuid, "hello"), (second.uuid, "world")
                ]

                await settings.upsert([
                    AppStateSettingDto(key="theme", value="dark", tag="ui", client="desktop"),
                    AppStateSettingDto(key="shared", value="one"),
                ])
                await settings.upsert([
                    AppStateSettingDto(key="theme", value="light", tag="ui", client="desktop")
                ])
                assert [(item.key, item.value) for item in await settings.list(None, None, None)] == [
                    ("theme", "light"), ("shared", "one")
                ]
                assert [item.value for item in await settings.list("theme", "ui", "desktop")] == [
                    "light"
                ]

                workspace_row = await workspaces.get(workspace.uuid)
                changed = await workspaces.update(workspace_row, CreateWorkspaceRequest(
                    name="Beta 2", description="changed"
                ))
                assert changed.name == "Beta 2" and changed.description == "changed"

                await threads.delete(await threads.get(thread.uuid))
                assert await messages.list(thread.uuid) == []
                await workspaces.delete(await workspaces.get(workspace.uuid))
                assert await workspaces.get(workspace.uuid) is None
        finally:
            await database.close()
    run(scenario())


def test_tool_registry_persists_metadata_and_encrypted_auth_with_real_sqlite(tmp_path):
    async def scenario():
        database = await open_database(tmp_path / "tools.db")
        credentials = EncryptedModelConfigurationStore(
            tmp_path / "secrets", StaticKeyProvider(Fernet.generate_key().decode("ascii"))
        )
        try:
            async with database.session() as session:
                tools = ToolRegistryService(session, credentials)
                created = await tools.create(UpsertToolRegistryRequest(
                    name=" weather-api ", alias=" Weather ", toolType="api",
                    endpointUrl="https://example.test/tools", authType="api_key",
                    authConfigJson='{"Authorization":"Bearer secret"}'
                ))
                assert created.name == "weather-api"
                assert created.alias == "Weather"
                assert created.has_auth_config is True
                assert b"Bearer secret" not in (tmp_path / "secrets" / "data.enc").read_bytes()
                assert (await tools.get(created.uuid)).has_auth_config is True
                assert [item.uuid for item in await tools.list()] == [created.uuid]

                updated = await tools.update(created.uuid, UpsertToolRegistryRequest(
                    alias="Local Script", toolType="script", scriptPath="tool.py"
                ))
                assert updated.tool_type == "script"
                assert updated.has_auth_config is False
                assert await credentials.get_tool_auth_config(created.uuid) is None
                assert await tools.update("missing", UpsertToolRegistryRequest(alias="x")) is None
                assert await tools.delete(created.uuid) is True
                assert await tools.delete(created.uuid) is False
        finally:
            await database.close()
    run(scenario())


@pytest.mark.parametrize("payload, message", [
    (UpsertToolRegistryRequest(alias="bad", toolType="unknown"), "Tool type"),
    (UpsertToolRegistryRequest(alias="bad", toolType="script", endpointUrl="https://example.test"),
     "Endpoint URLs"),
    (UpsertToolRegistryRequest(alias="bad", toolType="api", endpointUrl="https://u:p@example.test"),
     "without embedded credentials"),
    (UpsertToolRegistryRequest(alias="bad", toolType="api", authType="basic"), "Only api_key"),
    (UpsertToolRegistryRequest(alias="bad", toolType="api", authType="api_key",
                               authConfigJson='{"X":"a","x":"b"}'), "unique HTTP"),
    (UpsertToolRegistryRequest(alias="bad", toolType="api", authType="api_key",
                               authConfigJson='{"X":"line\\nfeed"}'), "unique HTTP"),
])
def test_tool_registry_rejects_unsafe_types_endpoints_and_headers(tmp_path, payload, message):
    async def scenario():
        database = await open_database(tmp_path / "invalid-tools.db")
        credentials = EncryptedModelConfigurationStore(
            tmp_path / "invalid-secrets", StaticKeyProvider(Fernet.generate_key().decode("ascii"))
        )
        try:
            async with database.session() as session:
                with pytest.raises(ValueError, match=message):
                    await ToolRegistryService(session, credentials).create(payload)
        finally:
            await database.close()
    run(scenario())
