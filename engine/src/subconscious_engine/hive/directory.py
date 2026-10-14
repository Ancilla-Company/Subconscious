"""Cached node directory: key pinning and approval-chain verification.

The server is not trusted to add members. A node is *trusted* only when its id
matches its key, its key matches any earlier pin, and either it is a local trust
root or its ``approval_sig`` was made by another trusted node over
``sc-approve-v1 | user_id | new_public_key``.

Trust roots: the local node when it is the account's first node, plus roots
pinned on this machine. If nothing is pinned and the server lists exactly one
active node without an approver, that node is pinned on first use (TOFU); the
short authentication string check at approval time is what protects enrolment.
"""

from __future__ import annotations

import json
import logging
import os
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx

from .identity import (
    IdentityError,
    approval_message,
    b64u_decode,
    b64u_encode,
    derive_node_id,
    node_ids_equal,
    verify_signature,
)

_LOGGER = logging.getLogger("uvicorn.error")
_MAX_CHAIN_DEPTH = 8


class HiveApiError(Exception):
    """A safe error from the node registry (never contains tokens)."""

    def __init__(self, message: str, status_code: int = 502) -> None:
        super().__init__(message)
        self.message = message
        self.status_code = status_code


@dataclass(frozen=True, slots=True)
class DirectoryNode:
    id: str
    kind: str
    name: str
    platform: str
    app_version: str
    protocol_version: int | str | None
    public_key: bytes
    status: str
    approved_by: str | None
    approval_sig: str | None
    capabilities: dict[str, Any] = field(default_factory=dict)
    created_at: str | None = None
    last_seen_at: str | None = None
    online: bool = False

    @property
    def public_key_b64u(self) -> str:
        return b64u_encode(self.public_key)

    @classmethod
    def parse(cls, raw: Any) -> "DirectoryNode | None":
        """Parse one server entry; malformed entries are dropped, never trusted."""
        if not isinstance(raw, dict):
            return None
        try:
            node_id = raw["id"]
            key = b64u_decode(raw["public_key"])
            if not isinstance(node_id, str) or len(key) != 32:
                return None
            capabilities = raw.get("capabilities")
            return cls(
                id=node_id,
                kind=str(raw.get("kind", "")),
                name=str(raw.get("name", "")),
                platform=str(raw.get("platform", "")),
                app_version=str(raw.get("app_version", "")),
                protocol_version=raw.get("protocol_version"),
                public_key=key,
                status=str(raw.get("status", "")),
                approved_by=raw.get("approved_by")
                if isinstance(raw.get("approved_by"), str)
                else None,
                approval_sig=raw.get("approval_sig")
                if isinstance(raw.get("approval_sig"), str)
                else None,
                capabilities=capabilities if isinstance(capabilities, dict) else {},
                created_at=raw.get("created_at"),
                last_seen_at=raw.get("last_seen_at"),
                online=raw.get("online") is True,
            )
        except (KeyError, IdentityError, TypeError):
            return None


class PinStore:
    """Persists pinned keys and trust roots as a small JSON file."""

    def __init__(self, path: Path | None) -> None:
        self._path = path
        self.keys: dict[str, str] = {}
        self.roots: set[str] = set()
        self._load()

    def _load(self) -> None:
        if self._path is None or not self._path.exists():
            return
        try:
            raw = json.loads(self._path.read_text(encoding="utf-8"))
            self.keys = {
                k: v for k, v in raw.get("keys", {}).items() if isinstance(v, str)
            }
            self.roots = {r for r in raw.get("roots", []) if isinstance(r, str)}
        except (OSError, ValueError, AttributeError):
            _LOGGER.warning("Hive pin store could not be read; starting empty.")

    def save(self) -> None:
        if self._path is None:
            return
        self._path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self._path.with_suffix(".tmp")
        temporary.write_text(
            json.dumps({"keys": self.keys, "roots": sorted(self.roots)}),
            encoding="utf-8",
        )
        os.replace(temporary, self._path)


class Directory:
    """In-memory verified view of the account's nodes."""

    def __init__(
        self,
        user_id: str,
        local_node_id: str,
        pins: PinStore | None = None,
    ) -> None:
        self.user_id = user_id
        self.local_node_id = local_node_id
        self._pins = pins or PinStore(None)
        self._nodes: dict[str, DirectoryNode] = {}
        self._trusted: set[str] = set()
        self.hive_id: str | None = None

    # --- queries ----------------------------------------------------------
    @property
    def nodes(self) -> list[DirectoryNode]:
        return list(self._nodes.values())

    def get(self, node_id: str) -> DirectoryNode | None:
        return self._nodes.get(node_id)

    def is_trusted(self, node_id: str) -> bool:
        return node_id in self._trusted

    def trusted_node(self, node_id: str) -> DirectoryNode | None:
        node = self._nodes.get(node_id)
        return node if node is not None and node_id in self._trusted else None

    # --- update -----------------------------------------------------------
    def update(self, raw_nodes: Iterable[Any], hive_id: str | None = None) -> None:
        if hive_id is not None:
            self.hive_id = hive_id
        parsed: dict[str, DirectoryNode] = {}
        for raw in raw_nodes:
            node = DirectoryNode.parse(raw)
            if node is None:
                continue
            if not node_ids_equal(node.id, derive_node_id(node.public_key)):
                _LOGGER.warning("Ignoring a directory entry whose id does not match its key.")
                continue
            pinned = self._pins.keys.get(node.id)
            if pinned is not None and pinned != node.public_key_b64u:
                _LOGGER.warning("Ignoring a directory entry whose key changed.")
                continue
            parsed[node.id] = node
        self._nodes = parsed
        self._trusted = self._compute_trusted()
        changed = False
        for node_id in self._trusted:
            key = self._nodes[node_id].public_key_b64u
            if self._pins.keys.get(node_id) != key:
                self._pins.keys[node_id] = key
                changed = True
        if changed:
            self._pins.save()

    def _compute_trusted(self) -> set[str]:
        roots = self._roots()
        trusted: set[str] = set()
        for node_id in self._nodes:
            if self._chain_ok(node_id, roots, set(), 0):
                trusted.add(node_id)
        return trusted

    def _roots(self) -> set[str]:
        roots = {r for r in self._pins.roots if r in self._nodes}
        local = self._nodes.get(self.local_node_id)
        if local is not None and local.status == "active" and local.approved_by is None:
            roots.add(local.id)  # we are the first node of this hive
        if not roots:
            candidates = [
                n for n in self._nodes.values()
                if n.status == "active" and n.approved_by is None
            ]
            if len(candidates) == 1:
                roots.add(candidates[0].id)
                self._pins.roots.add(candidates[0].id)
                self._pins.save()
        if roots - self._pins.roots:
            self._pins.roots |= roots
            self._pins.save()
        return roots

    def _chain_ok(
        self, node_id: str, roots: set[str], seen: set[str], depth: int
    ) -> bool:
        node = self._nodes.get(node_id)
        if node is None or node.status != "active" or depth > _MAX_CHAIN_DEPTH:
            return False
        if node_id in roots:
            return True
        if node_id in seen or node.approved_by is None or node.approval_sig is None:
            return False
        approver = self._nodes.get(node.approved_by)
        if approver is None or approver.id == node.id:
            return False
        if not verify_signature(
            approver.public_key,
            node.approval_sig,
            approval_message(self.user_id, node.public_key_b64u),
        ):
            return False
        return self._chain_ok(approver.id, roots, seen | {node_id}, depth + 1)


class HiveApi:
    """HTTP client for the server's node registry endpoints."""

    def __init__(
        self,
        base_url: str,
        access_token: Callable[[], str | None],
        refresh_token: Callable[[], Any] | None = None,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/") + "/"
        self._access_token = access_token
        self._refresh = refresh_token
        self._client = client or httpx.AsyncClient(base_url=self._base_url, timeout=15.0)
        self._owns_client = client is None

    @property
    def base_url(self) -> str:
        return self._base_url

    async def close(self) -> None:
        if self._owns_client:
            await self._client.aclose()

    async def request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
        *,
        node_id: str | None = None,
    ) -> Any:
        for attempt in range(2):
            token = self._access_token()
            if not token:
                raise HiveApiError("Sign in to use the hive.", 401)
            headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
            if node_id:
                headers["X-Node-Id"] = node_id
            try:
                response = await self._client.request(
                    method, path.lstrip("/"), json=body, headers=headers
                )
            except httpx.HTTPError as error:
                raise HiveApiError("Could not reach the hive server.") from error
            if response.status_code == 401 and attempt == 0 and self._refresh:
                await self._refresh()
                continue
            if response.is_error:
                raise HiveApiError(_error_text(response), response.status_code)
            if response.status_code == 204 or not response.content:
                return {}
            try:
                return response.json()
            except ValueError as error:
                raise HiveApiError("The hive server returned an invalid response.") from error
        raise HiveApiError("The hive server rejected the session.", 401)

    async def register(self, body: dict[str, Any]) -> dict[str, Any]:
        return _mapping(await self.request("POST", "nodes", body))

    async def list_nodes(self) -> dict[str, Any]:
        return _mapping(await self.request("GET", "nodes"))

    async def approve(self, node_id: str, approver_node_id: str, sig: str) -> None:
        await self.request(
            "POST",
            f"nodes/{node_id}/approve",
            {"approver_node_id": approver_node_id, "approval_sig": sig},
        )

    async def revoke(self, node_id: str) -> None:
        await self.request("DELETE", f"nodes/{node_id}")

    async def create_invite(self, node_id: str) -> dict[str, Any]:
        return _mapping(await self.request("POST", "nodes/invites", {}, node_id=node_id))

    async def signal_ticket(self, node_id: str) -> dict[str, Any]:
        return _mapping(await self.request("POST", f"nodes/{node_id}/signal-ticket", {}))

    async def ice_config(self, node_id: str) -> dict[str, Any]:
        return _mapping(await self.request("POST", f"nodes/{node_id}/ice-config", {}))


def _mapping(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise HiveApiError("The hive server returned an invalid response.")
    return value


def _error_text(response: httpx.Response) -> str:
    try:
        value = response.json()
    except ValueError:
        value = None
    if isinstance(value, dict):
        for key in ("message", "error", "detail"):
            text = value.get(key)
            if isinstance(text, str) and text.strip():
                return text.strip()[:200]
    return f"The hive server returned status {response.status_code}."
