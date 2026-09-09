import asyncio
from contextlib import asynccontextmanager
from io import BytesIO
import json
from types import SimpleNamespace
import zipfile

import httpx
import pytest

from subconscious_engine.api.app import create_app
from subconscious_engine.api.common import json_response, not_found
from subconscious_engine.auth import EngineAuthToken
from subconscious_engine.configuration import ModelConfigurationStoreError
from subconscious_engine.configuration.models import ModelConfigurationDto
from subconscious_engine.services.rag_service import RagServiceError
from subconscious_engine.storage import Database


def run(coro):
    return asyncio.run(coro)


class FakeStore:
    def __init__(self):
        self.models = {}
        self.tool_auth = {}
        self.fail_models = False
        self.fail_tools = False

    async def list(self):
        if self.fail_models:
            raise ModelConfigurationStoreError("credential vault unavailable")
        return list(self.models.values())

    async def create(self, request):
        identifier = f"model-{len(self.models) + 1}"
        value = self._dto(identifier, request)
        self.models[identifier] = value
        return value

    async def update(self, identifier, request):
        if identifier not in self.models:
            return None
        value = self._dto(identifier, request)
        self.models[identifier] = value
        return value

    async def delete(self, identifier):
        return self.models.pop(identifier, None) is not None

    async def resolve(self, identifier):
        return None

    async def get_tool_auth_config_ids(self):
        if self.fail_tools:
            raise ModelConfigurationStoreError("tool credential vault unavailable")
        return set(self.tool_auth)

    async def update_tool_auth_config(self, identifier, replacement, clear=False):
        if self.fail_tools:
            raise ModelConfigurationStoreError("tool credential vault unavailable")
        if replacement:
            self.tool_auth[identifier] = replacement
        elif clear:
            self.tool_auth.pop(identifier, None)
        return identifier in self.tool_auth

    async def remove_tool_auth_config(self, identifier):
        if self.fail_tools:
            raise ModelConfigurationStoreError("tool credential vault unavailable")
        self.tool_auth.pop(identifier, None)

    @staticmethod
    def _dto(identifier, request):
        return ModelConfigurationDto(
            id=identifier,
            provider=request.provider.strip(),
            model=request.model.strip(),
            alias=request.alias,
            baseUrl=request.base_url,
            contextWindow=request.context_window,
            hasApiKey=bool(request.api_key),
        )


class FakeRag:
    def __init__(self):
        self.error = None
        self.search_call = None

    async def index(self, session, workspace_uuid):
        if self.error:
            raise self.error
        return {"roots": [{"rootIndex": 0, "indexed": 2}]}

    async def search(self, session, workspace_uuid, query, mode, limit):
        if self.error:
            raise self.error
        self.search_call = (workspace_uuid, query, mode, limit)
        return [{"path": "notes.txt", "score": 0.75}]


class FakeBuiltinTools:
    def catalog(self):
        return {"local": [{"name": "echo", "doc": "Echo", "operation": "read"}]}


@asynccontextmanager
async def api_client(tmp_path, *, store=None, rag=None):
    database = Database(tmp_path / "api.db")
    await database.initialize()
    app = create_app(
        database,
        EngineAuthToken("secret-token"),
        model_configuration_store=store or FakeStore(),
        rag_service=rag or FakeRag(),
        tool_registry=FakeBuiltinTools(),
    )
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        yield client, app
    await database.close()


def auth():
    return {"Authorization": "Bearer secret-token"}


def test_response_helpers_serialize_aliases_and_standardize_not_found():
    value = ModelConfigurationDto(
        id="m1", provider="openai", model="gpt", contextWindow=4096, hasApiKey=False
    )
    response = json_response({"items": [value]}, 201, {"X-Test": "yes"})
    assert response.status_code == 201
    assert json.loads(response.body) == {
        "items": [{
            "id": "m1", "provider": "openai", "model": "gpt", "alias": None,
            "baseUrl": None, "region": None, "contextWindow": 4096,
            "hasApiKey": False,
        }]
    }
    assert response.headers["x-test"] == "yes"
    missing = not_found("Widget")
    assert missing.status_code == 404
    assert json.loads(missing.body) == {"error": "Widget not found."}


def test_health_is_public_while_api_routes_require_bearer_authentication(tmp_path):
    async def scenario():
        async with api_client(tmp_path) as (client, _):
            health = await client.get("/api/v1/health")
            assert health.status_code == 200
            assert health.json()["status"] == "ok"
            assert isinstance(health.json()["version"], str)

            denied = await client.get("/api/v1/workspaces")
            assert denied.status_code == 401
            assert denied.json() == {"error": "Missing or invalid bearer token."}
            assert (await client.get("/api/v1/workspaces", headers=auth())).json() == []
            assert (await client.patch("/api/v1/workspaces", headers=auth())).status_code == 405
    run(scenario())


def test_authenticated_workspace_thread_and_message_crud_and_validation(tmp_path):
    async def scenario():
        async with api_client(tmp_path) as (client, _):
            invalid = await client.post(
                "/api/v1/workspaces", headers=auth(), content=b"{",
            )
            assert invalid.status_code == 400
            assert invalid.json()["error"] == "Invalid request body."
            assert (await client.post(
                "/api/v1/workspaces", headers=auth(), json={"name": ""}
            )).status_code == 400

            created = await client.post(
                "/api/v1/workspaces", headers=auth(),
                json={"name": "Alpha", "defaultModelId": "echo"},
            )
            assert created.status_code == 200
            workspace = created.json()
            workspace_id = workspace["uuid"]
            assert workspace["name"] == "Alpha"
            assert workspace["defaultModelId"] == "echo"
            assert [item["uuid"] for item in (await client.get(
                "/api/v1/workspaces", headers=auth()
            )).json()] == [workspace_id]

            fetched = await client.get(f"/api/v1/workspaces/{workspace_id}", headers=auth())
            assert fetched.json()["name"] == "Alpha"
            updated = await client.put(
                f"/api/v1/workspaces/{workspace_id}", headers=auth(),
                json={"name": "Renamed", "description": "updated"},
            )
            assert updated.json()["description"] == "updated"
            missing_workspace = await client.get("/api/v1/workspaces/missing", headers=auth())
            assert missing_workspace.status_code == 404
            assert missing_workspace.json() == {"error": "Workspace not found."}

            missing_parent = await client.post(
                "/api/v1/threads", headers=auth(),
                json={"workspaceUuid": "missing", "title": "No parent"},
            )
            assert missing_parent.status_code == 404
            thread_response = await client.post(
                "/api/v1/threads", headers=auth(),
                json={"workspaceUuid": workspace_id, "title": "First"},
            )
            thread = thread_response.json()
            thread_id = thread["uuid"]
            assert thread["workspaceUuid"] == workspace_id
            assert [item["uuid"] for item in (await client.get(
                f"/api/v1/workspaces/{workspace_id}/threads", headers=auth()
            )).json()] == [thread_id]

            bad_message = await client.post(
                "/api/v1/messages", headers=auth(),
                json={"threadUuid": thread_id, "role": "invalid", "content": "x"},
            )
            assert bad_message.status_code == 400
            missing_thread = await client.post(
                "/api/v1/messages", headers=auth(),
                json={"threadUuid": "missing", "role": "user", "content": "hello"},
            )
            assert missing_thread.status_code == 404
            message = (await client.post(
                "/api/v1/messages", headers=auth(),
                json={"threadUuid": thread_id, "role": "user", "content": "hello"},
            )).json()
            assert message["threadUuid"] == thread_id
            assert (await client.get(
                f"/api/v1/threads/{thread_id}/messages", headers=auth()
            )).json()[0]["content"] == "hello"

            changed = await client.put(
                f"/api/v1/threads/{thread_id}", headers=auth(),
                json={"title": "Second", "description": "changed"},
            )
            assert changed.json()["title"] == "Second"
            assert (await client.delete(
                f"/api/v1/threads/{thread_id}", headers=auth()
            )).status_code == 204
            assert (await client.get(
                f"/api/v1/threads/{thread_id}", headers=auth()
            )).status_code == 404
            assert (await client.delete(
                f"/api/v1/workspaces/{workspace_id}", headers=auth()
            )).status_code == 204
            assert (await client.delete(
                f"/api/v1/workspaces/{workspace_id}", headers=auth()
            )).status_code == 404
    run(scenario())


def test_settings_and_workspace_file_routes_through_asgi(tmp_path):
    async def scenario():
        root = tmp_path / "workspace"
        root.mkdir()
        async with api_client(tmp_path) as (client, _):
            workspace = (await client.post(
                "/api/v1/workspaces", headers=auth(),
                json={"name": "Files", "directories": json.dumps([str(root)])},
            )).json()
            workspace_id = workspace["uuid"]

            values = [
                {"key": "theme", "value": "dark", "tag": "ui", "client": "desktop"},
                {"key": "shared", "value": "yes", "tag": None, "client": None},
            ]
            saved = await client.put("/api/v1/settings", headers=auth(), json=values)
            assert saved.status_code == 200
            assert saved.json() == values
            filtered = await client.get(
                "/api/v1/settings?key=theme&tag=ui&client=desktop", headers=auth()
            )
            assert filtered.json() == [values[0]]
            duplicate = await client.put(
                "/api/v1/settings", headers=auth(), json=[values[0], values[0]]
            )
            assert duplicate.status_code == 400
            assert "unique" in duplicate.json()["error"]
            assert (await client.put(
                "/api/v1/settings", headers=auth(), json=[]
            )).status_code == 400

            base = f"/api/v1/workspaces/{workspace_id}/files"
            no_root = await client.get(base, headers=auth())
            assert no_root.status_code == 400
            assert no_root.json() == {"error": "rootIndex must be an integer."}
            assert (await client.get(f"{base}?rootIndex=0", headers=auth())).json() == []

            created = await client.post(
                f"{base}/content?rootIndex=0&path=note.txt", headers=auth(),
                json={"content": "first"},
            )
            assert created.status_code == 200
            assert created.json() == {"content": "first"}
            listing = (await client.get(f"{base}?rootIndex=0", headers=auth())).json()
            assert listing == [{
                "name": "note.txt", "relativePath": "note.txt", "isDirectory": False,
            }]
            assert (await client.get(
                f"{base}/content?rootIndex=0&path=note.txt", headers=auth()
            )).json() == {"content": "first"}
            assert (await client.put(
                f"{base}/content?rootIndex=0&path=note.txt", headers=auth(),
                json={"content": "second"},
            )).json() == {"content": "second"}
            assert root.joinpath("note.txt").read_text(encoding="utf-8") == "second"
            directory = await client.post(
                f"{base}/directory?rootIndex=0&path=src", headers=auth()
            )
            assert directory.json()["isDirectory"] is True
            traversal = await client.get(
                f"{base}/content?rootIndex=0&path=../secret.txt", headers=auth()
            )
            assert traversal.status_code == 400
            missing = await client.get(
                f"{base}/content?rootIndex=0&path=missing.txt", headers=auth()
            )
            assert missing.status_code == 404

            png = b"\x89PNG\r\n\x1a\npreview"
            pdf = b"%PDF-1.7\n%%EOF"
            docx_buffer = BytesIO()
            with zipfile.ZipFile(docx_buffer, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("[Content_Types].xml", "<Types/>")
                archive.writestr("word/document.xml", "<w:document/>")
            previews = {
                "preview.png": ("image", "image/png", png),
                "preview.pdf": ("pdf", "application/pdf", pdf),
                "preview.docx": (
                    "docx",
                    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                    docx_buffer.getvalue(),
                ),
            }
            for filename, (kind, media_type, content) in previews.items():
                (root / filename).write_bytes(content)
                preview = await client.get(
                    f"{base}/preview",
                    headers=auth(),
                    params={"rootIndex": 0, "path": filename},
                )
                assert preview.status_code == 200
                assert preview.content == content
                assert preview.headers["content-type"] == media_type
                assert preview.headers["content-length"] == str(len(content))
                assert preview.headers["x-preview-kind"] == kind
                assert preview.headers["x-content-type-options"] == "nosniff"
                assert preview.headers["cache-control"] == "no-store, private"
                assert f'filename="{filename}"' in preview.headers["content-disposition"]
    run(scenario())


def test_model_and_tool_crud_locations_catalogs_and_storage_errors(tmp_path):
    async def scenario():
        store = FakeStore()
        async with api_client(tmp_path, store=store) as (client, _):
            assert (await client.post(
                "/api/v1/model-configurations", headers=auth(), json={"provider": "openai"}
            )).status_code == 400
            created = await client.post(
                "/api/v1/model-configurations", headers=auth(),
                json={"provider": "openai", "model": "gpt-test", "alias": "Test",
                      "contextWindow": 2048, "apiKey": "write-only"},
            )
            assert created.status_code == 201
            assert created.headers["location"] == "/api/v1/model-configurations/model-1"
            assert created.json()["hasApiKey"] is True
            assert "apiKey" not in created.json()
            assert (await client.get(
                "/api/v1/model-configurations", headers=auth()
            )).json()[0]["id"] == "model-1"
            catalog = (await client.get("/api/v1/models", headers=auth())).json()
            assert [(item["id"], item["name"]) for item in catalog] == [
                ("model-1", "Test"), ("echo", "Echo (dev)"),
            ]
            assert (await client.put(
                "/api/v1/model-configurations/missing", headers=auth(),
                json={"provider": "x", "model": "y"},
            )).status_code == 404
            assert (await client.delete(
                "/api/v1/model-configurations/missing", headers=auth()
            )).status_code == 404

            invalid_tool = await client.post(
                "/api/v1/tool-registry", headers=auth(), json={"toolType": "unknown"}
            )
            assert invalid_tool.status_code == 400
            tool_response = await client.post(
                "/api/v1/tool-registry", headers=auth(),
                json={"alias": "Runner", "toolType": "script", "scriptPath": "run.py"},
            )
            assert tool_response.status_code == 201
            tool = tool_response.json()
            tool_id = tool["uuid"]
            assert tool_response.headers["location"] == f"/api/v1/tool-registry/{tool_id}"
            assert (await client.get(
                f"/api/v1/tool-registry/{tool_id}", headers=auth()
            )).json()["alias"] == "Runner"
            changed = await client.put(
                f"/api/v1/tool-registry/{tool_id}", headers=auth(),
                json={"alias": "Remote", "toolType": "api",
                      "endpointUrl": "https://example.test/tool"},
            )
            assert changed.json()["endpointUrl"] == "https://example.test/tool"
            tools = (await client.get("/api/v1/tools/catalog", headers=auth())).json()
            assert tools["builtin"]["local"][0]["name"] == "echo"
            assert tools["configured"][0]["uuid"] == tool_id
            assert (await client.put(
                "/api/v1/tool-registry/missing", headers=auth(),
                json={"alias": "x"},
            )).status_code == 404
            assert (await client.delete(
                f"/api/v1/tool-registry/{tool_id}", headers=auth()
            )).status_code == 204
            assert (await client.get(
                f"/api/v1/tool-registry/{tool_id}", headers=auth()
            )).status_code == 404

            store.fail_models = True
            unavailable = await client.get("/api/v1/model-configurations", headers=auth())
            assert unavailable.status_code == 503
            assert unavailable.headers["content-type"].startswith("application/problem+json")
            assert unavailable.json()["detail"] == "credential vault unavailable"
            store.fail_models = False
            store.fail_tools = True
            unavailable = await client.get("/api/v1/tool-registry", headers=auth())
            assert unavailable.status_code == 503
            assert unavailable.json()["detail"] == "tool credential vault unavailable"
    run(scenario())


def test_rag_routes_validate_payload_forward_arguments_and_map_service_errors(tmp_path):
    async def scenario():
        rag = FakeRag()
        async with api_client(tmp_path, rag=rag) as (client, _):
            indexed = await client.post(
                "/api/v1/workspaces/ws/rag/index", headers=auth()
            )
            assert indexed.json() == {"roots": [{"rootIndex": 0, "indexed": 2}]}
            assert (await client.post(
                "/api/v1/workspaces/ws/rag/search", headers=auth(),
                json={"query": "", "limit": 0},
            )).status_code == 400
            result = await client.post(
                "/api/v1/workspaces/ws/rag/search", headers=auth(),
                json={"query": "needle", "mode": "keyword", "limit": 3},
            )
            assert result.json() == [{"path": "notes.txt", "score": 0.75}]
            assert rag.search_call == ("ws", "needle", "keyword", 3)
            rag.error = RagServiceError(409, "index is busy")
            failed = await client.post(
                "/api/v1/workspaces/ws/rag/index", headers=auth()
            )
            assert failed.status_code == 409
            assert failed.json() == {"error": "index is busy"}
    run(scenario())
