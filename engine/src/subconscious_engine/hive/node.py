"""HiveNode: the per-engine hive runtime that sits on top of authenticated links.

It owns the sync coordinator and the task manager wiring, and routes every
inbound envelope to the right layer. The service builds one per sign-in; tests
build one per in-memory engine.
"""

from __future__ import annotations

import asyncio
import logging
from contextlib import suppress
from typing import Any

from subconscious_engine.auth import PeerPrincipal

from .authz import HIVE_PEER, REMOTE_TOOL_FRAMES, authorize_frame, role_for_kind
from .channels import Envelope
from .directory import Directory
from .http_tunnel import HttpTunnel
from .identity import NodeIdentity
from .peers import PeerLink, PeerManager
from .session import PeerSession
from .sync.engine import SyncEngine
from .sync.protocol import SyncCoordinator
from .tasks import PEER_EVENT_FRAMES, HiveContext, TaskManager

_LOGGER = logging.getLogger("uvicorn.error")


class PeerRuntime:
    """Per-link chat session + REST tunnel, created when a link authenticates."""

    def __init__(self, app: Any, link: PeerLink, name: str) -> None:
        self.link = link
        self.session = PeerSession(app, link, name)
        self.tunnel = HttpTunnel(app, PeerPrincipal(link.node_id, link.role))
        self.tasks: set[asyncio.Task[Any]] = set()

    def rpc(self, envelope: Envelope) -> None:
        task = asyncio.ensure_future(self._rpc(envelope))
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)

    async def _rpc(self, envelope: Envelope) -> None:
        response = await self.tunnel.handle(envelope)
        with suppress(Exception):
            await self.link.send("rpc", response)

    async def stop(self) -> None:
        for task in list(self.tasks):
            task.cancel()
        await self.session.stop()
        await self.tunnel.aclose()


class HiveNode(HiveContext):
    def __init__(self, app: Any, identity: NodeIdentity, directory: Directory) -> None:
        self.app = app
        self.identity = identity
        self.directory = directory
        self.local_node_id = identity.node_id
        self.engine: SyncEngine = app.state.sync_engine
        self.tasks: TaskManager = app.state.task_manager
        self.coordinator = SyncCoordinator(self.engine, on_mismatch=self._on_mismatch)
        self.peers: PeerManager | None = None
        self.runtimes: dict[str, PeerRuntime] = {}
        self.mismatch: str | None = None
        self._background: set[asyncio.Task[Any]] = set()

    # --- lifecycle ----------------------------------------------------------------
    async def start(self, hive_id: str) -> bool:
        """Bind sync and tasks to the account's hive. ``False`` when this database belongs to another."""
        self.engine.resolve_origin = self.directory.trusted_node
        if not await self.engine.check_hive(hive_id):
            self.mismatch = "hive_mismatch"
            return False
        await self.engine.attach_identity(self.identity)
        if self.engine.blocked is not None:
            self.mismatch = self.engine.blocked
            return False
        self.tasks.bind(self)
        await self.tasks.recover()
        self.tasks.start()
        return True

    async def stop(self) -> None:
        self.coordinator.close()
        await self.tasks.stop()
        self.tasks.bind(HiveContext())
        self.engine.detach_identity()
        for runtime in list(self.runtimes.values()):
            await runtime.stop()
        self.runtimes.clear()

    def _on_mismatch(self, node_id: str) -> None:
        _LOGGER.warning("A peer belongs to a different hive; its link was closed.")

    # --- HiveContext ---------------------------------------------------------------
    def node_role(self, node_id: str) -> str | None:
        node = self.directory.trusted_node(node_id)
        return role_for_kind(node.kind) if node is not None else None

    def node_name(self, node_id: str) -> str | None:
        node = self.directory.trusted_node(node_id)
        return node.name if node is not None else None

    def link(self, node_id: str) -> PeerLink | None:
        return self.peers.link(node_id) if self.peers is not None else None

    def links(self) -> dict[str, PeerLink]:
        return self.peers.links if self.peers is not None else {}

    async def wait_synced(self, node_id: str, timeout: float = 10.0) -> bool:
        link = self.link(node_id)
        if link is None or link.role != HIVE_PEER:
            return True  # thin clients do not hold a replica, so there is nothing to wait for
        return await self.coordinator.wait_ready(node_id, timeout)

    # --- link callbacks ----------------------------------------------------------------
    def on_link(self, link: PeerLink) -> None:
        node = self.directory.get(link.node_id)
        runtime = PeerRuntime(self.app, link, node.name if node else "")
        previous = self.runtimes.pop(link.node_id, None)
        if previous is not None:
            self._spawn(previous.stop())
        self.runtimes[link.node_id] = runtime
        link.handler = self.route
        runtime.session.start()
        if link.role == HIVE_PEER:
            self.coordinator.on_link(link)
        self._spawn(self.tasks.on_link(link))

    def on_link_closed(self, node_id: str) -> None:
        runtime = self.runtimes.pop(node_id, None)
        if runtime is not None:
            self._spawn(runtime.stop())
        self.coordinator.on_link_closed(node_id)
        self.tasks.on_link_closed(node_id)
        self._remote_on_link_closed(node_id)

    def route(self, link: PeerLink, channel: str, envelope: Envelope) -> None:
        runtime = self.runtimes.get(link.node_id)
        if runtime is None or runtime.link is not link:
            return
        if channel == "rpc":
            runtime.rpc(envelope)
        elif channel == "sync":
            if link.role == HIVE_PEER:
                self.coordinator.on_frame(link, envelope)
        elif link.role == HIVE_PEER and envelope.type in PEER_EVENT_FRAMES:
            self._spawn(self.tasks.on_peer_frame(link, envelope))
        elif (
            channel == "control"
            and link.role == HIVE_PEER
            and authorize_frame(link.role, envelope.type)
            and envelope.type in REMOTE_TOOL_FRAMES
        ):
            self._route_remote_tool(link, envelope)
        elif channel in {"control", "events"}:
            runtime.session.feed(envelope)

    # --- remote tools (webrtc.md section 8) -----------------------------------------------
    def _route_remote_tool(self, link: PeerLink, envelope: Envelope) -> None:
        """Requests go to the owner side, results/lists to the executor side."""
        state = self.app.state
        if envelope.type in {"tool.list", "tool.call", "tool.cancel"}:
            service = getattr(state, "remote_tools", None)
            if service is not None:
                trusted = self.node_role(link.node_id) == HIVE_PEER  # revoked/unknown peers get nothing
                self._spawn(service.handle(link, envelope, trusted))
        else:
            toolset = getattr(state, "remote_toolset", None)
            if toolset is not None and self.node_role(link.node_id) == HIVE_PEER:
                toolset.on_frame(link, envelope)

    def _remote_on_link_closed(self, node_id: str) -> None:
        state = self.app.state
        toolset = getattr(state, "remote_toolset", None)
        if toolset is not None:
            toolset.on_link_closed(node_id)
        service = getattr(state, "remote_tools", None)
        if service is not None:
            service.on_link_closed(node_id)

    def _spawn(self, coro: Any) -> None:
        task = asyncio.ensure_future(coro)
        self._background.add(task)
        task.add_done_callback(self._background.discard)
        task.add_done_callback(_log_failure)


def _log_failure(task: "asyncio.Future[Any]") -> None:
    if not task.cancelled() and task.exception() is not None:
        _LOGGER.warning("A hive background task failed.", exc_info=task.exception())
