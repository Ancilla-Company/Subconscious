"""Pydantic REST contracts matching the .NET DTOs."""

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field
from pydantic.alias_generators import to_camel


class WireModel(BaseModel):
    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True, serialize_by_alias=True)


class WorkspaceDto(WireModel):
    id: int
    uuid: str
    name: str
    description: str | None = None
    default_model_id: str | None = None
    tools_config: str | None = None
    directories: str | None = None
    approval_config: str | None = None
    rag_config: str | None = None
    created_at: datetime
    updated_at: datetime


class CreateWorkspaceRequest(WireModel):
    name: str = Field(min_length=1)
    description: str | None = None
    default_model_id: str | None = None
    tools_config: str | None = None
    directories: str | None = None
    approval_config: str | None = None
    rag_config: str | None = None


class ThreadDto(WireModel):
    id: int
    uuid: str
    workspace_uuid: str
    title: str | None = None
    description: str | None = None
    default_model_id: str | None = None
    tools_config: str | None = None
    created_at: datetime
    updated_at: datetime


class CreateThreadRequest(WireModel):
    workspace_uuid: str
    title: str | None = None
    description: str | None = None
    default_model_id: str | None = None
    tools_config: str | None = None


class UpdateThreadRequest(WireModel):
    title: str | None = None
    description: str | None = None
    default_model_id: str | None = None
    tools_config: str | None = None


class MessageDto(WireModel):
    uuid: str
    thread_uuid: str
    role: Literal["user", "assistant", "system", "tool"]
    content: str
    created_at: datetime


class SendMessageRequest(WireModel):
    thread_uuid: str
    role: Literal["user", "assistant", "system", "tool"]
    content: str
