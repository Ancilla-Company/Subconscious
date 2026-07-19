""" Pydantic DTOs for the local engine API.
    These are the wire shapes exchanged with API clients
"""
from typing import Optional
from datetime import datetime
# from __future__ import annotations
from pydantic import BaseModel, Field


class WorkspaceDTO(BaseModel):
  uuid: str
  name: str
  description: Optional[str] = None
  created_at: Optional[datetime] = None
  updated_at: Optional[datetime] = None


class ThreadDTO(BaseModel):
  uuid: str
  workspace_uuid: str
  title: Optional[str] = None
  description: Optional[str] = None
  default_model_id: Optional[str] = None
  created_at: Optional[datetime] = None
  updated_at: Optional[datetime] = None


class MessageDTO(BaseModel):
  uuid: str
  thread_uuid: str
  role: str
  content: str
  created_at: Optional[datetime] = None


class CreateThreadRequest(BaseModel):
  workspace_uuid: str
  title: Optional[str] = None
  description: Optional[str] = None


class UpdateThreadRequest(BaseModel):
  title: Optional[str] = None
  description: Optional[str] = None
  default_model_id: Optional[str] = None


class WSFrame(BaseModel):
  """ Envelope for every WebSocket message in either direction. """
  v: int = 1
  type: str                      # e.g. "chat.send", "chat.delta", "message.created"
  id: Optional[str] = None       # client-supplied correlation id for request/response
  data: dict = Field(default_factory=dict)


class HealthResponse(BaseModel):
  status: str = "ok"
  version: str
  node_id: Optional[str] = None


class ModelConfigDTO(BaseModel):
  """ A configured model, safe for the wire (the API key is never included). """
  id: str
  alias: Optional[str] = None
  provider: Optional[str] = None
  model: Optional[str] = None
  system_prompt: Optional[str] = None
  base_url: Optional[str] = None
  is_default: bool = False
