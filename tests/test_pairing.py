import asyncio
from contextlib import asynccontextmanager
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import pytest

from subconscious_engine.account import AccountUser
from subconscious_engine.api.app import create_app
from subconscious_engine.auth import BearerAuthMiddleware, EngineAuthToken
from subconscious_engine.pairing import (
    LAST_USED_THROTTLE_SECONDS,
    PairedClientStore,
    RateLimiter,
    hash_token,
    is_extension_origin,
)
from subconscious_engine.storage import Database

ORIGIN = "chrome-extension://" + "a" * 32
MASTER = "secret-token"
NONCE = "n" * 24


def run(coro):
    return asyncio.run(coro)


class Clock:
    def __init__(self, now=1_000_000.0):
        self.now = now

    def __call__(self):
        return self.now


class FakeAccount:
    def __init__(self, user_id="user-1", signed_in=True):
        self.user = AccountUser(id=user_id, email="a@b.c", connected_providers=()) if signed_in else None
        self.token = "access-1" if signed_in else None
        self.server_base_url = "https://server.test/"
        self.refreshed = 0

    @property
    def current_account_user(self):
        return self.user

    def access_token(self):
        return self.token

    async def refresh_access_token(self):
        self.refreshed += 1
        self.token = "access-2"
        return self.token

    async def close(self):
        return None


class FakeServer:
    """Models the server's verify endpoint: single use, bound to nonce + origin."""

    def __init__(self, user_id="user-1"):
        self.user_id = user_id
        self.valid = {("good", NONCE, ORIGIN)}
        self.calls = []
        self.down = False
        self.expire_first_token = False

    def handler(self, request: httpx.Request) -> httpx.Response:
        if self.down:
            raise httpx.ConnectError("down", request=request)
        body = json.loads(request.content)
        self.calls.append((str(request.url), request.headers["authorization"], body))
        if self.expire_first_token and request.headers["authorization"] == "Bearer access-1":
            return httpx.Response(401, json={"detail": "expired"})
        key = (body["assertion"], body["client_nonce"], body["origin"])
        if key not in self.valid:
            return httpx.Response(404, json={"detail": "Invalid assertion"})
        self.valid.discard(key)
        return httpx.Response(200, json={"ok": True, "user_id": self.user_id})


@asynccontextmanager
async def pair_client(tmp_path, *, account=None, server=None, node_id="node-1"):
    account = account or FakeAccount()
    server = server or FakeServer()
    database = Database(tmp_path / "api.db")
    await database.initialize()
    app = create_app(database, EngineAuthToken(MASTER), account_session_service=account)
    app.state.hive_service = SimpleNamespace(identity=SimpleNamespace(node_id=node_id) if node_id else None)
    app.state.pairing_service._client = httpx.AsyncClient(transport=httpx.MockTransport(server.handler))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
        yield client, app, account, server
    await database.close()


def master():
    return {"Authorization": f"Bearer {MASTER}"}


def body(assertion="good", nonce=NONCE):
    return {"assertion": assertion, "client_nonce": nonce}


def origin_header(origin=ORIGIN):
    return {"Origin": origin}


# --- store -------------------------------------------------------------------------------------

def test_store_persists_only_hashes_and_reloads(tmp_path):
    path = tmp_path / "paired.json"
    store = PairedClientStore(path)
    token, record = store.add(ORIGIN)
    assert token.startswith("scp_")
    text = path.read_text(encoding="utf-8")
    assert token not in text
    assert hash_token(token) in text
    reloaded = PairedClientStore(path)
    assert reloaded.verify(token).id == record.id
    assert reloaded.verify(token + "x") is None
    assert reloaded.verify("garbage") is None


def test_store_evicts_oldest_beyond_cap(tmp_path):
    clock = Clock()
    store = PairedClientStore(tmp_path / "p.json", clock=clock, max_clients=3)
    tokens = []
    for _ in range(4):
        clock.now += 1
        tokens.append(store.add(ORIGIN)[0])
    assert store.verify(tokens[0]) is None
    assert all(store.verify(token) for token in tokens[1:])
    assert len(store.list()) == 3


def test_store_expiry_and_sliding_with_throttled_last_used(tmp_path):
    clock = Clock()
    store = PairedClientStore(tmp_path / "p.json", clock=clock, ttl_seconds=100, throttle_seconds=10)
    token, record = store.add(ORIGIN)
    created = record.last_used_at
    clock.now += 5
    assert store.verify(token).last_used_at == created  # throttled: not updated
    clock.now += 10
    refreshed = store.verify(token)
    assert refreshed.last_used_at == clock.now
    assert refreshed.expires_at == clock.now + 100  # sliding
    clock.now += 101
    assert store.verify(token) is None
    assert store.list() == []


def test_store_throttle_default_and_revoke(tmp_path):
    assert LAST_USED_THROTTLE_SECONDS >= 30
    store = PairedClientStore(tmp_path / "p.json")
    token, record = store.add(ORIGIN)
    assert store.revoke(record.id) is True
    assert store.revoke(record.id) is False
    assert store.verify(token) is None
    assert PairedClientStore(tmp_path / "p.json").list() == []


def test_store_survives_corrupt_file(tmp_path):
    path = tmp_path / "p.json"
    path.write_text("{not json", encoding="utf-8")
    assert PairedClientStore(path).list() == []


def test_origin_patterns_and_rate_limiter():
    assert is_extension_origin(ORIGIN)
    assert is_extension_origin("moz-extension://123e4567-e89b-12d3-a456-426614174000")
    for bad in (None, "", "http://localhost", "chrome-extension://short", ORIGIN + "x", "https://evil.com"):
        assert not is_extension_origin(bad)
    clock = Clock(0)
    limiter = RateLimiter(2, 60, clock)
    assert limiter.allow("k") and limiter.allow("k") and not limiter.allow("k")
    assert limiter.allow("other")
    clock.now = 61
    assert limiter.allow("k")


# --- middleware --------------------------------------------------------------------------------

def _scope(kind="http", path="/api/v1/models", token=None, query=b"", method="GET"):
    headers = [(b"authorization", f"Bearer {token}".encode())] if token else []
    return {"type": kind, "path": path, "headers": headers, "query_string": query, "method": method}


async def _invoke(middleware, scope):
    messages = []

    async def send(message):
        messages.append(message)

    await middleware(scope, AsyncMock(), send)
    return messages


def test_middleware_accepts_master_and_paired_rejects_revoked_expired_garbage(tmp_path):
    clock = Clock()
    store = PairedClientStore(tmp_path / "p.json", clock=clock, ttl_seconds=100)
    token, record = store.add(ORIGIN)
    app = AsyncMock()
    middleware = BearerAuthMiddleware(app, EngineAuthToken(MASTER), store)
    assert run(_invoke(middleware, _scope(token=MASTER))) == []
    assert run(_invoke(middleware, _scope(token=token))) == []
    assert app.await_count == 2
    for bad in ("scp_garbage", "garbage", None):
        messages = run(_invoke(middleware, _scope(token=bad)))
        assert messages[0]["status"] == 401
    store.revoke(record.id)
    assert run(_invoke(middleware, _scope(token=token)))[0]["status"] == 401
    token2, _ = store.add(ORIGIN)
    clock.now += 1000
    assert run(_invoke(middleware, _scope(token=token2)))[0]["status"] == 401


def test_middleware_websocket_query_token_for_paired_client(tmp_path):
    store = PairedClientStore(tmp_path / "p.json")
    token, _ = store.add(ORIGIN)
    app = AsyncMock()
    middleware = BearerAuthMiddleware(app, EngineAuthToken(MASTER), store)
    assert run(_invoke(middleware, _scope("websocket", "/api/v1/events", query=f"token={token}".encode()))) == []
    app.assert_awaited_once()
    closed = run(_invoke(middleware, _scope("websocket", "/api/v1/events", query=b"token=scp_nope")))
    assert closed == [{"type": "websocket.close", "code": 4401}]


def test_pair_management_requires_master_token(tmp_path):
    async def scenario():
        async with pair_client(tmp_path) as (client, app, _, _):
            token, record = app.state.paired_clients.add(ORIGIN)
            paired = {"Authorization": f"Bearer {token}"}
            assert (await client.get("/api/v1/workspaces", headers=paired)).status_code == 200
            assert (await client.get("/api/v1/pair/clients", headers=paired)).status_code == 401
            assert (await client.delete(f"/api/v1/pair/clients/{record.id}", headers=paired)).status_code == 401
            assert (await client.get("/api/v1/pair/clients")).status_code == 401
            listing = await client.get("/api/v1/pair/clients", headers=master())
            assert listing.status_code == 200
            text = listing.text
            assert "token_hash" not in text and hash_token(token) not in text
            assert listing.json()["clients"][0]["id"] == record.id
            assert (await client.delete(f"/api/v1/pair/clients/{record.id}", headers=master())).status_code == 200
            assert (await client.delete(f"/api/v1/pair/clients/{record.id}", headers=master())).status_code == 404
            assert (await client.get("/api/v1/workspaces", headers=paired)).status_code == 401
    run(scenario())


# --- pair flow ---------------------------------------------------------------------------------

def test_health_reports_node_id(tmp_path):
    async def scenario():
        async with pair_client(tmp_path) as (client, app, _, _):
            assert (await client.get("/api/v1/health")).json()["node_id"] == "node-1"
        async with pair_client(tmp_path, node_id=None) as (client, _, _, _):
            assert (await client.get("/api/v1/health")).json()["node_id"] is None
    run(scenario())


def test_pair_success_then_replay_rejected_and_token_works(tmp_path):
    async def scenario():
        async with pair_client(tmp_path) as (client, app, _, server):
            ok = await client.post("/api/v1/pair", json=body(), headers=origin_header())
            assert ok.status_code == 200, ok.text
            data = ok.json()
            assert data["token"].startswith("scp_") and data["client_id"] and data["expires_at"] > 0
            url, auth_header, sent = server.calls[0]
            assert url == "https://server.test/nodes/node-1/pairing-assertion/verify"
            assert auth_header == "Bearer access-1"
            assert sent == {"assertion": "good", "client_nonce": NONCE, "origin": ORIGIN}
            assert (await client.get("/api/v1/workspaces",
                                     headers={"Authorization": f"Bearer {data['token']}"})).status_code == 200
            assert data["token"] not in (tmp_path / "paired_clients.json").read_text(encoding="utf-8")
            replay = await client.post("/api/v1/pair", json=body(), headers=origin_header())
            assert replay.status_code == 404
    run(scenario())


def test_pair_rejects_bad_or_missing_origin(tmp_path):
    async def scenario():
        async with pair_client(tmp_path) as (client, _, _, server):
            assert (await client.post("/api/v1/pair", json=body())).status_code == 403
            for origin in ("http://localhost:3000", "https://evil.com", "chrome-extension://short"):
                assert (await client.post("/api/v1/pair", json=body(), headers=origin_header(origin))).status_code == 403
            assert server.calls == []
    run(scenario())


def test_pair_wrong_account_not_signed_in_and_server_down(tmp_path):
    async def scenario():
        async with pair_client(tmp_path, server=FakeServer(user_id="someone-else")) as (client, app, _, _):
            response = await client.post("/api/v1/pair", json=body(), headers=origin_header())
            assert response.status_code == 401
            assert app.state.paired_clients.list() == []
        async with pair_client(tmp_path, account=FakeAccount(signed_in=False)) as (client, _, _, server):
            assert (await client.post("/api/v1/pair", json=body(), headers=origin_header())).status_code == 401
            assert server.calls == []
        down = FakeServer()
        down.down = True
        async with pair_client(tmp_path, server=down) as (client, _, _, _):
            assert (await client.post("/api/v1/pair", json=body(), headers=origin_header())).status_code == 503
    run(scenario())


def test_pair_refreshes_expired_access_token_once(tmp_path):
    async def scenario():
        server = FakeServer()
        server.expire_first_token = True
        async with pair_client(tmp_path, server=server) as (client, _, account, _):
            response = await client.post("/api/v1/pair", json=body(), headers=origin_header())
            assert response.status_code == 200
            assert account.refreshed == 1
            assert server.calls[-1][1] == "Bearer access-2"
    run(scenario())


def test_pair_validates_body_and_rate_limits(tmp_path):
    async def scenario():
        async with pair_client(tmp_path) as (client, _, _, _):
            short = await client.post("/api/v1/pair", json=body(nonce="short"), headers=origin_header())
            assert short.status_code == 400
            statuses = [
                (await client.post("/api/v1/pair", json=body("bad"), headers=origin_header())).status_code
                for _ in range(6)
            ]
            assert statuses[-1] == 429
            # A different origin has its own budget.
            other = "chrome-extension://" + "b" * 32
            assert (await client.post("/api/v1/pair", json=body("bad"), headers=origin_header(other))).status_code == 404
    run(scenario())


def test_cors_preflight_allows_extension_delete_and_pair(tmp_path):
    async def scenario():
        async with pair_client(tmp_path) as (client, _, _, _):
            response = await client.options(
                "/api/v1/pair",
                headers={"Origin": ORIGIN, "Access-Control-Request-Method": "POST",
                         "Access-Control-Request-Headers": "content-type"},
            )
            assert response.status_code == 200
            assert response.headers["access-control-allow-origin"] == ORIGIN
    run(scenario())
