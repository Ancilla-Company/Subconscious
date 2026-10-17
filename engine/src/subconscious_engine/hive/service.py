"""HiveService: owns the hive runtime for one signed-in account.

Started by ``EngineHost`` only while the account session is authenticated and
torn down on logout or account change. Wires identity, directory, signalling,
peers, sessions and the REST tunnel together.
"""

from __future__ import annotations

import asyncio
import logging
import platform as platform_module
import time
from collections import deque
from pathlib import Path
from typing import Any

from subconscious_engine.account import AccountError, AccountSessionService, AccountUser
from subconscious_engine.configuration import EncryptedModelConfigurationStore

from . import PROTOCOL_VERSION
from .directory import Directory, HiveApi, HiveApiError, PinStore
from .errors import HiveError
from .identity import (
    IdentityError,
    NodeIdentity,
    approval_message,
    default_identity_store,
    load_or_create_identity,
    register_message,
    short_authentication_string,
    verify_signature,
    IdentitySeedStore,
)
from .node import HiveNode
from .peers import DEFAULT_DIRECT_TIMEOUT, PeerManager
from .signaling import SignalingClient
from ..logging_setup import logged_suppress, spawn_logged
_LOG = logging.getLogger(__name__)

_LOGGER = logging.getLogger("uvicorn.error")
DIRECTORY_POLL_SECONDS = 15.0
REFRESH_DEBOUNCE_SECONDS = 1.0
AUTO_APPROVE_LIMIT = 5
AUTO_APPROVE_WINDOW_SECONDS = 60.0
AUTO_APPROVE_KINDS = frozenset({"thin", "engine"})


class HiveService:
    def __init__(
        self,
        *,
        account: AccountSessionService,
        credential_store: EncryptedModelConfigurationStore,
        data_directory: Path,
        enabled: bool = True,
        server_url: str | None = None,
        stun_servers: tuple[str, ...] = (),
        node_name: str | None = None,
        app_version: str = "0",
        identity_store: IdentitySeedStore | None = None,
        api: HiveApi | None = None,
        direct_timeout: float = DEFAULT_DIRECT_TIMEOUT,
        relay_enabled: bool = True,
        force_relay: bool = False,
        auto_approve_account_devices: bool = True,
    ) -> None:
        self._account = account
        self._data_directory = data_directory
        self._enabled = enabled
        self._server_url = server_url
        self._stun = list(stun_servers)
        self._node_name = node_name or platform_module.node() or "engine"
        self._app_version = app_version
        self._identity_store = identity_store or default_identity_store(credential_store)
        self._api_override = api
        self._direct_timeout = direct_timeout
        self._relay_enabled = relay_enabled
        self._force_relay = force_relay
        self._auto_approve = auto_approve_account_devices
        self._auto_approvals: deque[float] = deque()
        self.app: Any = None
        self.state = "stopped"
        self.detail = ""
        self.identity: NodeIdentity | None = None
        self.directory: Directory | None = None
        self.api: HiveApi | None = None
        self.signaling: SignalingClient | None = None
        self.peers: PeerManager | None = None
        self._user: AccountUser | None = None
        self.node: HiveNode | None = None
        self._online: dict[str, bool] = {}
        self._main: asyncio.Task[None] | None = None
        self._refresh_task: asyncio.Task[None] | None = None
        self._lock = asyncio.Lock()
        self._unsubscribe: Any = None
        self._unsubscribe_clients: Any = None
        self._clients: tuple[str, ...] = ()
        self._pending_apply: asyncio.Task[None] | None = None

    # --- lifecycle ----------------------------------------------------------
    def attach(self, app: Any) -> None:
        """Bind to the Starlette app and follow the account session."""
        self.app = app
        if self._unsubscribe is None:
            self._unsubscribe = self._account.subscribe(self._on_account_changed)

    async def startup(self) -> None:
        """Try to resume an existing account session; failures are not fatal."""
        if not self._enabled:
            return
        with logged_suppress(AccountError):
            await self._account.restore()
        if self._pending_apply is not None:
            with logged_suppress(Exception):
                await self._pending_apply
        user = self._account.current_account_user
        if user is not None and self.state == "stopped":
            await self._apply(user)

    async def shutdown(self) -> None:
        if self._unsubscribe is not None:
            self._unsubscribe()
            self._unsubscribe = None
        if self._pending_apply is not None:
            self._pending_apply.cancel()
            with logged_suppress(asyncio.CancelledError, Exception):
                await self._pending_apply
        await self.stop()

    def _on_account_changed(self, user: AccountUser | None) -> None:
        if not self._enabled:
            return
        self._pending_apply = spawn_logged(self._apply(user))

    async def _apply(self, user: AccountUser | None) -> None:
        async with self._lock:
            await self._stop_locked()
            if user is not None:
                await self._start_locked(user)

    async def stop(self) -> None:
        async with self._lock:
            await self._stop_locked()

    async def _start_locked(self, user: AccountUser) -> None:
        self._user = user
        try:
            self.identity = load_or_create_identity(self._identity_store)
        except IdentityError as error:
            _LOG.warning("hive.service.HiveService._start_locked: handled IdentityError; continuing with fallback", exc_info=True)
            self.state, self.detail = "error", str(error)
            return
        base = self._server_url or self._account.server_base_url
        self.api = self._api_override or HiveApi(
            base, self._account.access_token, self._account.refresh_access_token
        )
        pins = PinStore(self._data_directory / "hive" / f"pins-{user.id}.json")
        self.directory = Directory(user.id, self.identity.node_id, pins)
        self.state, self.detail = "starting", ""
        self._main = spawn_logged(self._run())

    async def _stop_locked(self) -> None:
        main, self._main = self._main, None
        if main is not None:
            main.cancel()
            with logged_suppress(asyncio.CancelledError, Exception):
                await main
        await self._teardown_network()
        if self.api is not None and self._api_override is None:
            with logged_suppress(Exception):
                await self.api.close()
        self.api = None
        self.directory = None
        self.identity = None
        self._user = None
        self._online.clear()
        self.state, self.detail = "stopped", ""

    async def _teardown_network(self) -> None:
        if self._unsubscribe_clients is not None:
            self._unsubscribe_clients()
            self._unsubscribe_clients = None
        refresh, self._refresh_task = self._refresh_task, None
        if refresh is not None:
            refresh.cancel()
            with logged_suppress(asyncio.CancelledError, Exception):
                await refresh
        if self.signaling is not None:
            await self.signaling.stop()
            self.signaling = None
        if self.peers is not None:
            await self.peers.close()
            self.peers = None
        node, self.node = self.node, None
        if node is not None:
            await node.stop()

    # --- main loop ------------------------------------------------------------
    async def _run(self) -> None:
        assert self.api and self.directory and self.identity
        try:
            while True:
                await self._refresh_directory()
                nodes = self.directory.nodes
                local = self.directory.get(self.identity.node_id)
                if local is None:
                    if nodes:
                        self.state, self.detail = "unenrolled", "Run 'subconscious node enroll'."
                    else:
                        await self.enroll(None)  # first node of the account
                        continue
                elif not self.directory.is_trusted(local.id):
                    self.state, self.detail = "pending", "Waiting for approval from another node."
                else:
                    await self._connect_network()
                    if self._auto_approve and self.state == "running":
                        await self._auto_approve_loop()
                    return
                await asyncio.sleep(DIRECTORY_POLL_SECONDS)
        except asyncio.CancelledError:
            raise
        except (HiveApiError, AccountError) as error:
            self.state = "error"
            self.detail = getattr(error, "message", "Hive unavailable.")
            _LOGGER.info("Hive unavailable: %s", self.detail)
        except Exception:
            self.state, self.detail = "error", "Hive failed to start."
            _LOGGER.warning("Hive failed to start.", exc_info=True)

    async def _connect_network(self) -> None:
        assert self.api and self.directory and self.identity
        identity, directory, api = self.identity, self.directory, self.api
        node: HiveNode | None = None
        if self.app is not None and getattr(self.app.state, "sync_engine", None) is not None:
            node = HiveNode(self.app, identity, directory)
            self.node = node
            if not await node.start(directory.hive_id or ""):
                # This data directory already belongs to another hive: never merge histories.
                self.state = "hive_mismatch"
                self.detail = (
                    "This data directory belongs to a different hive. Start with a fresh data "
                    "directory, or run 'subconscious hive reset-local --confirm' to wipe local hive data."
                )
                return
        self.signaling = SignalingClient(api, identity)
        ice_cache: dict[str, Any] = {}

        async def ice() -> dict[str, Any]:
            if not ice_cache:
                ice_cache.update(await api.ice_config(identity.node_id))
                asyncio.get_running_loop().call_later(
                    max(30.0, min(float(ice_cache.get("ttl", 300)) / 2, 1800.0)), ice_cache.clear
                )
            return dict(ice_cache)

        self.peers = PeerManager(
            identity,
            directory,
            self.signaling,
            ice,
            on_link=node.on_link if node else None,
            on_link_closed=node.on_link_closed if node else None,
            stun_override=self._stun,
            direct_timeout=self._direct_timeout,
            relay_sender=self.signaling,
            relay_enabled=self._relay_enabled,
            force_relay=self._force_relay,
        )
        if node is not None:
            node.peers = self.peers
        self.signaling.on("signal", self.peers.handle_signal)
        self.signaling.on("relay", self.peers.handle_relay)
        self.signaling.on("presence.snapshot", self._on_presence)
        self.signaling.on("presence.update", self._on_presence)
        self.signaling.start()
        registry = getattr(getattr(self.app, "state", None), "client_registry", None)
        if registry is not None:
            self._unsubscribe_clients = registry.subscribe(self._on_local_clients)
        self.state, self.detail = "running", ""

    # --- callbacks -------------------------------------------------------------
    def _on_local_clients(self, clients: tuple[str, ...]) -> None:
        self._clients = clients
        signaling = self.signaling
        if signaling is not None:
            spawn_logged(self._publish_presence(signaling, clients))

    async def capabilities(self) -> dict[str, Any]:
        """What this node advertises: it can run agents, and which model names it has.

        Names only. API keys and endpoints never leave the machine.
        """
        models: list[dict[str, str]] = []
        store = getattr(getattr(self.app, "state", None), "model_configuration_store", None)
        if store is not None:
            with logged_suppress(Exception):
                for item in await store.list():
                    models.append({"id": item.id, "name": item.alias or item.model})
        return {"agents": True, "can_run_agents": True, "models": models, "protocol": PROTOCOL_VERSION}

    async def _publish_presence(self, signaling: SignalingClient, clients: tuple[str, ...]) -> None:
        with logged_suppress(Exception):
            await signaling.set_presence(list(clients), await self.capabilities())

    async def _on_presence(self, data: dict[str, Any]) -> None:
        entries = data.get("nodes")
        entries = entries if isinstance(entries, list) else [data]
        unknown = False
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("node_id"), str):
                continue
            node_id, online = entry["node_id"], entry.get("online") is True
            self._online[node_id] = online
            if self.directory is not None and self.directory.get(node_id) is None:
                unknown = True
            if self.peers is not None:
                await self.peers.on_presence(node_id, online)
        if unknown or "nodes" not in data:
            self._schedule_refresh()

    def _schedule_refresh(self) -> None:
        if self._refresh_task is None or self._refresh_task.done():
            self._refresh_task = spawn_logged(self._debounced_refresh())

    async def _debounced_refresh(self) -> None:
        await asyncio.sleep(REFRESH_DEBOUNCE_SECONDS)
        try:
            await self._refresh_directory()
        except (HiveApiError, AccountError):
            _LOG.warning("hive.service.HiveService._debounced_refresh: handled (HiveApiError, AccountError); continuing with fallback", exc_info=True)
            return
        with logged_suppress(HiveError, HiveApiError, AccountError):
            await self._auto_approve_pending()
        peers, directory = self.peers, self.directory
        if peers is None or directory is None:
            return
        runtimes = self.node.runtimes if self.node is not None else {}
        for node_id in list(peers.links) + [n for n in runtimes if n not in peers.links]:
            if not directory.is_trusted(node_id):
                await peers.close_peer(node_id)
        for node_id, online in list(self._online.items()):
            if online:
                await peers.on_presence(node_id, True)

    # --- directory + commands ---------------------------------------------------
    async def _refresh_directory(self) -> None:
        assert self.api and self.directory
        listing = await self.api.list_nodes()
        raw = listing.get("nodes")
        hive_id = listing.get("hive_id")
        self.directory.update(
            raw if isinstance(raw, list) else [],
            hive_id if isinstance(hive_id, str) else None,
        )

    def _require_running(self) -> tuple[HiveApi, Directory, NodeIdentity, AccountUser]:
        if not (self.api and self.directory and self.identity and self._user):
            raise HiveError("Sign in to use the hive.", 409)
        return self.api, self.directory, self.identity, self._user

    async def refresh(self) -> None:
        """Re-read the server's node list (best effort).

        A node that just enrolled is ``pending`` and not on the signalling socket, so no
        presence frame ever tells the others about it; listing and approving must ask.
        """
        if self.api is None or self.directory is None:
            return
        with logged_suppress(HiveApiError, AccountError):
            await self._refresh_directory()
            await self._auto_approve_pending()

    async def enroll(self, invite_code: str | None) -> dict[str, Any]:
        api, directory, identity, user = self._require_running()
        body: dict[str, Any] = {
            "kind": "engine",
            "name": self._node_name,
            "platform": platform_module.system().lower() or "unknown",
            "app_version": self._app_version,
            "protocol_version": PROTOCOL_VERSION,
            "public_key": identity.public_key_b64u,
            "proof": identity.sign(register_message(user.id, identity.public_key_b64u)),
            "capabilities": {"agents": True},
        }
        if invite_code:
            body["invite_code"] = invite_code.strip()
        try:
            await api.register(body)
        except HiveApiError as error:
            if error.status_code != 409:  # already registered is fine
                raise HiveError(error.message, error.status_code) from error
        await self._refresh_directory()
        return self.snapshot()

    async def create_invite(self) -> dict[str, Any]:
        api, directory, identity, _ = self._require_running()
        if not directory.is_trusted(identity.node_id):
            raise HiveError("Only an approved node can create invites.", 403)
        try:
            return await api.create_invite(identity.node_id)
        except HiveApiError as error:
            raise HiveError(error.message, error.status_code) from error

    def sas_for(self, node_id: str) -> str | None:
        if not (self.directory and self.identity):
            return None
        node = self.directory.get(node_id)
        return (
            short_authentication_string(self.identity.public_key, node.public_key)
            if node is not None
            else None
        )

    async def approve(self, node_id: str, sas: str) -> None:
        api, directory, identity, user = self._require_running()
        if not directory.is_trusted(identity.node_id):
            raise HiveError("Only an approved node can approve others.", 403)
        if directory.get(node_id) is None:
            await self.refresh()  # the pending node may have enrolled after our last listing
        node = directory.get(node_id)
        if node is None or node.status != "pending":
            raise HiveError("That node is not waiting for approval.", 404)
        if sas.strip() != self.sas_for(node_id):
            raise HiveError("The short authentication code does not match.", 400)
        await self._approve_verified(node_id)

    async def _approve_verified(self, node_id: str) -> None:
        """Sign and submit an approval. Callers must already have verified the node."""
        api, directory, identity, user = self._require_running()
        node = directory.get(node_id)
        if node is None:
            raise HiveError("That node is not waiting for approval.", 404)
        signature = identity.sign(approval_message(user.id, node.public_key_b64u))
        try:
            await api.approve(node_id, identity.node_id, signature)
            await self._refresh_directory()
        except HiveApiError as error:
            raise HiveError(error.message, error.status_code) from error

    async def _auto_approve_loop(self) -> None:
        while True:
            await asyncio.sleep(DIRECTORY_POLL_SECONDS)
            try:
                await self._refresh_directory()
                await self._auto_approve_pending()
            except (HiveApiError, AccountError, HiveError):
                _LOG.warning("hive.service.HiveService._auto_approve_loop: handled; will retry", exc_info=True)

    def _node_passes_ownership(self, node: Any, user_id: str) -> bool:
        if node.kind not in AUTO_APPROVE_KINDS or not node.platform:
            return False
        if node.protocol_version != PROTOCOL_VERSION:
            return False
        # The server lists only nodes registered under this account; when it also
        # returns the registration proof, re-verify it so the server cannot inject a key.
        if node.proof is not None and not verify_signature(
            node.public_key, node.proof, register_message(user_id, node.public_key_b64u)
        ):
            return False
        return True

    async def _auto_approve_pending(self) -> int:
        """Approve pending nodes of the signed-in account without a short code.

        Signing in is the proof of ownership. Only a trusted node does this, only
        while the account is unchanged, and at most AUTO_APPROVE_LIMIT per window.
        """
        if not self._auto_approve:
            return 0
        if not (self.api and self.directory and self.identity and self._user):
            return 0
        directory, identity, user = self.directory, self.identity, self._user
        current = self._account.current_account_user
        if current is None or current.id != user.id or directory.user_id != user.id:
            return 0
        if not directory.is_trusted(identity.node_id):
            return 0
        approved = 0
        for node in directory.nodes:
            if node.status != "pending" or node.id == identity.node_id:
                continue
            if not self._node_passes_ownership(node, user.id):
                _LOG.warning("hive auto-approve skipped node %s: ownership checks failed", node.id)
                continue
            now = time.monotonic()
            while self._auto_approvals and now - self._auto_approvals[0] > AUTO_APPROVE_WINDOW_SECONDS:
                self._auto_approvals.popleft()
            if len(self._auto_approvals) >= AUTO_APPROVE_LIMIT:
                _LOG.warning("hive auto-approve rate limit reached; deferring %s", node.id)
                break
            self._auto_approvals.append(now)
            await self._approve_verified(node.id)
            _LOGGER.info("Hive auto-approved account device node_id=%s name=%s", node.id, node.name)
            approved += 1
        return approved

    async def revoke(self, node_id: str) -> None:
        api, directory, identity, _ = self._require_running()
        if directory.get(node_id) is None:
            raise HiveError("Unknown node.", 404)
        try:
            await api.revoke(node_id)
            await self._refresh_directory()
        except HiveApiError as error:
            raise HiveError(error.message, error.status_code) from error
        if self.peers is not None:
            await self.peers.close_peer(node_id)

    # --- reporting --------------------------------------------------------------
    def snapshot(self) -> dict[str, Any]:
        directory, identity, peers = self.directory, self.identity, self.peers
        nodes: list[dict[str, Any]] = []
        if directory is not None and identity is not None:
            for node in directory.nodes:
                link = peers.link(node.id) if peers else None
                nodes.append(
                    {
                        "id": node.id,
                        "name": node.name,
                        "kind": node.kind,
                        "platform": node.platform,
                        "status": node.status,
                        "trusted": directory.is_trusted(node.id),
                        "local": node.id == identity.node_id,
                        "online": self._online.get(node.id, node.online),
                        "connection": peers.state_of(node.id) if peers else "disconnected",
                        "tier": link.tier if link else None,
                        "sas": None
                        if node.id == identity.node_id
                        else short_authentication_string(identity.public_key, node.public_key),
                    }
                )
        return {
            "enabled": self._enabled,
            "state": self.state,
            "detail": self.detail,
            "autoApprove": self._auto_approve,
            "node_id": identity.node_id if identity else None,
            "hive_id": directory.hive_id if directory else None,
            "nodes": nodes,
        }
