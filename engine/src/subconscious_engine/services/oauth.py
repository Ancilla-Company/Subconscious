"""OAuth sign-in for remote (streamable HTTP) MCP tools.

The MCP SDK implements the client side of the MCP authorization spec (OAuth 2.1 + PKCE,
metadata discovery, dynamic client registration) as an ``httpx.Auth``
(``mcp.client.auth.OAuthClientProvider``). It needs three things from the host, all provided here:

* ``ToolOAuthStorage``: the SDK's ``TokenStorage`` over the encrypted ``data.enc`` store
  (``tool_oauth`` section, keyed by tool uuid). Tokens, the client registration and a
  user-supplied client secret never touch SQLite, logs, DTOs or the model.
* a ``redirect_handler(url)``: the SDK hands over the authorization URL; the broker registers a
  *pending authorization* and tells every listener (the chat turn that triggered it, the
  event bus and all connected clients) to show a "Sign in" prompt.
* a ``callback_handler()``: awaits the browser's trip back to
  ``http://127.0.0.1:<engine port>/api/v1/oauth/callback`` (or the paste fallback below).

Redirect URI and its limitation
-------------------------------
The redirect URI is a loopback URL on the engine's own listening port. The host sets the bound
port after binding (``app.state.oauth_broker.set_port``); until then the first request or
websocket that reaches the engine supplies it. A loopback redirect only works when the browser
that completes the sign-in runs on the SAME machine as the engine. A UI on another device
(phone, LAN client) ends on a page that cannot load; it then pastes the address the browser ended
on (or the code and state) to ``POST /api/v1/oauth/{authId}/complete``.

Interactive vs non-interactive
------------------------------
Only a flow started on purpose (the authorize endpoint, the ``connect_tool`` management tool) may
wait for a human. Chat turns and tool tests build their provider in non-interactive mode: if the
SDK would open a new authorization, ``redirect_handler`` raises ``AuthorizationRequired`` instead
and the tool is marked as needing sign-in. Each state value is single use and expires after
``PENDING_TIMEOUT_SECONDS``.
"""

from __future__ import annotations

import asyncio
import html
import logging
import time
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass
from typing import Any
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from uuid import uuid4

from mcp.client.auth import OAuthClientProvider
from mcp.shared.auth import (
    OAuthClientInformationFull,
    OAuthClientMetadata,
    OAuthMetadata,
    OAuthToken,
    ProtectedResourceMetadata,
)
from pydantic import ValidationError

from subconscious_engine.connection_log import connection_event, connection_problem

_LOG = logging.getLogger(__name__)

PENDING_TIMEOUT_SECONDS = 600.0
CALLBACK_PATH = "/api/v1/oauth/callback"
CLIENT_NAME = "Subconscious"
REQUEST_FRAME = "oauth.request"
RESOLVED_FRAME = "oauth.resolved"
NOT_COMPLETED_IN_TIME = "Sign-in was not completed in time."

Listener = Callable[[str, dict[str, Any]], Awaitable[None]]


class AuthorizationRequired(Exception):
    """A non-interactive start reached the point where a human has to sign in."""


class OAuthDenied(Exception):
    """The user (or the authorization server) refused the sign-in."""


class OAuthCancelled(Exception):
    """The pending sign-in was cancelled before it completed."""


class OAuthCallbackError(ValueError):
    """The callback / paste input is invalid (unknown, expired or replayed state, bad URL)."""


class OAuthNotReady(RuntimeError):
    """The engine's listening port is not known yet, so no redirect URI can be built."""


@dataclass(slots=True)
class PendingAuthorization:
    auth_id: str
    tool_uuid: str
    tool_name: str
    state: str
    url: str
    redirect_uri: str
    created_at: float
    expires_at: float
    # Resolves to (status, code, state, message) when the authorization ends.
    future: asyncio.Future[tuple[str, str | None, str | None, str | None]]
    status: str = "pending"

    def to_json(self) -> dict[str, Any]:
        return {"authId": self.auth_id, "toolUuid": self.tool_uuid, "toolName": self.tool_name,
                "url": self.url, "redirectUri": self.redirect_uri, "createdAt": self.created_at,
                "expiresAt": self.expires_at}


def _query(url: str) -> dict[str, str]:
    return dict(parse_qsl(urlsplit(url).query, keep_blank_values=True))


class OAuthBroker:
    """Tracks pending authorizations and tells listeners about them."""

    def __init__(self, *, event_bus: Any = None, client_registry: Any = None,
                 timeout: float = PENDING_TIMEOUT_SECONDS, clock: Callable[[], float] = time.time,
                 port: int | None = None) -> None:
        self.event_bus = event_bus
        self.client_registry = client_registry
        self.timeout = timeout
        self._clock = clock
        self._port = port
        self._pending: dict[str, PendingAuthorization] = {}
        self._by_state: dict[str, PendingAuthorization] = {}
        self._listeners: dict[str, tuple[Listener, str | None]] = {}

    # --- redirect URI ------------------------------------------------------------------------
    @property
    def port(self) -> int | None:
        return self._port

    def set_port(self, port: int | None, *, overwrite: bool = True) -> None:
        if port and (overwrite or self._port is None):
            self._port = int(port)

    @property
    def redirect_uri(self) -> str:
        if not self._port:
            raise OAuthNotReady("The engine port is not known yet; try again in a moment.")
        return f"http://127.0.0.1:{self._port}{CALLBACK_PATH}"

    # --- listeners ---------------------------------------------------------------------------
    def attach(self, turn_id: str, notify: Listener, client_id: str | None = None) -> None:
        """Send every request/resolved frame to ``notify`` until :meth:`detach`."""
        self._listeners[turn_id] = (notify, client_id)

    def detach(self, turn_id: str) -> None:
        self._listeners.pop(turn_id, None)

    async def _emit(self, frame_type: str, data: dict[str, Any]) -> None:
        listeners = list(self._listeners.values())
        for notify, _ in listeners:
            try:
                await notify(frame_type, dict(data))
            except Exception:
                _LOG.warning("services.oauth.OAuthBroker._emit: a listener failed for %s", frame_type, exc_info=True)
        excluded = {client for _, client in listeners if client}
        if self.event_bus is not None:
            try:
                await self.event_bus.publish(frame_type, dict(data))
            except Exception:
                _LOG.warning("services.oauth.OAuthBroker._emit: event bus failed", exc_info=True)
        if self.client_registry is not None:
            try:
                await self.client_registry.broadcast(frame_type, dict(data), exclude_client_ids=excluded)
            except Exception:
                _LOG.warning("services.oauth.OAuthBroker._emit: broadcast failed", exc_info=True)

    # --- lifecycle ---------------------------------------------------------------------------
    async def register(self, tool_uuid: str, tool_name: str, url: str) -> PendingAuthorization:
        """Record an authorization the SDK wants the user to approve and announce it."""
        state = _query(url).get("state")
        if not state:
            raise OAuthCallbackError("The authorization URL has no state parameter.")
        now = self._clock()
        pending = PendingAuthorization(
            auth_id=uuid4().hex, tool_uuid=tool_uuid, tool_name=tool_name, state=state, url=url,
            redirect_uri=self.redirect_uri, created_at=now, expires_at=now + self.timeout,
            future=asyncio.get_running_loop().create_future())
        self._pending[pending.auth_id] = pending
        self._by_state[state] = pending
        connection_event("oauth.authorization.requested", auth_id=pending.auth_id, uuid=tool_uuid,
                         alias=tool_name)
        await self._emit(REQUEST_FRAME, self.request_payload(pending))
        return pending

    def request_payload(self, pending: PendingAuthorization) -> dict[str, Any]:
        return {"auth_id": pending.auth_id, "tool_uuid": pending.tool_uuid, "tool_name": pending.tool_name,
                "url": pending.url, "redirect_uri": pending.redirect_uri,
                "expires_in": max(0, int(pending.expires_at - self._clock()))}

    async def _finish(self, pending: PendingAuthorization, status: str, *, code: str | None = None,
                      message: str | None = None) -> None:
        if pending.status != "pending":
            return
        pending.status = status
        self._pending.pop(pending.auth_id, None)
        if self._by_state.get(pending.state) is pending:
            del self._by_state[pending.state]
        if not pending.future.done():
            pending.future.set_result((status, code, pending.state if status == "authorized" else None, message))
        fields = {"auth_id": pending.auth_id, "uuid": pending.tool_uuid, "alias": pending.tool_name}
        if status == "authorized":
            connection_event("oauth.authorization.completed", **fields)
        elif status == "expired":
            connection_problem("oauth.authorization.expired", **fields)
        else:
            connection_problem("oauth.authorization.failed", reason=status, **fields)
        await self._emit(RESOLVED_FRAME, {"auth_id": pending.auth_id, "tool_uuid": pending.tool_uuid,
                                          "status": status})

    async def _expire_overdue(self) -> None:
        now = self._clock()
        for pending in list(self._pending.values()):
            if pending.expires_at <= now:
                await self._finish(pending, "expired")

    async def list_pending(self) -> list[PendingAuthorization]:
        await self._expire_overdue()
        return sorted(self._pending.values(), key=lambda item: item.created_at)

    def pending_for_tool(self, tool_uuid: str) -> PendingAuthorization | None:
        return next((item for item in self._pending.values() if item.tool_uuid == tool_uuid), None)

    def get(self, auth_id: str) -> PendingAuthorization | None:
        return self._pending.get(auth_id)

    async def complete(self, state: str | None, code: str | None, *, error: str | None = None,
                       error_description: str | None = None,
                       auth_id: str | None = None) -> PendingAuthorization:
        """Finish the authorization that owns ``state``; each state is usable exactly once."""
        await self._expire_overdue()
        pending = self._by_state.get(state or "")
        if pending is None or (auth_id is not None and pending.auth_id != auth_id):
            raise OAuthCallbackError("This sign-in link is unknown, has expired, or was already used.")
        if error:
            await self._finish(pending, "denied", message=error_description or error)
            return pending
        if not code:
            raise OAuthCallbackError("The sign-in response did not contain an authorization code.")
        await self._finish(pending, "authorized", code=code)
        return pending

    async def complete_from_url(self, auth_id: str, redirect_url: str) -> PendingAuthorization:
        """Paste fallback: the full address the browser ended on."""
        if self.get(auth_id) is None:
            await self._expire_overdue()
            raise KeyError(auth_id)
        try:
            params = _query(redirect_url.strip())
        except ValueError as problem:
            _LOG.warning("services.oauth.OAuthBroker.complete_from_url: unparsable redirect URL", exc_info=True)
            raise OAuthCallbackError("The pasted address is not a valid URL.") from problem
        return await self.complete(params.get("state"), params.get("code"), error=params.get("error"),
                                   error_description=params.get("error_description"), auth_id=auth_id)

    async def complete_from_params(self, auth_id: str, code: str | None,
                                   state: str | None) -> PendingAuthorization:
        if self.get(auth_id) is None:
            await self._expire_overdue()
            raise KeyError(auth_id)
        return await self.complete(state, code, auth_id=auth_id)

    async def cancel(self, auth_id: str) -> bool:
        pending = self._pending.get(auth_id)
        if pending is None:
            return False
        await self._finish(pending, "cancelled")
        return True

    async def cancel_for_tool(self, tool_uuid: str) -> None:
        for pending in [item for item in self._pending.values() if item.tool_uuid == tool_uuid]:
            await self._finish(pending, "cancelled")

    async def wait(self, pending: PendingAuthorization) -> tuple[str, str | None]:
        """Await the outcome; returns ``(code, state)`` or raises a descriptive error."""
        remaining = max(0.0, pending.expires_at - self._clock())
        try:
            status, code, state, message = await asyncio.wait_for(asyncio.shield(pending.future), remaining)
        except asyncio.TimeoutError:
            await self._finish(pending, "expired")
            raise TimeoutError(NOT_COMPLETED_IN_TIME) from None
        except asyncio.CancelledError:
            # The owning task (a cancelled turn / closed connection) is gone.
            await self._finish(pending, "cancelled")
            raise
        if status == "authorized":
            return code or "", state
        if status == "denied":
            raise OAuthDenied(f"Sign-in was denied: {message}" if message else "Sign-in was denied.")
        if status == "expired":
            raise TimeoutError(NOT_COMPLETED_IN_TIME)
        raise OAuthCancelled("Sign-in was cancelled.")

    def handlers(self, tool_uuid: str, tool_name: str, scopes: str | None = None) -> tuple[
            Callable[[str], Awaitable[None]], Callable[[], Awaitable[tuple[str, str | None]]]]:
        """``(redirect_handler, callback_handler)`` for one interactive provider."""
        current: list[PendingAuthorization] = []

        async def redirect_handler(url: str) -> None:
            if scopes:
                url = _with_scope(url, scopes)
            current[:] = [await self.register(tool_uuid, tool_name, url)]

        async def callback_handler() -> tuple[str, str | None]:
            if not current:
                raise OAuthCallbackError("No authorization is pending.")
            return await self.wait(current[0])

        return redirect_handler, callback_handler


def _with_scope(url: str, scopes: str) -> str:
    """The user's configured scopes win over the ones the SDK picked from server metadata."""
    parts = urlsplit(url)
    query = [(key, value) for key, value in parse_qsl(parts.query, keep_blank_values=True) if key != "scope"]
    query.append(("scope", scopes))
    return urlunsplit(parts._replace(query=urlencode(query)))


# --- storage + provider -----------------------------------------------------------------------
class ToolOAuthStorage:
    """The SDK ``TokenStorage`` for one tool, over the encrypted credential store."""

    def __init__(self, store: Any, tool_uuid: str, redirect_uri: str, client_id: str | None = None) -> None:
        self.store = store
        self.tool_uuid = tool_uuid
        self.redirect_uri = redirect_uri
        self.client_id = client_id
        self.provider: OAuthClientProvider | None = None

    async def get_tokens(self) -> OAuthToken | None:
        raw = (await self.store.get_tool_oauth(self.tool_uuid)).get("tokens")
        if not isinstance(raw, dict):
            return None
        try:
            return OAuthToken.model_validate(raw)
        except ValidationError:
            _LOG.warning("services.oauth.ToolOAuthStorage.get_tokens: stored tokens for %s are invalid",
                         self.tool_uuid, exc_info=True)
            return None

    async def set_tokens(self, tokens: OAuthToken) -> None:
        changes: dict[str, Any] = {
            "tokens": tokens.model_dump(mode="json", exclude_none=True),
            "expires_at": time.time() + tokens.expires_in if tokens.expires_in else None}
        context = getattr(self.provider, "context", None)
        # The SDK does not persist discovery results, but refreshing needs the token endpoint.
        if context is not None and context.oauth_metadata is not None:
            changes["oauth_metadata"] = context.oauth_metadata.model_dump(mode="json", exclude_none=True)
        if context is not None and context.protected_resource_metadata is not None:
            changes["resource_metadata"] = context.protected_resource_metadata.model_dump(
                mode="json", exclude_none=True)
        await self.store.patch_tool_oauth(self.tool_uuid, changes)

    async def get_client_info(self) -> OAuthClientInformationFull | None:
        state = await self.store.get_tool_oauth(self.tool_uuid)
        if self.client_id:  # a pre-registered client replaces dynamic registration
            secret = state.get("client_secret")
            return OAuthClientInformationFull(
                client_id=self.client_id, client_secret=secret or None, redirect_uris=[self.redirect_uri],  # type: ignore[list-item]
                token_endpoint_auth_method="client_secret_post" if secret else "none",
                grant_types=["authorization_code", "refresh_token"], response_types=["code"],
                client_name=CLIENT_NAME)
        raw = state.get("client_info")
        if not isinstance(raw, dict):
            return None
        try:
            return OAuthClientInformationFull.model_validate(raw)
        except ValidationError:
            _LOG.warning("services.oauth.ToolOAuthStorage.get_client_info: stored registration for %s is invalid",
                         self.tool_uuid, exc_info=True)
            return None

    async def set_client_info(self, client_info: OAuthClientInformationFull) -> None:
        await self.store.patch_tool_oauth(
            self.tool_uuid, {"client_info": client_info.model_dump(mode="json", exclude_none=True)})

    async def forget_stale_registration(self) -> None:
        """Drop a dynamic registration made for another redirect URI (the engine port changed)."""
        raw = (await self.store.get_tool_oauth(self.tool_uuid)).get("client_info")
        if not isinstance(raw, dict) or self.client_id:
            return
        registered = [str(item) for item in raw.get("redirect_uris") or []]
        if self.redirect_uri not in registered:
            await self.store.patch_tool_oauth(self.tool_uuid, {"client_info": None})

    async def restore(self) -> tuple[float | None, OAuthMetadata | None, ProtectedResourceMetadata | None]:
        """Access-token expiry and the discovery documents saved with the tokens."""
        state = await self.store.get_tool_oauth(self.tool_uuid)
        expiry = state.get("expires_at")
        return (float(expiry) if isinstance(expiry, (int, float)) else None,
                self._model(OAuthMetadata, state.get("oauth_metadata")),
                self._model(ProtectedResourceMetadata, state.get("resource_metadata")))

    @staticmethod
    def _model(model: Any, raw: Any) -> Any:
        if not isinstance(raw, dict):
            return None
        try:
            return model.model_validate(raw)
        except ValidationError:
            _LOG.warning("services.oauth.ToolOAuthStorage._model: stored discovery data is invalid", exc_info=True)
            return None


class StoredOAuthProvider(OAuthClientProvider):
    """The SDK provider, but a restart does not forget the token expiry or the token endpoint.

    Without this a stored but expired access token is treated as valid (-> a 401 and a brand new
    interactive sign-in) and a refresh would go to ``<origin>/token`` instead of the server's
    real token endpoint.
    """

    async def _initialize(self) -> None:
        await super()._initialize()
        storage = self.context.storage
        if isinstance(storage, ToolOAuthStorage):
            expiry, metadata, resource = await storage.restore()
            self.context.token_expiry_time = expiry
            if metadata is not None and self.context.oauth_metadata is None:
                self.context.oauth_metadata = metadata
            if resource is not None and self.context.protected_resource_metadata is None:
                self.context.protected_resource_metadata = resource


async def build_provider(tool_uuid: str, tool_name: str, server_url: str, config: Mapping[str, Any],
                         store: Any, broker: OAuthBroker, *, interactive: bool,
                         on_auth_required: Callable[[], None]) -> StoredOAuthProvider:
    """The ``auth=`` object for one MCP connection of an ``authType == oauth`` tool."""
    client_id = str(config.get("oauthClientId") or "").strip() or None
    scopes = str(config.get("oauthScopes") or "").strip() or None
    redirect_uri = broker.redirect_uri
    storage = ToolOAuthStorage(store, tool_uuid, redirect_uri, client_id)
    if interactive:
        await storage.forget_stale_registration()
    metadata = OAuthClientMetadata(
        redirect_uris=[redirect_uri],  # type: ignore[list-item]
        # Used for dynamic registration only: a public client (PKCE) on a loopback redirect.
        token_endpoint_auth_method="none",
        grant_types=["authorization_code", "refresh_token"], response_types=["code"],
        scope=scopes, client_name=CLIENT_NAME)
    if interactive:
        redirect_handler, callback_handler = broker.handlers(tool_uuid, tool_name, scopes)
    else:
        async def redirect_handler(url: str) -> None:
            on_auth_required()
            raise AuthorizationRequired("Sign-in required.")

        async def callback_handler() -> tuple[str, str | None]:
            raise AuthorizationRequired("Sign-in required.")

    provider = StoredOAuthProvider(server_url, metadata, storage, redirect_handler, callback_handler,
                                   timeout=broker.timeout)
    storage.provider = provider
    return provider


# --- the browser landing page -----------------------------------------------------------------
_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title}</title>
<style>body{{font-family:system-ui,sans-serif;margin:0;display:flex;min-height:100vh;align-items:center;
justify-content:center;background:#f6f6f8;color:#1c1c22}}main{{max-width:30rem;padding:2rem;background:#fff;
border-radius:12px;box-shadow:0 2px 12px rgba(0,0,0,.12)}}h1{{font-size:1.25rem;margin:0 0 .75rem}}
p{{margin:0;line-height:1.5}}</style></head>
<body><main><h1>{title}</h1><p>{message}</p></main></body></html>
"""


def result_page(title: str, message: str) -> str:
    """Self-contained HTML; every interpolated value is escaped."""
    return _PAGE.format(title=html.escape(title), message=html.escape(message))
