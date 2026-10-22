"""Starlette application exposing the engine REST, SSE, and WebSocket surfaces."""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
import asyncio

from starlette.applications import Starlette
from starlette.datastructures import State
from starlette.middleware import Middleware
from starlette.middleware.cors import CORSMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route, WebSocketRoute

from subconscious_engine.account import (
    AccountServerClient,
    AccountSessionService,
    DEFAULT_ACCOUNT_SERVER_URL,
)
from subconscious_engine.agents import AgentManager
from subconscious_engine.audio import AudioServices, audio_routes
from subconscious_engine.capabilities import CapabilityResolver
from subconscious_engine.auth import BearerAuthMiddleware, EngineAuthToken
from subconscious_engine.pairing import PairedClientStore, PairingService, RateLimiter
from subconscious_engine.client_tools import ClientToolCatalog
from subconscious_engine.configuration import EncryptedModelConfigurationStore
from subconscious_engine.events import EventBus
from subconscious_engine.graph_engine import GraphEngine
from subconscious_engine.subconscious_loop import SubconsciousWorker
from subconscious_engine.services.configured_tools import ConfiguredToolRuntime
from subconscious_engine.services.oauth import OAuthBroker
from subconscious_engine.services.tool_management import ToolManagement
from subconscious_engine.services.rag_service import WorkspaceRagService
from subconscious_engine.storage import Database
from subconscious_engine.tools import ToolRegistry

from .account_routes import account_routes
from .event_routes import event_routes
from .file_routes import file_routes
from subconscious_engine.config import RemoteToolsConfig
from subconscious_engine.hive.remote_tools import RemoteToolService, RemoteToolset
from subconscious_engine.hive.sync.engine import SyncEngine
from subconscious_engine.hive.tasks import TaskManager

from .hive_routes import hive_routes
from .model_routes import model_routes
from .profile_routes import profile_routes
from .rag_routes import rag_routes
from .settings_routes import settings_routes
from .thread_routes import (
    create_message,
    create_thread,
    delete_thread,
    get_thread,
    list_messages,
    list_threads,
    update_thread,
)
from .oauth_routes import oauth_routes
from .pair_routes import pair_routes
from .skill_routes import skill_routes
from .tool_routes import tool_routes
from .websocket import ClientRegistry, websocket_endpoint
from .workspace_routes import (
    create_workspace,
    delete_workspace,
    get_workspace,
    list_workspaces,
    update_workspace,
)
from ..logging_setup import logged_suppress, spawn_logged


async def health(_: Request) -> JSONResponse:
    from subconscious_engine import __version__

    hive = getattr(_.app.state, "hive_service", None)
    identity = getattr(hive, "identity", None)
    return JSONResponse(
        {"status": "ok", "version": __version__, "node_id": getattr(identity, "node_id", None)}
    )


async def agui(_: Request) -> JSONResponse:
    return JSONResponse({"message": "AG-UI endpoint not yet implemented"})


def create_app(
    database: Database,
    token: EngineAuthToken,
    model_configuration_store: EncryptedModelConfigurationStore | None = None,
    event_bus: EventBus | None = None,
    tool_registry: ToolRegistry | None = None,
    rag_service: WorkspaceRagService | None = None,
    agent_manager: AgentManager | None = None,
    graph_engine: GraphEngine | None = None,
    subconscious_worker: SubconsciousWorker | None = None,
    account_session_service: AccountSessionService | None = None,
    remote_tools_config: RemoteToolsConfig | None = None,
    capability_resolver: CapabilityResolver | None = None,
    audio_services: AudioServices | None = None,
    dev_models: bool = False,
) -> Starlette:
    """Build the engine API. ``dev_models`` lists test-only models (Echo); dev engines only."""
    store = model_configuration_store or EncryptedModelConfigurationStore(
        database.path.parent
    )
    bus = event_bus or EventBus()
    builtins = tool_registry or ToolRegistry()
    account_service = account_session_service or AccountSessionService(
        AccountServerClient(DEFAULT_ACCOUNT_SERVER_URL),
        credential_store=store,
    )
    rag = rag_service or WorkspaceRagService(
        model_cache_directory=database.path.parent / "models"
    )
    agents = agent_manager or AgentManager()

    @asynccontextmanager
    async def lifespan(app: Starlette) -> AsyncIterator[None]:
        await database.initialize()
        # Work that was running when the engine last stopped did not finish.
        with logged_suppress(Exception):
            await app.state.task_manager.recover()
        if graph_engine is not None:
            await graph_engine.telemetry.initialize()
        scheduler = (
            spawn_logged(rag.run_daily_indexing(database))
            if isinstance(rag, WorkspaceRagService)
            else None
        )
        reflection_task = (
            spawn_logged(subconscious_worker.run())
            if subconscious_worker is not None
            else None
        )
        try:
            yield
        finally:
            for task in (reflection_task, scheduler):
                if task is not None:
                    task.cancel()
                    with logged_suppress(asyncio.CancelledError):
                        await task
            if graph_engine is not None:
                await graph_engine.telemetry.close()
            # Stop every MCP server process the chat runtime started.
            await app.state.configured_tools.close()
            await account_service.close()
            await database.close()

    routes = [
        Route("/api/v1/health", health),
        *account_routes(),
        *hive_routes(),
        *profile_routes(),
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
        *file_routes(),
        *settings_routes(),
        *model_routes(),
        *audio_routes(),
        *tool_routes(),
        *oauth_routes(),
        *pair_routes(),
        *skill_routes(),
        *rag_routes(),
        *event_routes(),
        WebSocketRoute("/api/v1/events", websocket_endpoint),
    ]
    paired_clients = PairedClientStore(database.path.parent / "paired_clients.json")
    client_registry = ClientRegistry()
    oauth_broker = OAuthBroker(event_bus=bus, client_registry=client_registry)
    configured_tools = ConfiguredToolRuntime(database, store, oauth_broker=oauth_broker)
    app = Starlette(
        routes=routes,
        middleware=[
            Middleware(
                CORSMiddleware,
                allow_origin_regex=r"^(https?://(?:localhost|127\.0\.0\.1)(?::\d+)?|chrome-extension://[a-p]{32}|moz-extension://[0-9a-f-]{36})$",
                allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
                allow_headers=["Authorization", "Content-Type"],
            ),
            Middleware(BearerAuthMiddleware, token=token, paired_clients=paired_clients),
        ],
        lifespan=lifespan,
    )
    app.state = State(
        {
            "database": database,
            "model_configuration_store": store,
            "capability_resolver": capability_resolver or CapabilityResolver(),
            "audio_services": audio_services or AudioServices(),
            "event_bus": bus,
            "tool_registry": builtins,
            "client_tool_catalog": ClientToolCatalog(),
            "oauth_broker": oauth_broker,
            "configured_tools": configured_tools,
            "tool_management": ToolManagement(database, store, configured_tools, oauth_broker),
            "rag_service": rag,
            "agent_manager": agents,
            "graph_engine": graph_engine,
            "subconscious_worker": subconscious_worker,
            "account_session_service": account_service,
            "client_registry": client_registry,
            "paired_clients": paired_clients,
            "pair_rate_limiter": RateLimiter(),
            "hive_service": None,
            "sync_engine": SyncEngine(database),
            "task_manager": TaskManager(app),
            "dev_models": dev_models,
        }
    )
    app.state.pairing_service = PairingService(
        account_service,
        lambda: getattr(getattr(app.state.hive_service, "identity", None), "node_id", None),
        paired_clients,
    )
    # Remote tools (webrtc.md section 8): both halves are inert until a peer asks or a
    # workspace/thread opts in, and the owner side exports nothing by default.
    app.state.remote_tools = RemoteToolService(
        app, remote_tools_config, database.path.parent / "hive" / "remote_tools.json"
    )
    app.state.remote_toolset = RemoteToolset(app)
    return app
