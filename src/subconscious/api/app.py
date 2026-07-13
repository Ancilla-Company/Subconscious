""" Local engine API — FastAPI app factory.

    Exposes a loopback-only REST + WebSocket surface over a running ``Engine``
    All local clients use a single subconscious daemon on desktop
"""
from __future__ import annotations

import asyncio
import logging
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from typing import Optional, AsyncIterator, TYPE_CHECKING
from fastapi import FastAPI, Depends, HTTPException, Header, WebSocket, WebSocketDisconnect, status

from ..constants import VERSION
from ..db.models import Workspace, Thread, Message
from .schemas import (
  ThreadDTO,
  MessageDTO,
  WorkspaceDTO,
  HealthResponse,
  ModelConfigDTO,
  CreateThreadRequest,
  UpdateThreadRequest,
)

if TYPE_CHECKING:
  from ..engine import Engine


# Loggin and env setup
API_PREFIX = "/api/v1"
logger = logging.getLogger("subconscious")

# Keep these in sync with the formats configured in cli/__init__.py so the
# uvicorn/FastAPI logs read identically to the rest of the application.
_DEV_LOG_FORMAT = "[%(levelname)s|%(asctime)s.%(msecs)04d|%(filename)s|%(lineno)d] %(message)s"
_LOG_FORMAT = "[%(asctime)s] %(message)s"
_LOG_DATEFMT = "%Y-%m-%d %H:%M:%S"


def build_uvicorn_log_config(dev: bool = False) -> dict:
  """ Return a uvicorn ``log_config`` (dictConfig) that matches the CLI format.

      Mirrors the formatters set up in ``cli.__init__.main``: the verbose
      level/file/line layout in dev mode, and the terse timestamped layout
      otherwise. ``disable_existing_loggers`` is False so the app's own
      ``subconscious`` logger keeps working.
  """
  fmt = _DEV_LOG_FORMAT if dev else _LOG_FORMAT
  return {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
      "default": {"format": fmt, "datefmt": _LOG_DATEFMT},
      "access": {"format": fmt, "datefmt": _LOG_DATEFMT},
    },
    "handlers": {
      "default": {
        "class": "logging.StreamHandler",
        "formatter": "default",
        "stream": "ext://sys.stderr",
      },
      "access": {
        "class": "logging.StreamHandler",
        "formatter": "access",
        "stream": "ext://sys.stdout",
      },
    },
    "loggers": {
      "uvicorn": {"handlers": ["default"], "level": "INFO", "propagate": False},
      "uvicorn.error": {"level": "INFO"},
      "uvicorn.access": {"handlers": ["access"], "level": "INFO", "propagate": False},
    },
  }


def create_app(engine: Engine, token: str) -> FastAPI:
  app = FastAPI(
    title="Subconscious Engine API",
    description="Local loopback API for Subconscious clients.",
    version=VERSION.lstrip("v"),
    docs_url=None,
    redoc_url=None,
  )
  app.state.token = token
  app.state.engine = engine

  def require_token(authorization: Optional[str] = Header(default=None)) -> None:
    """ Auth """
    expected = f"Bearer {token}"
    if authorization != expected:
      raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid or missing token")

  async def get_db() -> AsyncIterator[AsyncSession]:
    """ Request-scoped database session dependency.

        Yields a single session for the lifetime of the request and closes it
        afterwards. Endpoints are still responsible for calling ``commit()`` on
        writes — the dependency only manages the session lifecycle.
    """
    async with engine.db.get_session() as session:
      yield session

  ###############################################################
  # Helpers
  ###############################################################
  async def _thread_by_uuid(session, thread_uuid: str) -> Thread:
    th = await session.scalar(select(Thread).where(Thread.uuid == thread_uuid))
    if not th:
      raise HTTPException(status.HTTP_404_NOT_FOUND, "Thread not found")
    return th

  async def _workspace_by_uuid(session, workspace_uuid: str) -> Workspace:
    ws = await session.scalar(select(Workspace).where(Workspace.uuid == workspace_uuid))
    if not ws:
      raise HTTPException(status.HTTP_404_NOT_FOUND, "Workspace not found")
    return ws

  ###############################################################
  # API Endpoints
  ###############################################################
  @app.get(f"{API_PREFIX}/health", response_model=HealthResponse)
  async def health() -> HealthResponse:
    return HealthResponse(version=VERSION, node_id=getattr(engine.config, "node_id", None))

  @app.get(f"{API_PREFIX}/models", response_model=list[ModelConfigDTO], dependencies=[Depends(require_token)])
  async def list_models() -> list[ModelConfigDTO]:
    """ List configured models. The API key is never returned.

        The first configured model is flagged ``is_default`` — it's the one used
        when a chat.send frame omits ``model_id`` (mirrors the UI behaviour).
    """
    cfgs = engine.agent_manager.list_model_cfgs()
    return [
      ModelConfigDTO(
        id=c["id"],
        provider=c.get("provider"),
        model=c.get("model"),
        system_prompt=c.get("system_prompt"),
        base_url=c.get("base_url"),
        is_default=(i == 0),
      )
      for i, c in enumerate(cfgs)
    ]

  @app.get(f"{API_PREFIX}/workspaces", response_model=list[WorkspaceDTO], dependencies=[Depends(require_token)])
  async def list_workspaces(session: AsyncSession = Depends(get_db)) -> list[WorkspaceDTO]:
    rows = (await session.scalars(select(Workspace).order_by(Workspace.created_at))).all()
    return [
      WorkspaceDTO(
        uuid=w.uuid, name=w.name, description=w.description,
        created_at=w.created_at, updated_at=w.updated_at,
      )
      for w in rows
    ]

  @app.get(
    f"{API_PREFIX}/workspaces/{{workspace_uuid}}/threads",
    response_model=list[ThreadDTO], dependencies=[Depends(require_token)],
  )
  async def list_threads(workspace_uuid: str, session: AsyncSession = Depends(get_db)) -> list[ThreadDTO]:
    ws = await _workspace_by_uuid(session, workspace_uuid)
    rows = (
      await session.scalars(
        select(Thread).where(Thread.workspace_id == ws.id)
        .order_by(Thread.updated_at.desc())
      )
    ).all()
    return [
      ThreadDTO(
        uuid=t.uuid, workspace_uuid=workspace_uuid, title=t.title,
        description=t.description, default_model_id=t.default_model_id,
        created_at=t.created_at, updated_at=t.updated_at,
      )
      for t in rows
    ]

  @app.post(f"{API_PREFIX}/threads", response_model=ThreadDTO, dependencies=[Depends(require_token)])
  async def create_thread(req: CreateThreadRequest, session: AsyncSession = Depends(get_db)) -> ThreadDTO:
    """ Create thread """
    ws = await _workspace_by_uuid(session, req.workspace_uuid)
    workspace_id = ws.id
    thread = await engine.get_or_create_thread(
      content=req.title or "New Thread", workspace_id=workspace_id,
    )

    if req.title or req.description:
      th = await session.get(Thread, thread.id)
      if req.title:
        th.title = req.title
      if req.description:
        th.description = req.description
      await session.commit()

    return ThreadDTO(
      created_at=thread.created_at, updated_at=thread.updated_at,
      description=req.description, default_model_id=thread.default_model_id,
      uuid=thread.uuid, workspace_uuid=req.workspace_uuid, title=req.title or thread.title,
    )

  @app.patch(f"{API_PREFIX}/threads/{{thread_uuid}}", response_model=ThreadDTO, dependencies=[Depends(require_token)])
  async def update_thread(thread_uuid: str, req: UpdateThreadRequest, session: AsyncSession = Depends(get_db)) -> ThreadDTO:
    """ Update thread """
    th = await _thread_by_uuid(session, thread_uuid)
    if req.title is not None:
      th.title = req.title
    if req.description is not None:
      th.description = req.description
    if req.default_model_id is not None:
      th.default_model_id = req.default_model_id
    await session.commit()
    ws = await session.get(Workspace, th.workspace_id)
    dto = ThreadDTO(
      uuid=th.uuid, workspace_uuid=ws.uuid if ws else "", title=th.title,
      description=th.description, default_model_id=th.default_model_id,
      created_at=th.created_at, updated_at=th.updated_at,
    )
    await engine.events.publish({"type": "thread.updated", "data": dto.model_dump(mode="json")})
    return dto

  @app.get(f"{API_PREFIX}/threads/{{thread_uuid}}/messages", response_model=list[MessageDTO], dependencies=[Depends(require_token)])
  async def list_messages(thread_uuid: str, session: AsyncSession = Depends(get_db)) -> list[MessageDTO]:
    th = await _thread_by_uuid(session, thread_uuid)
    rows = (
      await session.scalars(
        select(Message).where(Message.thread_id == th.id).order_by(Message.created_at)
      )
    ).all()
    return [
      MessageDTO(
        uuid=m.uuid, thread_uuid=thread_uuid, role=m.role,
        content=m.content, created_at=m.created_at,
      )
      for m in rows
    ]

  @app.websocket(f"{API_PREFIX}/events")
  async def events_ws(ws: WebSocket) -> None:
    # Auth via query param (browsers/extensions can't set WS headers reliably).
    if ws.query_params.get("token") != token:
      await ws.close(code=status.WS_1008_POLICY_VIOLATION)
      return
    await ws.accept()
    queue = engine.events.subscribe()

    async def pump_events() -> None:
      """Forward engine events to this client."""
      while True:
        event = await queue.get()
        await ws.send_json({"v": 1, **event})

    async def pump_commands() -> None:
      """Handle commands sent by the client."""
      while True:
        frame = await ws.receive_json()
        if frame.get("type") == "chat.send":
          await _handle_chat_send(ws, engine, frame)

    pump_task = asyncio.create_task(pump_events())
    cmd_task = asyncio.create_task(pump_commands())
    try:
      await asyncio.wait({pump_task, cmd_task}, return_when=asyncio.FIRST_COMPLETED)
    except WebSocketDisconnect:
      pass
    finally:
      engine.events.unsubscribe(queue)
      for t in (pump_task, cmd_task):
        t.cancel()

  return app


async def _handle_chat_send(ws: WebSocket, engine: Engine, frame: dict) -> None:
  """ Persist the user message, stream the assistant reply as `chat.delta` frames,
      persist the assistant message, then emit `chat.done`. The `message.created`
      events for both messages are published by engine.save_message and reach all
      connected clients (including this one) via the event pump.
  """
  corr = frame.get("id")
  data = frame.get("data", {})
  thread_uuid = data.get("thread_uuid")
  content = (data.get("content") or "").strip()
  # Optional model config selection. When omitted, stream_chat falls back to the
  # engine's best/default model. A supplied-but-unknown id is an error.
  model_id = data.get("model_id")
  if not thread_uuid or not content:
    await ws.send_json({"v": 1, "type": "chat.error", "id": corr, "data": {"error": "thread_uuid and content required"}})
    return

  model_cfg = None
  if model_id:
    model_cfg = engine.agent_manager.get_model_cfg(model_id)
    if model_cfg is None:
      await ws.send_json({"v": 1, "type": "chat.error", "id": corr, "data": {"error": f"unknown model_id: {model_id}"}})
      return

  # Resolve uuids → local ids
  async with engine.db.get_session() as session:
    th = await session.scalar(select(Thread).where(Thread.uuid == thread_uuid))
    if not th:
      await ws.send_json({"v": 1, "type": "chat.error", "id": corr, "data": {"error": "thread not found"}})
      return
    thread_id, workspace_id = th.id, th.workspace_id

  await engine.save_message(thread_id, "user", content)

  reply_parts: list[str] = []
  try:
    async for chunk in engine.stream_chat(
      content, thread_id, workspace_id=workspace_id, model_cfg=model_cfg,
    ):
      reply_parts.append(chunk)
      await ws.send_json({"v": 1, "type": "chat.delta", "id": corr, "data": {"delta": chunk}})
  except Exception as exc:  # surface model/config errors to the client
    logger.exception("chat.send stream failed")
    await ws.send_json({"v": 1, "type": "chat.error", "id": corr, "data": {"error": str(exc)}})
    return

  full = "".join(reply_parts)
  if full:
    await engine.save_message(thread_id, "agent", full)
  await ws.send_json({"v": 1, "type": "chat.done", "id": corr, "data": {}})
