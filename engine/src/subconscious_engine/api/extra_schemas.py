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


class WorkspaceFilePreviewDto(WireModel):
    local_path: str
    media_type: str


class WriteWorkspaceFileRequest(WireModel):
    content: str | None = None


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
    status: str
    created_at: datetime
    updated_at: datetime


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
    status: str | None = None


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
