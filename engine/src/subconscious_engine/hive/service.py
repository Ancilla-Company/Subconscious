"""HiveService: owns the hive runtime for one signed-in account.

Started by ``EngineHost`` only while the account session is authenticated and
torn down on logout or account change. Wires identity, directory, signalling,
peers, sessions and the REST tunnel together.
"""

from __future__ import annotations

import asyncio
import logging
import platform as platform_module
import random
import time
from collections import deque
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import datetime
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
from .gui_clients import GuiClientStore
from .signaling import SignalingClient, backoff_delay
from ..logging_setup import logged_suppress, spawn_logged
_LOG = logging.getLogger(__name__)

_LOGGER = logging.getLogger("uvicorn.error")
DIRECTORY_POLL_SECONDS = 15.0
DIRECTORY_RECONCILE_SECONDS = 120.0
REFRESH_DEBOUNCE_SECONDS = 1.0
REFRESH_THROTTLE_SECONDS = 5.0
AUTO_APPROVE_LIMIT = 5
AUTO_APPROVE_WINDOW_SECONDS = 60.0
AUTO_APPROVE_MAX_ATTEMPTS = 2
AUTO_APPROVE_KINDS = frozenset({"thin", "engine"})
BOUNDED_RETRY_SECONDS = 60.0
MAX_BACKOFF_404 = 5
HIVE_MISMATCH_DETAIL = (
    "This data directory belongs to a different hive. Use 'Reset local hive data' to back up "
    "and clear the local hive bookkeeping (your threads and files are kept), then sign in again."
)


def _backup_sqlite(source: Path, target: Path) -> None:
    """Consistent copy of a (possibly open, WAL mode) SQLite database."""
    import sqlite3

    src = sqlite3.connect(str(source))
    try:
        dst = sqlite3.connect(str(target))
        try:
            src.backup(dst)
        finally:
            dst.close()
    finally:
        src.close()


def _seen_before(last_seen: Any, moment: float) -> bool:
    """True when ``last_seen`` (ISO text) is earlier than ``moment`` (epoch seconds)."""
    if not isinstance(last_seen, str):
        return False
    try:
        parsed = datetime.fromisoformat(last_seen.replace("Z", "+00:00"))
    except ValueError:
        _LOG.debug("Unparseable last_seen_at.", exc_info=True)
        return False
    return parsed.timestamp() < moment


def _session_is_dead(error: BaseException) -> bool:
    if isinstance(error, HiveApiError):
        return error.status_code == 401
    if isinstance(error, AccountError):
        return error.status_code in (401, 403)
    return False


@dataclass(frozen=True, slots=True)
class Verdict:
    action: str  # "retry" or "stop"
    delay: float
    state: str
    detail: str


def _status_of(error: BaseException) -> int | None:
    status = getattr(error, "status_code", None)
    return status if isinstance(status, int) else None


def classify_failure(
    error: BaseException,
    *,
    consecutive_404: int = 0,
    bounded_used: bool = False,
    attempt: int = 0,
    rng: Callable[[], float] = random.random,
) -> Verdict:
    """Pure retry policy for the supervisor (design 4.1). ``consecutive_404`` counts this failure."""
    if isinstance(error, asyncio.CancelledError):
        raise error
    backoff = backoff_delay(attempt, rng=rng)
    retry = Verdict("retry", backoff, "retrying", "Hive unavailable. Retrying.")
    if isinstance(error, IdentityError):
        return Verdict("stop", 0.0, "error", str(error))
    if isinstance(error, AccountError):
        if _status_of(error) in (401, 403):
            return Verdict("stop", 0.0, "signed_out", "Sign in again to link this engine")
        return retry
    if isinstance(error, (HiveApiError, HiveError)):
        status = _status_of(error) or 0
        if isinstance(error, HiveApiError) and not error.reachable:
            return retry
        if status in (0, 408, 429) or status >= 500:
            return retry
        if status == 401:
            return Verdict("stop", 0.0, "signed_out", "Sign in again to link this engine")
        if status == 404:
            if consecutive_404 <= MAX_BACKOFF_404:
                return retry
            return Verdict(
                "retry", BOUNDED_RETRY_SECONDS, "error", "The hive server returned status 404."
            )
        if status in (400, 403, 409, 422):
            message = getattr(error, "message", "") or "The hive server refused the request."
            if bounded_used:
                return Verdict("stop", 0.0, "error", message)
            return Verdict("retry", BOUNDED_RETRY_SECONDS, "error", message)
        return retry
    return retry


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
        keyring_namespace: str | None = None,
        api: HiveApi | None = None,
        direct_timeout: float = DEFAULT_DIRECT_TIMEOUT,
        relay_enabled: bool = True,
        force_relay: bool = False,
        auto_approve_account_devices: bool = True,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
        rng: Callable[[], float] = random.random,
    ) -> None:
        self._sleep = sleep
        self._rng = rng
        self._last_refresh = 0.0
        self._approve_attempts: dict[str, int] = {}
        self._gui_name: str | None = None
        self._gui_client_id: str | None = None
        self._parented: set[str] = set()
        self._warned_messages: set[str] = set()
        self._gui_store = GuiClientStore(data_directory / "hive" / "gui-clients.json")
        self._account = account
        self._data_directory = data_directory
        self._enabled = enabled
        self._server_url = server_url
        self._stun = list(stun_servers)
        self._node_name = node_name or platform_module.node() or "engine"
        self._app_version = app_version
        self._identity_store = identity_store or default_identity_store(
            credential_store, keyring_namespace
        )
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
        self._approve_attempts.clear()
        self._main = spawn_logged(self._supervise())

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
    async def _supervise(self) -> None:
        """Run ``_run_once`` and retry per ``classify_failure`` until it ends or is cancelled."""
        attempt = consecutive_404 = 0
        bounded_used = False
        while True:
            try:
                await self._run_once()
                return
            except asyncio.CancelledError:
                raise
            except Exception as error:
                if self.state == "running":
                    attempt = consecutive_404 = 0
                    bounded_used = False
                consecutive_404 = consecutive_404 + 1 if _status_of(error) == 404 else 0
                verdict = classify_failure(
                    error,
                    consecutive_404=consecutive_404,
                    bounded_used=bounded_used,
                    attempt=attempt,
                    rng=self._rng,
                )
                message = str(error) or type(error).__name__
                known = isinstance(error, (HiveApiError, HiveError, AccountError, IdentityError))
                if known:
                    _LOGGER.info(
                        "Hive %s (%s: %s); %s",
                        verdict.state,
                        type(error).__name__,
                        message,
                        f"retry in {verdict.delay:.0f}s" if verdict.action == "retry" else "not retrying",
                    )
                elif message not in self._warned_messages:
                    self._warned_messages.add(message)
                    _LOGGER.warning("Hive failed to start: %s", message, exc_info=True)
                self.state, self.detail = verdict.state, verdict.detail
                if verdict.action == "stop":
                    return
                if _status_of(error) in (400, 403, 409, 422):
                    bounded_used = True
                attempt += 1
                await self._teardown_network()
                await self._sleep(verdict.delay)

    async def retry(self) -> None:
        """Restart a supervisor that stopped in ``error`` (the GUI's retry button)."""
        main = self._main
        if self.state == "error" and self._user is not None and (main is None or main.done()):
            self.state, self.detail = "starting", ""
            self._main = spawn_logged(self._supervise())

    async def reset_local_hive_data(self) -> Path:
        """Back up the database (copy, never delete) then forget local hive bookkeeping.

        Restarts the supervisor so signalling can start under the current account.
        """
        engine = getattr(getattr(self.app, "state", None), "sync_engine", None)
        if engine is None:
            raise HiveError("The hive is not available.", 503)
        source = self._data_directory / "subconscious.db"
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        target = self._data_directory / f"subconscious.db.bak-{stamp}"
        if source.exists():
            await asyncio.to_thread(_backup_sqlite, source, target)
        _LOGGER.warning("Hive: local hive data reset; backup=%s", target.name)
        async with self._lock:
            user = self._user
            await self._stop_locked()
            await engine.reset_local()
            if user is not None:
                await self._start_locked(user)
        return target

    async def _run_once(self) -> None:
        assert self.api and self.directory and self.identity
        enroll_tried = False
        while True:
            await self._refresh_directory()
            local = self.directory.get(self.identity.node_id)
            if local is None:
                # Signing in to the account authorizes this engine: register it as a
                # full node whether or not other devices (clients) are listed already.
                if not enroll_tried:
                    enroll_tried = True
                    _LOGGER.info("Hive: engine not listed; registering node_id=%s", self.identity.node_id)
                    await self.enroll(None)
                    continue
                self.state = "error"
                self.detail = "This engine could not be listed on your account. Retrying."
                enroll_tried = False
            else:
                _LOGGER.info(
                    "Hive: engine listed (status=%s); starting network", local.status
                )
                await self._connect_network()
                if self.state == "hive_mismatch":
                    _LOGGER.warning("Hive stopped: %s", self.detail)
                    return
                await self._reconcile_loop()
                return
            await self._sleep(DIRECTORY_POLL_SECONDS)

    async def _connect_network(self) -> None:
        assert self.api and self.directory and self.identity
        identity, directory, api = self.identity, self.directory, self.api
        node: HiveNode | None = None
        if self.app is not None and getattr(self.app.state, "sync_engine", None) is not None:
            node = HiveNode(self.app, identity, directory)
            self.node = node
            # An empty hive id (server did not report one) is never bound or compared.
            if not await node.start(directory.hive_id or ""):
                # This data directory already belongs to another hive: never merge histories.
                self.state = "hive_mismatch"
                self.detail = HIVE_MISMATCH_DETAIL
                _LOGGER.warning("Hive: signalling not started: hive mismatch")
                return
        self.signaling = SignalingClient(api, identity, on_connected=self._on_signalling_connected)
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
        _LOGGER.info("Hive: signalling started node_id=%s", identity.node_id)
        registry = getattr(getattr(self.app, "state", None), "client_registry", None)
        if registry is not None:
            self._unsubscribe_clients = registry.subscribe(self._on_local_clients)
        self.state, self.detail = "running", ""

    # --- legacy thin-row fold ----------------------------------------------------
    def note_gui_client(self, device_name: str | None, client_id: str | None) -> None:
        """Remember the GUI's device name / client id from the last local login (never logged)."""
        self._gui_name, self._gui_client_id = device_name, client_id

    async def _on_signalling_connected(self) -> None:
        _LOGGER.info("Hive: signalling connected; checking legacy client rows")
        spawn_logged(self._fold_gui_clients())

    def _fold_candidates(self, connected_at: float) -> list[Any]:
        directory, identity = self.directory, self.identity
        if directory is None or identity is None:
            return []
        mapped = self._gui_store.mapping.get(self._gui_client_id or "")
        platform_name = (platform_module.system() or "").lower()
        found: list[Any] = []
        for node in directory.nodes:
            if (
                node.kind != "thin"
                or node.parent_node_id is not None
                or node.status != "active"
                or node.id in self._parented
            ):
                continue
            if mapped is not None:
                if node.id == mapped:
                    found.append(node)
                continue
            if self._gui_name is None or node.name != self._gui_name:
                continue
            if node.platform.lower() != platform_name:
                continue
            if self._online.get(node.id, node.online) and not _seen_before(
                node.last_seen_at, connected_at
            ):
                continue
            found.append(node)
        return found

    async def _fold_gui_clients(self) -> None:
        api, identity = self.api, self.identity
        if api is None or identity is None or (self._gui_name is None and self._gui_client_id is None):
            return
        matches = self._fold_candidates(time.time())
        if len(matches) > 1:
            _LOGGER.info("legacy_fold_ambiguous count=%d", len(matches))
            return
        if not matches:
            return
        node = matches[0]
        self._parented.add(node.id)
        try:
            await api.set_parent(node.id, identity.node_id)
        except HiveApiError as error:
            _LOGGER.info("legacy_fold skipped node_id=%s status=%s", node.id, error.status_code)
            return
        if self._gui_client_id:
            self._gui_store.mapping[self._gui_client_id] = node.id
            with logged_suppress(OSError):
                self._gui_store.save()
        _LOGGER.info("legacy_fold parented node_id=%s under %s", node.id, identity.node_id)
        await self.refresh(force=True)

    # --- callbacks -------------------------------------------------------------
    def _on_local_clients(self, infos: tuple[Any, ...]) -> None:
        clients = tuple(info.display_name for info in infos if info.is_local)
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
            known = self.directory.get(node_id) if self.directory is not None else None
            if self.directory is not None:
                if known is None:
                    unknown = True
                else:
                    status = entry.get("status")
                    if isinstance(status, str) and status != known.status:
                        unknown = True
                    if "parent_node_id" in entry and entry["parent_node_id"] != known.parent_node_id:
                        unknown = True
            if self.peers is not None:
                await self.peers.on_presence(node_id, online)
        if unknown:
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

    async def refresh(self, *, force: bool = False) -> None:
        """Re-read the server's node list (best effort), at most once per 5 s unless forced.

        A node that just enrolled is ``pending`` and not on the signalling socket, so no
        presence frame ever tells the others about it; listing and approving must ask.
        """
        if self.api is None or self.directory is None:
            return
        now = time.monotonic()
        if not force and now - self._last_refresh < REFRESH_THROTTLE_SECONDS:
            return
        self._last_refresh = now
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
        await self.retry()
        return self.snapshot()

    async def create_invite(self) -> dict[str, Any]:
        api, directory, identity, _ = self._require_running()
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
        if directory.get(node_id) is None:
            await self.refresh(force=True)  # the pending node may have enrolled after our last listing
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

    async def _reconcile_loop(self) -> None:
        """Safety net only: refresh and auto-approve while signalling is down (0 req/min when up)."""
        while True:
            await self._sleep(DIRECTORY_RECONCILE_SECONDS)
            signaling = self.signaling
            if signaling is not None and signaling.connected:
                continue
            try:
                await self._refresh_directory()
                await self._auto_approve_pending()
            except (HiveApiError, AccountError, HiveError) as error:
                if _session_is_dead(error):
                    raise
                _LOG.warning("hive.service.HiveService._reconcile_loop: handled; will retry", exc_info=True)

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
            attempts = self._approve_attempts.get(node.id, 0)
            if attempts >= AUTO_APPROVE_MAX_ATTEMPTS:
                if attempts == AUTO_APPROVE_MAX_ATTEMPTS:
                    _LOGGER.info("Hive auto-approve gave up on node_id=%s", node.id)
                    self._approve_attempts[node.id] = attempts + 1
                continue
            self._approve_attempts[node.id] = attempts + 1
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
        signaling = self.signaling
        signalling_up = signaling is not None and signaling.connected
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
                        "online": signalling_up
                        if node.id == identity.node_id
                        else self._online.get(node.id, node.online),
                        "parent_node_id": node.parent_node_id,
                        "clients": list(self._clients)
                        if node.id == identity.node_id
                        else list(node.clients),
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
            "signalling": {
                "connected": signalling_up,
                "started": signaling is not None,
                "reason": "not started: hive mismatch" if self.state == "hive_mismatch" else None,
                "failures": signaling.failures if signaling is not None else 0,
                "last_error": signaling.last_error if signaling is not None else None,
            },
            "node_id": identity.node_id if identity else None,
            "hive_id": directory.hive_id if directory else None,
            "nodes": nodes,
        }
