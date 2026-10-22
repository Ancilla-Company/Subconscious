"""A tiny OAuth-protected MCP server for tests: everything runs in-process on loopback.

Implements just enough of the MCP authorization spec for the SDK's OAuthClientProvider:
protected-resource + authorization-server metadata, dynamic client registration, /authorize
(302 back to the redirect URI), /token (authorization_code with S256 PKCE verified, and
refresh_token), and a streamable-HTTP MCP endpoint (FastMCP) that requires a Bearer token.

    async with fake_oauth_mcp() as fake:
        fake.url            # the MCP endpoint, http://127.0.0.1:<port>/mcp
        fake.access_ttl     # lifetime (s) of issued access tokens; tests shorten it
"""

import asyncio
import base64
import hashlib
import secrets
import socket
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from urllib.parse import urlencode

import uvicorn
from mcp.server.fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse, RedirectResponse, Response


@dataclass
class FakeOAuthServer:
    port: int = 0
    access_ttl: int = 3600
    require_client_secret: str | None = None  # a pre-registered confidential client
    clients: dict = field(default_factory=dict)
    codes: dict = field(default_factory=dict)
    access_tokens: dict = field(default_factory=dict)  # token -> expiry (monotonic seconds)
    refresh_tokens: dict = field(default_factory=dict)
    registrations: int = 0
    token_grants: list = field(default_factory=list)
    mcp_requests_without_token: int = 0
    scopes_requested: list = field(default_factory=list)

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    @property
    def url(self) -> str:
        return f"{self.base}/mcp"

    def revoke_access_tokens(self) -> None:
        self.access_tokens.clear()

    def expire_access_tokens(self) -> None:
        for token in self.access_tokens:
            self.access_tokens[token] = 0.0


def _valid(fake: FakeOAuthServer, header: str) -> bool:
    import time
    token = header[7:].strip() if header.lower().startswith("bearer ") else ""
    expiry = fake.access_tokens.get(token)
    return expiry is not None and expiry > time.monotonic()


class _BearerGate:
    """Pure ASGI (streaming-safe): 401 + WWW-Authenticate unless the Bearer token is valid."""

    def __init__(self, app, fake: FakeOAuthServer) -> None:
        self.app, self.fake = app, fake

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and scope["path"].startswith("/mcp"):
            headers = {k.lower(): v for k, v in scope["headers"]}
            if not _valid(self.fake, headers.get(b"authorization", b"").decode()):
                self.fake.mcp_requests_without_token += 1
                challenge = (f'Bearer resource_metadata="{self.fake.base}/.well-known/oauth-protected-resource"')
                await Response(status_code=401, headers={"WWW-Authenticate": challenge})(scope, receive, send)
                return
        await self.app(scope, receive, send)


def build_app(fake: FakeOAuthServer):
    import time
    mcp = FastMCP("fake-protected", host="127.0.0.1")

    @mcp.tool()
    def ping() -> str:
        """Reply with pong."""
        return "pong"

    app = mcp.streamable_http_app()

    async def protected_resource(request: Request):
        return JSONResponse({"resource": fake.url, "authorization_servers": [fake.base],
                             "scopes_supported": ["mail.read"], "bearer_methods_supported": ["header"]})

    async def server_metadata(request: Request):
        return JSONResponse({
            "issuer": fake.base, "authorization_endpoint": f"{fake.base}/authorize",
            "token_endpoint": f"{fake.base}/oauth/token", "registration_endpoint": f"{fake.base}/register",
            "response_types_supported": ["code"], "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["S256"],
            "token_endpoint_auth_methods_supported": ["none", "client_secret_post"]})

    async def register(request: Request):
        body = await request.json()
        fake.registrations += 1
        client_id = f"dyn-{fake.registrations}"
        fake.clients[client_id] = {"redirect_uris": body["redirect_uris"], "secret": None}
        return JSONResponse({**body, "client_id": client_id}, 201)

    async def authorize(request: Request):
        query = request.query_params
        client = fake.clients.get(query.get("client_id", ""))
        if client is None or (client["redirect_uris"] is not None
                                   and query.get("redirect_uri") not in client["redirect_uris"]) \
                or query.get("code_challenge_method") != "S256":
            return JSONResponse({"error": "invalid_request"}, 400)
        fake.scopes_requested.append(query.get("scope"))
        code = secrets.token_urlsafe(16)
        fake.codes[code] = {"challenge": query["code_challenge"], "client_id": query["client_id"],
                            "redirect_uri": query["redirect_uri"]}
        return RedirectResponse(f"{query['redirect_uri']}?{urlencode({'code': code, 'state': query['state']})}", 302)

    def issue(client_id: str) -> dict:
        access, refresh = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
        fake.access_tokens[access] = time.monotonic() + fake.access_ttl
        fake.refresh_tokens[refresh] = client_id
        return {"access_token": access, "token_type": "Bearer", "expires_in": fake.access_ttl,
                "refresh_token": refresh}

    async def token(request: Request):
        form = dict((await request.form()).items())
        grant = form.get("grant_type")
        fake.token_grants.append(grant)
        client_id = form.get("client_id", "")
        if client_id not in fake.clients:
            return JSONResponse({"error": "invalid_client"}, 401)
        secret = fake.clients[client_id]["secret"]
        if secret is not None and form.get("client_secret") != secret:
            return JSONResponse({"error": "invalid_client"}, 401)
        if grant == "authorization_code":
            record = fake.codes.pop(form.get("code", ""), None)
            if record is None or record["client_id"] != client_id or record["redirect_uri"] != form.get("redirect_uri"):
                return JSONResponse({"error": "invalid_grant"}, 400)
            digest = hashlib.sha256(form.get("code_verifier", "").encode()).digest()
            if base64.urlsafe_b64encode(digest).decode().rstrip("=") != record["challenge"]:
                return JSONResponse({"error": "invalid_grant", "error_description": "PKCE mismatch"}, 400)
            return JSONResponse(issue(client_id))
        if grant == "refresh_token":
            if fake.refresh_tokens.pop(form.get("refresh_token", ""), None) != client_id:
                return JSONResponse({"error": "invalid_grant"}, 400)
            return JSONResponse(issue(client_id))
        return JSONResponse({"error": "unsupported_grant_type"}, 400)

    for path, handler, methods in (
            ("/.well-known/oauth-protected-resource", protected_resource, ["GET"]),
            ("/.well-known/oauth-protected-resource/mcp", protected_resource, ["GET"]),
            ("/.well-known/oauth-authorization-server", server_metadata, ["GET"]),
            ("/register", register, ["POST"]), ("/authorize", authorize, ["GET"]), ("/oauth/token", token, ["POST"])):
        app.add_route(path, handler, methods=methods)
    return _BearerGate(app, fake)


@asynccontextmanager
async def fake_oauth_mcp(**options):
    from sse_starlette.sse import AppStatus
    AppStatus.should_exit_event = None  # sse_starlette keeps a process-global Event bound to the first loop
    fake = FakeOAuthServer(**options)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    listener.listen(64)
    fake.port = listener.getsockname()[1]
    if fake.require_client_secret is not None:
        fake.clients["preregistered"] = {"redirect_uris": None, "secret": fake.require_client_secret}
    server = uvicorn.Server(uvicorn.Config(build_app(fake), log_level="warning", log_config=None))
    task = asyncio.ensure_future(server.serve(sockets=[listener]))
    while not server.started:
        if task.done():
            await task
        await asyncio.sleep(0.01)
    try:
        yield fake
    finally:
        server.should_exit = True
        await task
        listener.close()
