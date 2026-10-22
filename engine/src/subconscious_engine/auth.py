"""Bearer authentication for HTTP and WebSocket engine traffic."""

from dataclasses import dataclass
import secrets
from urllib.parse import parse_qs

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

from subconscious_engine.pairing import PairedClientStore


@dataclass(frozen=True, slots=True)
class EngineAuthToken:
    value: str

    @classmethod
    def generate(cls) -> "EngineAuthToken":
        return cls(secrets.token_urlsafe(32))


# The browser returns here after an OAuth consent page; it has no bearer token. The handler
# validates a single-use random `state` instead.
OAUTH_CALLBACK_PATH = "/api/v1/oauth/callback"

# Pairing: POST /api/v1/pair is public (it verifies a server assertion itself); everything
# under /api/v1/pair/ (client management) needs the master engine token.
PAIR_PATH = "/api/v1/pair"
PAIR_MANAGEMENT_PREFIX = "/api/v1/pair/"

PEER_STATE_KEY = "hive_peer_principal"


@dataclass(frozen=True, slots=True)
class PeerPrincipal:
    """An authenticated remote node; only the in-process tunnel may create one."""

    node_id: str
    role: str


def trusted_peer(scope: Scope) -> PeerPrincipal | None:
    """Return the tunnel-set principal. Real clients cannot place Python objects in
    ASGI scope state (servers build it from lifespan state, never from the wire)."""
    state = scope.get("state")
    value = state.get(PEER_STATE_KEY) if isinstance(state, dict) else None
    return value if isinstance(value, PeerPrincipal) else None


class BearerAuthMiddleware:
    def __init__(self, app: ASGIApp, token: EngineAuthToken,
                 paired_clients: PairedClientStore | None = None) -> None:
        self.app = app
        self.token = token
        self.paired_clients = paired_clients

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        path = scope.get("path", "")
        if not path.startswith("/api/v1") or path.startswith("/api/v1/health") \
                or (scope["type"] == "http" and path in (OAUTH_CALLBACK_PATH, PAIR_PATH)):
            await self.app(scope, receive, send)
            return
        master_only = path.startswith(PAIR_MANAGEMENT_PREFIX)
        if scope["type"] == "http" and not master_only and trusted_peer(scope) is not None:
            # Authenticated and authorised by the hive tunnel before dispatch.
            await self.app(scope, receive, send)
            return
        headers = {key.lower(): value for key, value in scope.get("headers", [])}
        authorization = headers.get(b"authorization", b"").decode("latin-1")
        presented = authorization[7:].strip() if authorization.lower().startswith("bearer ") else None
        if presented is None and scope["type"] == "websocket":
            query = parse_qs(scope.get("query_string", b"").decode("latin-1"))
            presented = query.get("token", [None])[0]
        allowed = secrets.compare_digest(
            (presented or "").encode("utf-8"), self.token.value.encode("utf-8")
        )
        # Paired client tokens never unlock token management.
        if not allowed and not master_only and presented and self.paired_clients is not None:
            allowed = self.paired_clients.verify(presented) is not None
        if not allowed:
            if scope["type"] == "websocket":
                await send({"type": "websocket.close", "code": 4401})
            else:
                await JSONResponse({"error": "Missing or invalid bearer token."}, 401)(scope, receive, send)
            return
        await self.app(scope, receive, send)
