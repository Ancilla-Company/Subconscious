"""REST over the ``rpc`` data channel.

Requests are authorised against the peer's role allowlist first, then executed
against the in-process ASGI app. The outermost ASGI wrapper sets
``scope["state"]["hive_peer_principal"]`` to a :class:`PeerPrincipal` object;
``BearerAuthMiddleware`` trusts only that exact type, which no network client can
produce (ASGI servers build ``scope["state"]`` from lifespan state, never from
request bytes). Peer requests never carry, and never receive, the engine bearer.

Request:  ``{id, type:"http.request", data:{method, path, query, headers, body}}``
Response: ``{id, type:"http.response", data:{status, headers, body}}``
``body`` is base64 so binary payloads survive; large bodies ride on chunking.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import logging
from typing import Any
from urllib.parse import urlencode

import httpx
from starlette.types import ASGIApp, Receive, Scope, Send

from subconscious_engine.auth import PEER_STATE_KEY, PeerPrincipal

from .authz import authorize_http, normalise_path
from .channels import Envelope

_LOGGER = logging.getLogger("uvicorn.error")
MAX_REQUEST_BODY_BYTES = 4 * 1024 * 1024
MAX_RESPONSE_BODY_BYTES = 6 * 1024 * 1024
MAX_IN_FLIGHT = 8
REQUEST_TIMEOUT_SECONDS = 60.0
ALLOWED_REQUEST_HEADERS = frozenset({"content-type", "accept", "accept-language"})
ALLOWED_RESPONSE_HEADERS = frozenset({"content-type", "etag", "cache-control"})
ALLOWED_METHODS = frozenset({"GET", "POST", "PUT", "DELETE"})


class _PrincipalScope:
    """Outermost ASGI wrapper: stamps the tunnel principal onto the scope."""

    def __init__(self, app: ASGIApp, principal: PeerPrincipal) -> None:
        self._app = app
        self._principal = principal

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        state = dict(scope.get("state") or {})
        state[PEER_STATE_KEY] = self._principal
        await self._app({**scope, "state": state}, receive, send)


def _error(identifier: str | None, status: int, message: str) -> Envelope:
    return Envelope(
        "http.response",
        {"status": status, "headers": {"content-type": "application/json"},
         "body": base64.b64encode(f'{{"error":"{message}"}}'.encode()).decode("ascii")},
        identifier,
    )


class HttpTunnel:
    """Executes tunnelled requests for one peer link."""

    def __init__(self, app: ASGIApp, principal: PeerPrincipal) -> None:
        self._principal = principal
        self._client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=_PrincipalScope(app, principal)),
            base_url="http://hive.invalid",
            timeout=REQUEST_TIMEOUT_SECONDS,
        )
        self._slots = asyncio.Semaphore(MAX_IN_FLIGHT)
        self._in_flight = 0

    async def aclose(self) -> None:
        await self._client.aclose()

    async def handle(self, envelope: Envelope) -> Envelope:
        """Authorise and run one ``http.request`` envelope; always returns a response."""
        identifier = envelope.id
        if envelope.type != "http.request" or not isinstance(envelope.data, dict):
            return _error(identifier, 400, "Malformed request.")
        data: dict[str, Any] = envelope.data
        method, path = data.get("method"), data.get("path")
        if not isinstance(method, str) or not isinstance(path, str):
            return _error(identifier, 400, "Malformed request.")
        method = method.upper()
        if method not in ALLOWED_METHODS or normalise_path(path) is None:
            return _error(identifier, 400, "Malformed request.")
        if not authorize_http(self._principal.role, method, path):
            return _error(identifier, 403, "Forbidden for this node.")
        try:
            body = self._decode_body(data.get("body"))
            query = self._query(data.get("query"))
        except ValueError as problem:
            return _error(identifier, 400, str(problem))
        if self._in_flight >= MAX_IN_FLIGHT:
            return _error(identifier, 429, "Too many requests.")
        self._in_flight += 1
        try:
            response = await self._client.request(
                method,
                normalise_path(path) or path,
                params=query,
                content=body,
                headers=self._headers(data.get("headers")),
            )
        except Exception:
            _LOGGER.debug("Tunnelled request failed.", exc_info=True)
            return _error(identifier, 502, "Request failed.")
        finally:
            self._in_flight -= 1
        content = response.content
        if len(content) > MAX_RESPONSE_BODY_BYTES:
            return _error(identifier, 502, "Response too large.")
        return Envelope(
            "http.response",
            {
                "status": response.status_code,
                "headers": {
                    k.lower(): v
                    for k, v in response.headers.items()
                    if k.lower() in ALLOWED_RESPONSE_HEADERS
                },
                "body": base64.b64encode(content).decode("ascii"),
            },
            identifier,
        )

    @staticmethod
    def _decode_body(value: Any) -> bytes:
        if value in (None, ""):
            return b""
        if not isinstance(value, str):
            raise ValueError("Body must be base64 text.")
        try:
            body = base64.b64decode(value, validate=True)
        except (binascii.Error, ValueError) as error:
            raise ValueError("Body is not valid base64.") from error
        if len(body) > MAX_REQUEST_BODY_BYTES:
            raise ValueError("Body too large.")
        return body

    @staticmethod
    def _query(value: Any) -> str:
        if value in (None, ""):
            return ""
        if isinstance(value, str):
            return value.lstrip("?")[:4096]
        if isinstance(value, dict):
            pairs = [(str(k), str(v)) for k, v in value.items()]
            return urlencode(pairs)[:4096]
        raise ValueError("Query must be a string or object.")

    @staticmethod
    def _headers(value: Any) -> dict[str, str]:
        if not isinstance(value, dict):
            return {}
        return {
            str(k).lower(): str(v)[:256]
            for k, v in value.items()
            if str(k).lower() in ALLOWED_REQUEST_HEADERS
        }
