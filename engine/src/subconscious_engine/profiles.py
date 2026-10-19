"""Account profiles: one isolated data directory and engine instance per account.

Layout under the engine root data directory::

    <root>/                      the default profile (original, pre-profile data)
    <root>/profiles.json         which email owns which profile
    <root>/profiles/<id>/        every other profile (database, vault, hive, identity)

The default profile is unowned until the first successful sign-in claims it. A later
sign-in with another email gets its own profile (and its own node identity), so one
data directory never mixes two hives. All instances run inside one engine process and
share one tray icon, which this manager drives.
"""

from __future__ import annotations

import asyncio
from collections.abc import Callable
from dataclasses import dataclass, replace
import hashlib
import json
import logging
import os
from pathlib import Path
import threading
from typing import TYPE_CHECKING, Any
from uuid import uuid4

from .logging_setup import logged_suppress, spawn_logged

if TYPE_CHECKING:
    from .account import AccountUser
    from .api.websocket import ClientInfo
    from .config import EngineConfig
    from .host import EngineHost

_LOG = logging.getLogger(__name__)

DEFAULT_PROFILE_ID = "default"
_START_TIMEOUT_SECONDS = 30.0


class ProfileError(RuntimeError):
    """A profile instance could not be created or started."""


def normalize_email(email: str) -> str:
    return email.strip().lower()


def profile_id_for_email(email: str) -> str:
    """Deterministic, filesystem-safe id so the same email always maps to one directory."""
    digest = hashlib.sha256(normalize_email(email).encode("utf-8")).hexdigest()
    return f"u-{digest[:16]}"


@dataclass(frozen=True, slots=True)
class Profile:
    id: str
    directory: Path
    email: str | None = None

    @property
    def is_default(self) -> bool:
        return self.id == DEFAULT_PROFILE_ID


class ProfileRegistry:
    """Persists which email owns which profile in ``<root>/profiles.json``."""

    file_name = "profiles.json"

    def __init__(self, root: Path) -> None:
        self.root = root
        self._lock = threading.Lock()

    @property
    def path(self) -> Path:
        return self.root / self.file_name

    def directory_for(self, profile_id: str) -> Path:
        if profile_id == DEFAULT_PROFILE_ID:
            return self.root
        return self.root / "profiles" / profile_id

    def _read(self) -> dict[str, str | None]:
        try:
            value = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            _LOG.debug("profiles.ProfileRegistry._read: no readable registry; continuing with none", exc_info=True)
            return {}
        profiles = value.get("profiles") if isinstance(value, dict) else None
        if not isinstance(profiles, dict):
            return {}
        return {
            key: (entry.get("email") if isinstance(entry, dict) else None)
            for key, entry in profiles.items()
            if isinstance(key, str) and key
        }

    def _write(self, entries: dict[str, str | None]) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        temporary = self.root / f".{self.file_name}.{os.getpid()}.{uuid4().hex}.tmp"
        try:
            temporary.write_text(
                json.dumps(
                    {"version": 1, "profiles": {k: {"email": v} for k, v in entries.items()}},
                    indent=2,
                ),
                encoding="utf-8",
            )
            os.replace(temporary, self.path)
        finally:
            temporary.unlink(missing_ok=True)

    def default(self) -> Profile:
        return self.get(DEFAULT_PROFILE_ID)

    def get(self, profile_id: str) -> Profile:
        with self._lock:
            email = self._read().get(profile_id)
        return Profile(profile_id, self.directory_for(profile_id), email)

    def list(self) -> list[Profile]:
        """The default profile first, then every registered profile."""
        with self._lock:
            entries = self._read()
        ids = [DEFAULT_PROFILE_ID, *sorted(k for k in entries if k != DEFAULT_PROFILE_ID)]
        return [Profile(i, self.directory_for(i), entries.get(i)) for i in ids]

    def find_by_email(self, email: str) -> Profile | None:
        wanted = normalize_email(email)
        for profile in self.list():
            if profile.email and normalize_email(profile.email) == wanted:
                return profile
        return None

    def bind(self, profile_id: str, email: str) -> Profile:
        """Record that ``email`` owns ``profile_id``. An existing owner is never replaced."""
        normalized = normalize_email(email)
        with self._lock:
            entries = self._read()
            if entries.get(profile_id) is None:
                entries[profile_id] = normalized
                self._write(entries)
        return Profile(profile_id, self.directory_for(profile_id), entries[profile_id])

    def pending_for(self, email: str) -> Profile:
        """The profile ``email`` would use (registered or not yet claimed)."""
        existing = self.find_by_email(email)
        if existing is not None:
            return existing
        pid = profile_id_for_email(email)
        return Profile(pid, self.directory_for(pid), None)


@dataclass(frozen=True, slots=True)
class RouteTarget:
    """Where a sign-in for an email must run."""

    profile: Profile
    host: "EngineHost"
    switched: bool


class ProfileManager:
    """Owns every engine instance in this process and the single tray icon."""

    def __init__(
        self,
        config: "EngineConfig",
        *,
        host_factory: Callable[..., "EngineHost"] | None = None,
    ) -> None:
        from .host import EngineHost

        self.config = config
        self.registry = ProfileRegistry(config.resolved_root_directory)
        self._host_factory = host_factory or EngineHost
        self.hosts: dict[str, EngineHost] = {}
        self._tasks: dict[str, asyncio.Future[Any]] = {}
        self._clients: dict[str, tuple["ClientInfo", ...]] = {}
        self._unsubscribe: dict[str, Callable[[], None]] = {}
        self._lock = asyncio.Lock()
        self._stopping = False
        self._default = self._build(self.registry.default())

    # --- construction ------------------------------------------------------------
    @property
    def default_host(self) -> "EngineHost":
        return self._default

    def _config_for(self, profile: Profile) -> "EngineConfig":
        if profile.is_default:
            return self.config
        # Secondary instances are headless, bind an ephemeral port and write their own
        # runtime.json inside the profile directory.
        return replace(
            self.config,
            profile_id=profile.id,
            root_directory=self.registry.root,
            data_directory=profile.directory,
            port=0,
            headless=True,
            node_id=None,
        )

    def _build(self, profile: Profile) -> "EngineHost":
        host = self._host_factory(
            self._config_for(profile), profiles=self, profile=profile
        )
        self.hosts[profile.id] = host
        self._watch(profile.id, host)
        return host

    def _watch(self, profile_id: str, host: "EngineHost") -> None:
        if getattr(host, "app", None) is None:
            return
        # Claim the profile for whoever signs in (also covers a restored session).
        def on_user(user: "AccountUser | None") -> None:
            if user is not None:
                self.registry.bind(profile_id, user.email)

        host.account_session_service.subscribe(on_user)
        self._unsubscribe[profile_id] = host.app.state.client_registry.subscribe(
            lambda clients: self._on_clients(profile_id, clients)
        )

    # --- tray ---------------------------------------------------------------------
    def _on_clients(self, profile_id: str, clients: tuple["ClientInfo", ...]) -> None:
        self._clients[profile_id] = tuple(clients)
        self.push_clients()

    def push_clients(self) -> None:
        combined = tuple(c for group in self._clients.values() for c in group)
        default = getattr(self, "_default", None)
        if default is not None:
            default.set_tray_clients(combined)

    # --- lifecycle -----------------------------------------------------------------
    async def serve(self) -> None:
        """Run the default instance (and the tray); stop every instance when it ends."""
        starter = spawn_logged(self._start_known_profiles())
        try:
            await self._default.serve()
        finally:
            starter.cancel()
            with logged_suppress(asyncio.CancelledError, Exception):
                await starter
            await self.stop_all()

    async def _start_known_profiles(self) -> None:
        await self._default.wait_until_ready(_START_TIMEOUT_SECONDS)
        for profile in self.registry.list():
            if profile.is_default or profile.email is None:
                continue
            with logged_suppress(Exception):
                await self.ensure(profile)

    async def ensure(self, profile: Profile) -> "EngineHost":
        """Return a running instance for ``profile``, starting it when needed."""
        if profile.is_default:
            return self._default
        async with self._lock:
            if self._stopping:
                raise ProfileError("The engine is shutting down.")
            host = self.hosts.get(profile.id)
            task = self._tasks.get(profile.id)
            if host is not None and task is not None and not task.done():
                return host
            if host is not None:
                self._forget(profile.id)  # a stopped host cannot be served again
            profile.directory.mkdir(parents=True, exist_ok=True)
            host = self._build(profile)
            task = spawn_logged(host.serve())
            self._tasks[profile.id] = task
            ready = spawn_logged(host.wait_until_ready(_START_TIMEOUT_SECONDS))
            await asyncio.wait({task, ready}, return_when=asyncio.FIRST_COMPLETED)
            if not host.is_ready:
                ready.cancel()
                task.cancel()
                self._forget(profile.id)
                raise ProfileError("The profile engine could not be started.")
            return host

    def _forget(self, profile_id: str) -> None:
        self.hosts.pop(profile_id, None)
        self._tasks.pop(profile_id, None)
        self._clients.pop(profile_id, None)
        unsubscribe = self._unsubscribe.pop(profile_id, None)
        if unsubscribe is not None:
            unsubscribe()
        self.push_clients()

    async def stop_profile(self, profile_id: str) -> None:
        host, task = self.hosts.get(profile_id), self._tasks.get(profile_id)
        if profile_id == DEFAULT_PROFILE_ID or host is None:
            return
        host.request_stop()
        if task is not None:
            with logged_suppress(asyncio.CancelledError, Exception):
                await asyncio.wait_for(task, 15.0)
        self._forget(profile_id)

    async def stop_all(self) -> None:
        self._stopping = True
        for profile_id in [p for p in self.hosts if p != DEFAULT_PROFILE_ID]:
            with logged_suppress(Exception):
                await self.stop_profile(profile_id)

    # --- routing -------------------------------------------------------------------
    async def route(self, current_profile_id: str, email: str) -> RouteTarget:
        """Pick (and start) the instance that must handle a sign-in for ``email``."""
        current = self.registry.get(current_profile_id)
        owner = self.registry.find_by_email(email)
        if owner is not None:
            target = owner
        elif current.email is None:
            target = current  # an unclaimed profile is claimed by its first sign-in
        else:
            target = self.registry.pending_for(email)
        host = await self.ensure(target)
        return RouteTarget(target, host, target.id != current_profile_id)

    async def abandon_if_unclaimed(self, profile: Profile) -> None:
        """Stop a freshly created profile whose sign-in failed (nothing was bound)."""
        if not profile.is_default and self.registry.get(profile.id).email is None:
            await self.stop_profile(profile.id)

    def describe(self, profile: Profile, host: "EngineHost | None" = None) -> dict[str, Any]:
        host = host or self.hosts.get(profile.id)
        running = host is not None and host.is_ready
        return {
            "id": profile.id,
            "email": self.registry.get(profile.id).email,
            "default": profile.is_default,
            "running": running,
            "host": "127.0.0.1" if running else None,
            "port": host.bound_port if running else None,
            "token": host.token.value if running else None,
        }

    def list_profiles(self) -> list[dict[str, Any]]:
        return [self.describe(profile) for profile in self.registry.list()]
