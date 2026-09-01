"""Bearer authentication for HTTP and WebSocket engine traffic."""

from dataclasses import dataclass
import secrets
from urllib.parse import parse_qs

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send


@dataclass(frozen=True, slots=True)
class EngineAuthToken:
    value: str

    @classmethod
    def generate(cls) -> "EngineAuthToken":
        return cls(secrets.token_urlsafe(32))


class BearerAuthMiddleware:
    def __init__(self, app: ASGIApp, token: EngineAuthToken) -> None:
        self.app = app
        self.token = token

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        path = scope.get("path", "")
        if not path.startswith("/api/v1") or path.startswith("/api/v1/health"):
            await self.app(scope, receive, send)
            return
        headers = {key.lower(): value for key, value in scope.get("headers", [])}
        authorization = headers.get(b"authorization", b"").decode("latin-1")
        presented = authorization[7:].strip() if authorization.lower().startswith("bearer ") else None
        if presented is None and scope["type"] == "websocket":
            query = parse_qs(scope.get("query_string", b"").decode("latin-1"))
            presented = query.get("token", [None])[0]
        if not secrets.compare_digest(presented or "", self.token.value):
            if scope["type"] == "websocket":
                await send({"type": "websocket.close", "code": 4401})
            else:
                await JSONResponse({"error": "Missing or invalid bearer token."}, 401)(scope, receive, send)
            return
        await self.app(scope, receive, send)
