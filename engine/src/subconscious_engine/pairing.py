"""Pairing of browser extensions with this engine through the signed-in account.

The extension obtains a single-use assertion from the cloud server (bound to the engine's node
id, a client nonce and the extension origin). The engine verifies it with its own account
session, checks the account matches, and mints a revocable client token. Only the SHA-256 hash
of that token is ever stored.
"""

from __future__ import annotations

from collections import deque
from collections.abc import Callable
from dataclasses import dataclass
import hashlib
import json
import logging
import os
from pathlib import Path
import re
import secrets
import threading
import time
import uuid
from typing import Any

import httpx

from subconscious_engine.account import AccountError, AccountSessionService

_LOG = logging.getLogger(__name__)

TOKEN_PREFIX = "scp_"
TTL_SECONDS = 30 * 24 * 3600
MAX_CLIENTS = 20
LAST_USED_THROTTLE_SECONDS = 60.0
ORIGIN_PATTERN = re.compile(r"chrome-extension://[a-p]{32}|moz-extension://[0-9a-f-]{36}")
RATE_LIMIT = 5
RATE_WINDOW_SECONDS = 60.0


class PairingError(Exception):
    def __init__(self, status_code: int, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.message = message


def is_extension_origin(origin: str | None) -> bool:
    return bool(origin) and ORIGIN_PATTERN.fullmatch(origin) is not None


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


@dataclass(slots=True)
class PairedClient:
    id: str
    token_hash: str
    origin: str
    label: str
    created_at: float
    last_used_at: float
    expires_at: float

    def to_api(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "origin": self.origin,
            "label": self.label,
            "created_at": self.created_at,
            "last_used_at": self.last_used_at,
            "expires_at": self.expires_at,
        }


class PairedClientStore:
    """Thread-safe, file-backed set of paired clients (hashes only)."""

    def __init__(
        self,
        path: Path | None = None,
        *,
        clock: Callable[[], float] = time.time,
        max_clients: int = MAX_CLIENTS,
        ttl_seconds: float = TTL_SECONDS,
        throttle_seconds: float = LAST_USED_THROTTLE_SECONDS,
    ) -> None:
        self._path = path
        self._clock = clock
        self._max = max_clients
        self._ttl = ttl_seconds
        self._throttle = throttle_seconds
        self._lock = threading.Lock()
        self._clients: list[PairedClient] = []
        self._load()

    def _load(self) -> None:
        if self._path is None or not self._path.exists():
            return
        try:
            data = json.loads(self._path.read_text(encoding="utf-8"))
            self._clients = [
                PairedClient(
                    id=str(item["id"]),
                    token_hash=str(item["token_hash"]),
                    origin=str(item["origin"]),
                    label=str(item.get("label", "")),
                    created_at=float(item["created_at"]),
                    last_used_at=float(item["last_used_at"]),
                    expires_at=float(item["expires_at"]),
                )
                for item in data.get("clients", [])
            ]
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            _LOG.warning("pairing: could not read %s; starting with no paired clients", self._path, exc_info=True)
            self._clients = []

    def _save(self) -> None:
        if self._path is None:
            return
        payload = {
            "version": 1,
            "clients": [{**c.to_api(), "token_hash": c.token_hash} for c in self._clients],
        }
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self._path.with_name(f"{self._path.name}.{uuid.uuid4().hex}.tmp")
            temporary.write_text(json.dumps(payload, indent=2), encoding="utf-8")
            if os.name != "nt":
                os.chmod(temporary, 0o600)
            os.replace(temporary, self._path)
        except OSError:
            _LOG.warning("pairing: could not persist paired clients to %s", self._path, exc_info=True)

    def add(self, origin: str, label: str | None = None) -> tuple[str, PairedClient]:
        """Create a client; returns the raw token (shown once) and the stored record."""
        token = TOKEN_PREFIX + secrets.token_urlsafe(32)
        now = self._clock()
        record = PairedClient(
            id=uuid.uuid4().hex,
            token_hash=hash_token(token),
            origin=origin,
            label=(label or "Browser extension")[:64],
            created_at=now,
            last_used_at=now,
            expires_at=now + self._ttl,
        )
        with self._lock:
            self._clients = [c for c in self._clients if c.expires_at > now]
            self._clients.append(record)
            if len(self._clients) > self._max:
                self._clients.sort(key=lambda c: c.created_at)
                self._clients = self._clients[len(self._clients) - self._max:]
            self._save()
        return token, record

    def verify(self, token: str) -> PairedClient | None:
        """Return the client for a valid unexpired token, sliding its expiry (throttled)."""
        if not token.startswith(TOKEN_PREFIX):
            return None
        digest = hash_token(token)
        now = self._clock()
        with self._lock:
            match: PairedClient | None = None
            for client in self._clients:  # compare every entry: no early exit on a hit
                if secrets.compare_digest(client.token_hash, digest):
                    match = client
            if match is None:
                return None
            if match.expires_at <= now:
                return None
            if now - match.last_used_at >= self._throttle:
                match.last_used_at = now
                match.expires_at = now + self._ttl
                self._save()
            return match

    def list(self) -> list[PairedClient]:
        now = self._clock()
        with self._lock:
            return [c for c in self._clients if c.expires_at > now]

    def revoke(self, client_id: str) -> bool:
        with self._lock:
            kept = [c for c in self._clients if c.id != client_id]
            removed = len(kept) != len(self._clients)
            self._clients = kept
            if removed:
                self._save()
            return removed


class RateLimiter:
    """Sliding-window limiter, in process."""

    def __init__(self, limit: int = RATE_LIMIT, window: float = RATE_WINDOW_SECONDS,
                 clock: Callable[[], float] = time.monotonic) -> None:
        self._limit = limit
        self._window = window
        self._clock = clock
        self._hits: dict[str, deque[float]] = {}

    def allow(self, key: str) -> bool:
        now = self._clock()
        if len(self._hits) > 1024:
            self._hits = {k: v for k, v in self._hits.items() if v and now - v[-1] < self._window}
        hits = self._hits.setdefault(key, deque())
        while hits and now - hits[0] >= self._window:
            hits.popleft()
        if len(hits) >= self._limit:
            return False
        hits.append(now)
        return True


class PairingService:
    def __init__(
        self,
        account: AccountSessionService,
        node_id_provider: Callable[[], str | None],
        store: PairedClientStore,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._account = account
        self._node_id = node_id_provider
        self.store = store
        self._client = client

    async def pair(self, assertion: str, client_nonce: str, origin: str) -> tuple[str, PairedClient]:
        user = self._account.current_account_user
        if user is None or not self._account.access_token():
            raise PairingError(401, "The engine is not signed in to an account.")
        node_id = self._node_id()
        if not node_id:
            raise PairingError(503, "This engine has no node identity yet.")
        body = {"assertion": assertion, "client_nonce": client_nonce, "origin": origin}
        url = f"{self._account.server_base_url}nodes/{node_id}/pairing-assertion/verify"
        response = await self._post(url, body)
        if response.status_code == 401:
            try:
                await self._account.refresh_access_token()
            except AccountError as error:
                raise PairingError(401, "The engine's account session expired.") from error
            response = await self._post(url, body)
        status = response.status_code
        if status == 401:
            raise PairingError(401, "The engine's account session is not valid.")
        if status == 429:
            raise PairingError(429, "Too many pairing attempts.")
        if status in (400, 403, 404, 422):
            raise PairingError(404, "Invalid assertion.")
        if status >= 400:
            raise PairingError(503, "The account server could not verify the assertion.")
        try:
            value = response.json()
        except ValueError as error:
            raise PairingError(503, "The account server returned an invalid response.") from error
        if not isinstance(value, dict) or value.get("ok") is not True:
            raise PairingError(404, "Invalid assertion.")
        current = self._account.current_account_user
        if current is None or value.get("user_id") != current.id:
            raise PairingError(401, "The assertion belongs to a different account.")
        return self.store.add(origin)

    async def _post(self, url: str, body: dict[str, str]) -> httpx.Response:
        token = self._account.access_token()
        headers = {"Accept": "application/json", "Authorization": f"Bearer {token}"}
        try:
            if self._client is not None:
                return await self._client.post(url, json=body, headers=headers)
            async with httpx.AsyncClient(timeout=10.0) as client:
                return await client.post(url, json=body, headers=headers)
        except httpx.HTTPError as error:
            _LOG.warning("pairing: account server unreachable: %s", type(error).__name__)
            raise PairingError(503, "Could not reach the account server.") from error
