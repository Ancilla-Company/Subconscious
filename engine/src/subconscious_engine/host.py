"""Composition root and Uvicorn lifecycle for the engine."""

import asyncio
from collections.abc import Callable
import errno
import ipaddress
import logging
import os
import socket
import sys
from urllib.parse import urlsplit

import uvicorn

from . import __version__
from .account import AccountServerClient, AccountSessionService
from .agents import AgentManager
from .api import create_app
from .auth import EngineAuthToken
from .capabilities import CapabilityResolver, RemoteCapabilitySource
from .background import BackgroundStatusIndicator, SystemTrayStatusIndicator
from .config import EngineConfig
from .configuration import EncryptedModelConfigurationStore
from .events import EventBus
from .graph_engine import GraphEngine
from .graphs import GraphKind, load_graph_schema
from .hive.service import HiveService
from .subconscious_loop import SubconsciousWorker
from .telemetry import TelemetryStore
from .tool_registry import PortableToolRegistry, ToolRegistryConfig
from .tools.subconscious_tools import SubconsciousToolset
from .runtime import RuntimeInfo, RuntimeInfoWriter
from .services.rag_service import WorkspaceRagService
from .storage import Database
from .tools import ToolRegistry
from .logging_setup import logged_suppress, spawn_logged

StatusIndicatorFactory = Callable[..., BackgroundStatusIndicator]

logger = logging.getLogger(__name__)

# EADDRINUSE on POSIX plus the Windows WSAEADDRINUSE code.
_ADDRESS_IN_USE_ERRORS = {errno.EADDRINUSE, 10048}
# Windows WSAEACCES: port is in a reserved range (or exclusively held).
_ADDRESS_BLOCKED_ERRORS = {errno.EACCES, 10013}


class EngineAlreadyRunningError(OSError):
    """Raised when the engine port is already bound by another process."""

    def __init__(self, port: int) -> None:
        super().__init__(f"Another Subconscious engine is already running on port {port}.")
        self.port = port


class EngineHost:
    DEVELOPMENT_PORT = 51515
    PRODUCTION_PORT = 51516
    DEVELOPMENT_TOKEN = "subconscious-dev-token"

    def __init__(
        self,
        config: EngineConfig,
        status_indicator_factory: StatusIndicatorFactory = SystemTrayStatusIndicator,
    ) -> None:
        self.config = config
        self.token = (
            EngineAuthToken(self.DEVELOPMENT_TOKEN)
            if config.dev
            else EngineAuthToken.generate()
        )
        self.database = Database(config.resolved_data_directory / "subconscious.db")
        self.model_configuration_store = EncryptedModelConfigurationStore(
            config.resolved_data_directory
        )
        self.event_bus = EventBus()
        self.tool_registry = ToolRegistry()
        self.rag_service = WorkspaceRagService(
            model_cache_directory=config.resolved_data_directory / "models"
        )
        self.agent_manager = AgentManager()
        self.telemetry = TelemetryStore(config.resolved_data_directory / "telemetry.db")
        registry_config, self.tool_registry_config_path = ToolRegistryConfig.load(
            config.resolved_data_directory
        )
        self.portable_tool_registry = PortableToolRegistry(registry_config)
        foreground_schema = load_graph_schema(
            GraphKind.FOREGROUND, config.resolved_conscious_graph
        )
        subconscious_schema = load_graph_schema(
            GraphKind.SUBCONSCIOUS, config.resolved_subconscious_graph
        )
        subconscious_toolset = SubconsciousToolset(
            config.resolved_data_directory, self.telemetry
        )

        async def subconscious_model():
            identifier = config.subconscious_model_id or os.getenv(
                "SUBCONSCIOUS_REFLECTION_MODEL"
            )
            if identifier:
                return await self.model_configuration_store.resolve(identifier)
            configured = await self.model_configuration_store.list()
            return (
                await self.model_configuration_store.resolve(configured[0].id)
                if configured
                else None
            )

        self.graph_engine = GraphEngine(
            self.telemetry,
            self.portable_tool_registry,
            foreground_schema,
            subconscious_schema,
            self.agent_manager,
            subconscious_model,
            subconscious_toolset.tools(),
            config.resolved_data_directory / "context",
        )
        self.subconscious_worker = (
            SubconsciousWorker(
                self.graph_engine,
                config.reflection_interval_seconds,
            )
            if config.subconscious_enabled
            else None
        )
        capabilities_url = config.capabilities_url or os.getenv("SUBCONSCIOUS_CAPABILITIES_URL")
        logger.info(
            "account server: %s",
            urlsplit(config.resolved_account_server_url).netloc,
        )
        self.account_session_service = AccountSessionService(
            AccountServerClient(config.resolved_account_server_url),
            credential_store=self.model_configuration_store,
        )
        self.app = create_app(
            self.database,
            self.token,
            self.model_configuration_store,
            self.event_bus,
            self.tool_registry,
            self.rag_service,
            self.agent_manager,
            self.graph_engine,
            self.subconscious_worker,
            self.account_session_service,
            remote_tools_config=config.hive.remote_tools,
            capability_resolver=CapabilityResolver(
                RemoteCapabilitySource(
                    capabilities_url,
                    token=config.capabilities_token
                    or os.getenv("SUBCONSCIOUS_CAPABILITIES_TOKEN"),
                )
                if capabilities_url
                else None
            ),
        )
        hive = config.hive
        self.hive_service = HiveService(
            account=self.account_session_service,
            credential_store=self.model_configuration_store,
            data_directory=config.resolved_data_directory,
            enabled=hive.enabled,
            server_url=hive.server_url,
            stun_servers=hive.stun_servers,
            node_name=hive.node_name,
            app_version=__version__,
            direct_timeout=hive.direct_timeout_seconds,
            relay_enabled=hive.relay_enabled,
            force_relay=hive.force_relay,
            auto_approve_account_devices=hive.auto_approve_account_devices,
        )
        self.app.state.hive_service = self.hive_service
        self.hive_service.attach(self.app)
        self._status_indicator_factory = status_indicator_factory
        self._status_indicator: BackgroundStatusIndicator | None = None
        self._server: uvicorn.Server | None = None
        self._listener: socket.socket | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._ready = asyncio.Event()
        self._stop_requested = False
        self._bound_port: int | None = None

    @property
    def bind_host(self) -> str:
        return "0.0.0.0" if self.config.lan_enabled else "127.0.0.1"

    @property
    def requested_port(self) -> int:
        if self.config.port is not None:
            return self.config.port
        return self.DEVELOPMENT_PORT if self.config.dev else self.PRODUCTION_PORT

    @property
    def bound_port(self) -> int:
        if self._bound_port is None:
            raise RuntimeError("The engine has not bound a port yet.")
        return self._bound_port

    @property
    def is_ready(self) -> bool:
        return self._ready.is_set()

    @property
    def address(self) -> str:
        host = self._lan_address() if self.config.lan_enabled else "127.0.0.1"
        return f"http://{host}:{self.bound_port}/api/v1/"

    @property
    def local_address(self) -> str:
        return f"http://localhost:{self.bound_port}/api/v1/"

    async def wait_until_ready(self, timeout: float = 10.0) -> None:
        await asyncio.wait_for(self._ready.wait(), timeout)

    def request_stop(self) -> None:
        """Request graceful shutdown; safe to call from a tray callback thread."""
        self._stop_requested = True
        loop = self._loop
        if loop is not None and loop.is_running():
            loop.call_soon_threadsafe(self._signal_stop)
        else:
            self._signal_stop()

    def _signal_stop(self) -> None:
        if self._server is not None:
            self._server.should_exit = True

    def _port_has_listener(self, port: int) -> bool:
        probe_host = "127.0.0.1" if self.bind_host in ("0.0.0.0", "") else self.bind_host
        try:
            with socket.create_connection((probe_host, port), timeout=0.5):
                return True
        except OSError as error:
            logger.debug("No listener on port %s: %s", port, error)
            return False

    async def serve(self) -> None:
        if self._listener is not None or self._server is not None:
            raise RuntimeError("The engine host is already running.")

        self._loop = asyncio.get_running_loop()
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_task: asyncio.Task[None] | None = None
        unsubscribe_clients: Callable[[], None] | None = None
        runtime_written = False
        try:
            if sys.platform == "win32":
                # SO_REUSEADDR lets two engines share a port on Windows.
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            else:
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                listener.bind((self.bind_host, self.requested_port))
            except OSError as error:
                codes = {error.errno, getattr(error, "winerror", None)}
                if codes & _ADDRESS_IN_USE_ERRORS:
                    raise EngineAlreadyRunningError(self.requested_port) from error
                if self.requested_port and codes & _ADDRESS_BLOCKED_ERRORS:
                    # Windows refuses binds inside reserved port ranges (Hyper-V,
                    # WSL, Docker) with WSAEACCES. With SO_EXCLUSIVEADDRUSE the same
                    # code can mean a live listener, so probe before falling back.
                    if self._port_has_listener(self.requested_port):
                        raise EngineAlreadyRunningError(self.requested_port) from error
                    logger.warning(
                        "Port %s is blocked or reserved by the OS (%s); falling back to an available port.",
                        self.requested_port,
                        error,
                    )
                    listener.close()
                    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    if sys.platform == "win32":
                        listener.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
                    listener.bind((self.bind_host, 0))
                    logger.warning("Engine fell back to port %s.", listener.getsockname()[1])
                else:
                    raise
            listener.listen(2048)
            self._listener = listener
            self._bound_port = int(listener.getsockname()[1])

            server = uvicorn.Server(
                uvicorn.Config(
                    self.app,
                    log_level="debug" if self.config.dev else "info",
                    # Leave logger wiring to logging_setup so uvicorn lands in engine.log.
                    log_config=None,
                )
            )
            self._server = server
            if self._stop_requested:
                server.should_exit = True
            server_task = spawn_logged(server.serve(sockets=[listener]))
            await self._wait_for_start(server, server_task)

            runtime = RuntimeInfo(
                host="127.0.0.1",
                port=self.bound_port,
                token=self.token.value,
                pid=os.getpid(),
                version=__version__,
                node_id=self.config.node_id,
            )
            RuntimeInfoWriter.write(self.config.resolved_data_directory, runtime)
            runtime_written = True
            if self.config.lan_enabled:
                logger.info("LAN joining token: %s", self.token.value)
            if not self.config.headless:
                self._status_indicator = self._status_indicator_factory(
                    self.address,
                    local_address=self.local_address,
                    lan_enabled=self.config.lan_enabled,
                    dev=self.config.dev,
                )
                unsubscribe_clients = self.app.state.client_registry.subscribe(
                    self._status_indicator.set_clients
                )
                self._status_indicator.start(self.request_stop, self.token.value)
            self._ready.set()
            # Resume an existing account session and start the hive only if the
            # user is signed in; failures never block the local engine.
            hive_startup = spawn_logged(self.hive_service.startup())
            try:
                await server_task
            finally:
                hive_startup.cancel()
                with logged_suppress(asyncio.CancelledError, Exception):
                    await hive_startup
        finally:
            with logged_suppress(Exception):
                await self.hive_service.shutdown()
            self._signal_stop()
            if server_task is not None and not server_task.done():
                with logged_suppress(asyncio.CancelledError):
                    await server_task
            if unsubscribe_clients is not None:
                unsubscribe_clients()
            if self._status_indicator is not None:
                self._status_indicator.stop()
                self._status_indicator = None
            if runtime_written:
                RuntimeInfoWriter.delete(
                    self.config.resolved_data_directory, expected_pid=os.getpid()
                )
            listener.close()
            self._ready.clear()
            self._listener = None
            self._server = None
            self._loop = None

    @staticmethod
    async def _wait_for_start(
        server: uvicorn.Server, server_task: asyncio.Task[None]
    ) -> None:
        while not server.started:
            if server_task.done():
                await server_task
                raise RuntimeError("The engine server stopped before becoming ready.")
            await asyncio.sleep(0.01)

    @staticmethod
    def _lan_address() -> str:
        candidates: set[str] = set()
        with logged_suppress(OSError):
            candidates.update(
                info[4][0]
                for info in socket.getaddrinfo(
                    socket.gethostname(), None, socket.AF_INET, socket.SOCK_STREAM
                )
            )
        for candidate in sorted(candidates):
            address = ipaddress.ip_address(candidate)
            if not (
                address.is_loopback or address.is_link_local or address.is_unspecified
            ):
                return candidate
        return "127.0.0.1"
