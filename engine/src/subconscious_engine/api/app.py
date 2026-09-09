"""Starlette application exposing the engine REST, SSE, and WebSocket surfaces."""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager, suppress
import asyncio

from starlette.applications import Starlette
from starlette.datastructures import State
from starlette.middleware import Middleware
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route, WebSocketRoute

from subconscious_engine.agents import AgentManager
from subconscious_engine.auth import BearerAuthMiddleware, EngineAuthToken
from subconscious_engine.configuration import EncryptedModelConfigurationStore
from subconscious_engine.events import EventBus
from subconscious_engine.services.rag_service import WorkspaceRagService
from subconscious_engine.storage import Database
from subconscious_engine.tools import ToolRegistry

from .event_routes import event_routes
from .file_routes import file_routes
from .model_routes import model_routes
from .rag_routes import rag_routes
from .settings_routes import settings_routes
from .thread_routes import (create_message, create_thread, delete_thread, get_thread,
                            list_messages, list_threads, update_thread)
from .tool_routes import tool_routes
from .websocket import ClientRegistry, websocket_endpoint
from .workspace_routes import (create_workspace, delete_workspace, get_workspace,
                               list_workspaces, update_workspace)


async def health(_: Request) -> JSONResponse:
    from subconscious_engine import __version__
    return JSONResponse({"status": "ok", "version": __version__})


async def agui(_: Request) -> JSONResponse:
    return JSONResponse({"message": "AG-UI endpoint not yet implemented"})


def create_app(database: Database, token: EngineAuthToken,
               model_configuration_store: EncryptedModelConfigurationStore | None = None,
               event_bus: EventBus | None = None, tool_registry: ToolRegistry | None = None,
               rag_service: WorkspaceRagService | None = None,
               agent_manager: AgentManager | None = None) -> Starlette:
    store = model_configuration_store or EncryptedModelConfigurationStore(database.path.parent)
    bus = event_bus or EventBus()
    builtins = tool_registry or ToolRegistry()
    rag = rag_service or WorkspaceRagService(
        model_cache_directory=database.path.parent / "models"
    )
    agents = agent_manager or AgentManager()

    @asynccontextmanager
    async def lifespan(_: Starlette) -> AsyncIterator[None]:
        await database.initialize()
        scheduler = asyncio.create_task(rag.run_daily_indexing(database)) \
            if isinstance(rag, WorkspaceRagService) else None
        try:
            yield
        finally:
            if scheduler is not None:
                scheduler.cancel()
                with suppress(asyncio.CancelledError):
                    await scheduler
            await database.close()

    routes = [
        Route("/api/v1/health", health),
        Route("/api/v1/workspaces", list_workspaces, methods=["GET"]),
        Route("/api/v1/workspaces", create_workspace, methods=["POST"]),
        Route("/api/v1/workspaces/{uuid}", get_workspace, methods=["GET"]),
        Route("/api/v1/workspaces/{uuid}", update_workspace, methods=["PUT"]),
        Route("/api/v1/workspaces/{uuid}", delete_workspace, methods=["DELETE"]),
        Route("/api/v1/workspaces/{uuid}/threads", list_threads, methods=["GET"]),
        Route("/api/v1/threads", create_thread, methods=["POST"]),
        Route("/api/v1/threads/{uuid}", get_thread, methods=["GET"]),
        Route("/api/v1/threads/{uuid}", update_thread, methods=["PUT"]),
        Route("/api/v1/threads/{uuid}", delete_thread, methods=["DELETE"]),
        Route("/api/v1/threads/{uuid}/messages", list_messages, methods=["GET"]),
        Route("/api/v1/messages", create_message, methods=["POST"]),
        Route("/api/v1/agui", agui, methods=["POST"]),
        *file_routes(), *settings_routes(), *model_routes(), *tool_routes(),
        *rag_routes(), *event_routes(),
        WebSocketRoute("/api/v1/events", websocket_endpoint),
    ]
    app = Starlette(
        routes=routes,
        middleware=[Middleware(BearerAuthMiddleware, token=token)],
        lifespan=lifespan,
    )
    app.state = State(
        {
            "database": database,
            "model_configuration_store": store,
            "event_bus": bus,
            "tool_registry": builtins,
            "rag_service": rag,
            "agent_manager": agents,
            "client_registry": ClientRegistry(),
        }
    )
    return app
