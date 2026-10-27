"""Wire contracts for settings, files, tools, and RAG."""

from datetime import datetime
from typing import Any

from pydantic import Field

from .schemas import WireModel


class AppStateSettingDto(WireModel):
    key: str
    value: str
    tag: str | None = None
    client: str | None = None


class WorkspaceFileEntryDto(WireModel):
    name: str
    relative_path: str
    is_directory: bool


class WorkspaceFileContentDto(WireModel):
    content: str
    # SHA-256 (hex) of the exact bytes on disk, including any byte-order mark.
    # Clients echo it back as ``expectedVersion`` to detect concurrent changes.
    version: str


class WorkspaceFileVersionDto(WireModel):
    version: str
    size: int


class WriteWorkspaceFileRequest(WireModel):
    content: str | None = None
    # When present, the write only succeeds if the file on disk still has this
    # version. Omit it for an unconditional overwrite.
    expected_version: str | None = None


class MoveWorkspaceFileRequest(WireModel):
    source_root_index: int
    source_path: str
    destination_root_index: int
    destination_path: str


class ToolRegistryDto(WireModel):
    id: int
    uuid: str
    name: str
    alias: str | None = None
    description: str | None = None
    tool_type: str
    script_path: str | None = None
    script_language: str | None = None
    endpoint_url: str | None = None
    auth_type: str | None = None
    has_auth_config: bool = False
    command: str | None = None
    args: list[str] | None = None
    # Plain text by design: secrets belong in the encrypted api_key headers (HTTP MCP).
    env: dict[str, str] | None = None
    cwd: str | None = None
    # mcp only: "http" when endpointUrl is set, "stdio" when command is set.
    transport: str | None = None
    # acp only: "read_only" or "allow_all" (how the agent's own permission requests are answered).
    permissions: str | None = None
    # authType == "oauth" only: non-secret client settings and whether tokens are stored.
    oauth_client_id: str | None = None
    oauth_scopes: str | None = None
    oauth_connected: bool | None = None
    status: str
    created_at: datetime
    updated_at: datetime


class ToolTestEntryDto(WireModel):
    name: str
    description: str = ""
    operation: str


class ToolTestResultDto(WireModel):
    ok: bool
    tools: list[ToolTestEntryDto] = Field(default_factory=list)
    error: str | None = None
    needs_auth: bool = False


class SkillDto(WireModel):
    uuid: str
    name: str
    alias: str | None = None
    description: str | None = None
    source_type: str
    source: str | None = None
    instructions: str | None = None
    enabled: bool = True
    valid: bool = True
    error: str | None = None
    created_at: datetime
    updated_at: datetime


class UpsertSkillRequest(WireModel):
    name: str | None = None
    alias: str | None = None
    description: str | None = None
    source_type: str = "folder"
    source: str | None = None
    instructions: str | None = None
    enabled: bool = True


class UpsertToolRegistryRequest(WireModel):
    name: str | None = None
    alias: str | None = None
    description: str | None = None
    tool_type: str | None = None
    script_path: str | None = None
    script_language: str | None = None
    endpoint_url: str | None = None
    auth_type: str | None = None
    auth_config_json: str | None = None
    clear_auth_config: bool = False
    command: str | None = None
    args: list[str] | None = None
    env: dict[str, str] | None = None
    cwd: str | None = None
    status: str | None = None
    permissions: str | None = None
    # authType == "oauth": a pre-registered client (skips dynamic client registration).
    oauth_client_id: str | None = None
    # Write-only; stored encrypted and never returned.
    oauth_client_secret: str | None = None
    clear_oauth_client_secret: bool = False
    # Space separated scopes to request (optional; the server's metadata is used otherwise).
    oauth_scopes: str | None = None


class RagSearchRequest(WireModel):
    query: str = Field(min_length=1)
    mode: str = "hybrid"
    limit: int = Field(default=8, ge=1, le=50)


class RagIndexResponse(WireModel):
    roots: list[dict[str, Any]]


class BuiltinToolCatalogEntryDto(WireModel):
    name: str
    doc: str
    operation: str


class ToolCatalogDto(WireModel):
    builtin: dict[str, list[BuiltinToolCatalogEntryDto]]
    configured: list[ToolRegistryDto]
