"""OAuth for remote MCP tools: broker, storage, REST endpoints and a real end-to-end sign-in.

The end-to-end tests run the MCP SDK's OAuthClientProvider against ``fixtures/oauth_fake_server``
(in-process uvicorn on loopback: discovery, dynamic client registration, PKCE, token + refresh, a
Bearer-protected FastMCP endpoint). The only step not performed by a real browser is the consent
page: the tests GET the authorization URL themselves and hand the 302 target to the engine callback.
"""
import asyncio
import json
import logging
import sys
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest
from cryptography.fernet import Fernet

from subconscious_engine.api.app import create_app
from subconscious_engine.approval import ApprovalConfig
from subconscious_engine.auth import EngineAuthToken
from subconscious_engine.configuration import EncryptedModelConfigurationStore
from subconscious_engine.services.oauth import (
    OAuthBroker,
    OAuthCallbackError,
    OAuthCancelled,
    OAuthDenied,
    result_page,
)
from subconscious_engine.storage import Database
from test_api import FakeBuiltinTools, FakeRag, auth, run

sys.path.insert(0, str(Path(__file__).parent / "fixtures"))
from oauth_fake_server import fake_oauth_mcp  # noqa: E402

ENGINE_PORT = 51516
CALLBACK = f"http://127.0.0.1:{ENGINE_PORT}/api/v1/oauth/callback"


@dataclass
class StaticKeyProvider:
    key: str

    def get_or_create_key(self) -> str:
        return self.key


@asynccontextmanager
async def oauth_app(tmp_path, **broker_options):
    """The real app on a real encrypted store; yields (client, app, store)."""
    database = Database(tmp_path / "oauth.db")
    await database.initialize()
    store = EncryptedModelConfigurationStore(tmp_path, StaticKeyProvider(Fernet.generate_key().decode("ascii")))
    app = create_app(database, EngineAuthToken("secret-token"), model_configuration_store=store,
                     rag_service=FakeRag(), tool_registry=FakeBuiltinTools(), dev_models=True)
    app.state.oauth_broker.set_port(ENGINE_PORT)
    for name, value in broker_options.items():
        setattr(app.state.oauth_broker, name, value)
    transport = httpx.ASGITransport(app=app)
    try:
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            yield client, app, store
    finally:
        await app.state.configured_tools.close()
        await database.close()


async def create_oauth_tool(client, url, alias="Mail", **extra):
    response = await client.post("/api/v1/tool-registry", headers=auth(), json={
        "alias": alias, "toolType": "mcp", "endpointUrl": url, "authType": "oauth", **extra})
    assert response.status_code == 201, response.text
    return response.json()


async def wait_for(predicate, timeout=15.0, interval=0.05):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = await predicate() if asyncio.iscoroutinefunction(predicate) else predicate()
        if value:
            return value
        await asyncio.sleep(interval)
    raise AssertionError("condition not reached in time")


async def browse(authorization_url):
    """What the user's browser does at the consent page: follow the 302 to the redirect URI."""
    async with httpx.AsyncClient() as browser:
        response = await browser.get(authorization_url, follow_redirects=False)
    assert response.status_code == 302, response.text
    return response.headers["location"]


def callback_path(location):
    parts = urlsplit(location)
    return f"{parts.path}?{parts.query}"


# --- broker ----------------------------------------------------------------------------------------
def authorization_url(state="state-1"):
    return f"https://auth.example/authorize?response_type=code&client_id=c&state={state}&scope=a"


def make_broker(**options):
    broker = OAuthBroker(**options)
    broker.set_port(ENGINE_PORT)
    return broker


def test_broker_completes_once_validates_state_and_notifies_listeners():
    async def scenario():
        broker = make_broker()
        frames = []

        async def notify(frame_type, data):
            frames.append((frame_type, data))

        broker.attach("turn-1", notify)
        redirect_handler, callback_handler = broker.handlers("tool-1", "Mail")
        await redirect_handler(authorization_url("s-1"))
        pending = broker.pending_for_tool("tool-1")
        assert pending.state == "s-1" and pending.redirect_uri == CALLBACK
        assert frames[0][0] == "oauth.request"
        assert frames[0][1]["auth_id"] == pending.auth_id and frames[0][1]["tool_name"] == "Mail"
        assert frames[0][1]["redirect_uri"] == CALLBACK and 590 <= frames[0][1]["expires_in"] <= 600
        assert [item.auth_id for item in await broker.list_pending()] == [pending.auth_id]
        waiting = asyncio.ensure_future(callback_handler())
        with pytest.raises(OAuthCallbackError):  # unknown state
            await broker.complete("nope", "code")
        with pytest.raises(OAuthCallbackError):  # no code
            await broker.complete("s-1", None)
        assert not waiting.done()
        await broker.complete("s-1", "the-code")
        assert await waiting == ("the-code", "s-1")
        with pytest.raises(OAuthCallbackError):  # replay: a state is single use
            await broker.complete("s-1", "the-code")
        assert frames[-1] == ("oauth.resolved", {"auth_id": pending.auth_id, "tool_uuid": "tool-1",
                                                 "status": "authorized"})
        assert await broker.list_pending() == []
        broker.detach("turn-1")
        await broker.register("tool-1", "Mail", authorization_url("s-2"))
        assert len(frames) == 2  # detached listeners hear nothing

    run(scenario())


def test_broker_error_callback_denies_and_cancel_and_expiry():
    async def scenario():
        now = [1000.0]
        broker = make_broker(timeout=600, clock=lambda: now[0])
        redirect_handler, callback_handler = broker.handlers("t", "Mail")
        await redirect_handler(authorization_url("s-denied"))
        waiting = asyncio.ensure_future(callback_handler())
        pending = await broker.complete("s-denied", None, error="access_denied", error_description="Nope")
        assert pending.status == "denied"
        with pytest.raises(OAuthDenied, match="Nope"):
            await waiting

        redirect_handler, callback_handler = broker.handlers("t", "Mail")
        await redirect_handler(authorization_url("s-cancel"))
        waiting = asyncio.ensure_future(callback_handler())
        assert await broker.cancel(broker.pending_for_tool("t").auth_id) is True
        assert await broker.cancel("unknown") is False
        with pytest.raises(OAuthCancelled):
            await waiting

        redirect_handler, callback_handler = broker.handlers("t", "Mail")
        await redirect_handler(authorization_url("s-late"))
        now[0] += 601
        with pytest.raises(OAuthCallbackError):  # expired states are refused
            await broker.complete("s-late", "code")
        assert broker.pending_for_tool("t") is None
        with pytest.raises(TimeoutError, match="Sign-in was not completed in time."):
            await callback_handler()

    run(scenario())


def test_broker_wait_times_out_with_a_clear_error():
    async def scenario():
        broker = make_broker(timeout=0.2)
        redirect_handler, callback_handler = broker.handlers("t", "Mail")
        await redirect_handler(authorization_url("s-slow"))
        with pytest.raises(TimeoutError, match="Sign-in was not completed in time."):
            await callback_handler()
        assert broker.pending_for_tool("t") is None

    run(scenario())


def test_broker_paste_fallback_validates_the_state_of_the_chosen_authorization():
    async def scenario():
        broker = make_broker()
        first, _ = broker.handlers("t1", "A")
        second, _ = broker.handlers("t2", "B")
        await first(authorization_url("s-a"))
        await second(authorization_url("s-b"))
        a, b = broker.pending_for_tool("t1"), broker.pending_for_tool("t2")
        with pytest.raises(KeyError):
            await broker.complete_from_url("missing", f"{CALLBACK}?code=c&state=s-a")
        with pytest.raises(OAuthCallbackError):  # a's state cannot complete b
            await broker.complete_from_url(b.auth_id, f"{CALLBACK}?code=c&state=s-a")
        done = await broker.complete_from_url(a.auth_id, f"{CALLBACK}?code=c1&state=s-a")
        assert done.status == "authorized"
        done = await broker.complete_from_params(b.auth_id, "c2", "s-b")
        assert done.status == "authorized"
        with pytest.raises(OAuthCallbackError):
            await broker.complete_from_params(b.auth_id, "c2", "s-b") if broker.get(b.auth_id) else \
                await broker.complete("s-b", "c2")

    run(scenario())


def test_broker_needs_a_port_and_a_state_and_never_logs_secrets(caplog):
    async def scenario():
        broker = OAuthBroker()
        with pytest.raises(RuntimeError):
            broker.redirect_uri
        broker.set_port(0)
        assert broker.port is None
        broker.set_port(4321)
        broker.set_port(9999, overwrite=False)
        assert broker.redirect_uri == "http://127.0.0.1:4321/api/v1/oauth/callback"
        redirect_handler, _ = broker.handlers("t", "Mail")
        with pytest.raises(OAuthCallbackError):
            await redirect_handler("https://auth.example/authorize?client_id=c")
        await redirect_handler(authorization_url("SECRET-STATE-VALUE"))
        await broker.complete("SECRET-STATE-VALUE", "SECRET-CODE-VALUE")

    with caplog.at_level(logging.DEBUG):
        run(scenario())
    assert "oauth.authorization.requested" in caplog.text and "oauth.authorization.completed" in caplog.text
    assert "SECRET-CODE-VALUE" not in caplog.text and "SECRET-STATE-VALUE" not in caplog.text


def test_scope_override_replaces_the_sdk_scope_in_the_authorization_url():
    async def scenario():
        broker = make_broker()
        redirect_handler, _ = broker.handlers("t", "Mail", scopes="mail.read mail.send")
        await redirect_handler(authorization_url("s-scope"))
        query = parse_qs(urlsplit(broker.pending_for_tool("t").url).query)
        assert query["scope"] == ["mail.read mail.send"] and query["state"] == ["s-scope"]

    run(scenario())


def test_result_page_escapes_every_value():
    page = result_page("<b>x</b>", '"><script>alert(1)</script>')
    assert "<script>" not in page and "&lt;script&gt;" in page and "&lt;b&gt;" in page


# --- REST: callback / pending / complete / cancel -----------------------------------------------------
def test_callback_is_public_but_every_other_oauth_route_needs_the_bearer_token(tmp_path):
    async def scenario():
        async with oauth_app(tmp_path) as (client, app, _):
            response = await client.get("/api/v1/oauth/callback?code=c&state=unknown")
            assert response.status_code == 400  # reached the handler, no 401
            assert response.headers["cache-control"] == "no-store"
            assert response.headers["referrer-policy"] == "no-referrer"
            assert "text/html" in response.headers["content-type"]
            for method, path in (("GET", "/api/v1/oauth/pending"), ("POST", "/api/v1/oauth/x/complete"),
                                 ("POST", "/api/v1/oauth/x/cancel"), ("POST", "/api/v1/tool-registry/x/authorize"),
                                 ("DELETE", "/api/v1/tool-registry/x/oauth")):
                assert (await client.request(method, path)).status_code == 401, path
            assert (await client.get("/api/v1/oauth/pending", headers=auth())).json() == []

    run(scenario())


def test_callback_page_for_success_denial_and_replay_escapes_html(tmp_path):
    async def scenario():
        async with oauth_app(tmp_path) as (client, app, _):
            broker = app.state.oauth_broker
            redirect_handler, callback_handler = broker.handlers("t", "<img src=x>")
            await redirect_handler(authorization_url("st-ok"))
            waiting = asyncio.ensure_future(callback_handler())
            page = await client.get("/api/v1/oauth/callback?code=abc&state=st-ok")
            assert page.status_code == 200 and "Signed in to &lt;img src=x&gt;" in page.text
            assert "<img" not in page.text and "close this tab" in page.text
            assert await waiting == ("abc", "st-ok")
            assert (await client.get("/api/v1/oauth/callback?code=abc&state=st-ok")).status_code == 400  # replay

            redirect_handler, callback_handler = broker.handlers("t", "Mail")
            await redirect_handler(authorization_url("st-no"))
            waiting = asyncio.ensure_future(callback_handler())
            denied = await client.get(
                "/api/v1/oauth/callback?state=st-no&error=access_denied&error_description=%3Cscript%3E")
            assert denied.status_code == 200 and "<script>" not in denied.text and "not completed" in denied.text
            with pytest.raises(OAuthDenied):
                await waiting

    run(scenario())


def test_pending_complete_and_cancel_endpoints(tmp_path):
    async def scenario():
        async with oauth_app(tmp_path) as (client, app, _):
            broker = app.state.oauth_broker
            redirect_handler, callback_handler = broker.handlers("tool-9", "Mail")
            await redirect_handler(authorization_url("st-1"))
            waiting = asyncio.ensure_future(callback_handler())
            listing = (await client.get("/api/v1/oauth/pending", headers=auth())).json()
            assert len(listing) == 1
            item = listing[0]
            assert set(item) == {"authId", "toolUuid", "toolName", "url", "redirectUri", "createdAt", "expiresAt"}
            assert item["toolUuid"] == "tool-9" and item["redirectUri"] == CALLBACK
            complete = f"/api/v1/oauth/{item['authId']}/complete"
            assert (await client.post("/api/v1/oauth/nope/complete", headers=auth(),
                                      json={"code": "c", "state": "st-1"})).status_code == 404
            for body in ({}, {"redirectUrl": "http://x/?state=wrong&code=c"}, {"code": "c", "state": "wrong"},
                         {"code": "c"}):
                assert (await client.post(complete, headers=auth(), json=body)).status_code == 400, body
            assert (await client.post(complete, headers=auth(), content="not json")).status_code == 400
            ok = await client.post(complete, headers=auth(), json={"redirectUrl": f"{CALLBACK}?code=zz&state=st-1"})
            assert ok.status_code == 200 and ok.json() == {"status": "authorized"}
            assert await waiting == ("zz", "st-1")

            await redirect_handler(authorization_url("st-2"))
            waiting = asyncio.ensure_future(callback_handler())
            auth_id = broker.pending_for_tool("tool-9").auth_id
            assert (await client.post(f"/api/v1/oauth/{auth_id}/cancel", headers=auth())).status_code == 204
            assert (await client.post("/api/v1/oauth/unknown/cancel", headers=auth())).status_code == 204
            with pytest.raises(OAuthCancelled):
                await waiting
            assert (await client.get("/api/v1/oauth/pending", headers=auth())).json() == []

    run(scenario())


# --- REST: registry ------------------------------------------------------------------------------------
def test_registry_oauth_validation_dto_and_secret_handling(tmp_path):
    async def scenario():
        async with oauth_app(tmp_path) as (client, app, store):
            async def post(body, expected):
                response = await client.post("/api/v1/tool-registry", headers=auth(), json=body)
                assert response.status_code == expected, (body, response.text)
                return response.json()

            await post({"alias": "A", "toolType": "cli", "command": "git", "authType": "oauth"}, 400)
            await post({"alias": "B", "toolType": "mcp", "command": "x", "authType": "oauth"}, 400)
            await post({"alias": "C", "toolType": "api", "endpointUrl": "https://x.example", "authType": "oauth"}, 400)
            await post({"alias": "D", "toolType": "mcp", "endpointUrl": "https://x.example", "authType": "oauth",
                        "authConfigJson": json.dumps({"X-Key": "v"})}, 400)
            await post({"alias": "E", "toolType": "mcp", "endpointUrl": "https://x.example",
                        "oauthClientId": "c"}, 400)  # oauth settings need authType oauth
            await post({"alias": "F", "toolType": "mcp", "endpointUrl": "https://x.example", "authType": "oauth",
                        "oauthClientSecret": "s"}, 400)  # secret needs a client id
            plain = await post({"alias": "G", "toolType": "mcp", "endpointUrl": "https://x.example"}, 201)
            assert plain["oauthConnected"] is None and plain["oauthClientId"] is None
            created = await post({"alias": "Mail", "toolType": "mcp", "endpointUrl": "https://mail.example/mcp",
                                  "authType": "oauth", "oauthClientId": "client-1", "oauthClientSecret": "TOP-SECRET",
                                  "oauthScopes": "mail.read   mail.send"}, 201)
            assert created["authType"] == "oauth" and created["oauthConnected"] is False
            assert created["oauthClientId"] == "client-1" and created["oauthScopes"] == "mail.read mail.send"
            assert "TOP-SECRET" not in json.dumps(created) and "oauthClientSecret" not in created
            uuid = created["uuid"]
            assert (await store.get_tool_oauth(uuid))["client_secret"] == "TOP-SECRET"
            raw = (tmp_path / "data.enc").read_bytes()
            assert b"TOP-SECRET" not in raw and b"client-1" not in raw  # encrypted at rest
            async with app.state.database.session() as session:
                from sqlalchemy import select
                from subconscious_engine.storage.models import ToolRegistryRecord
                config = (await session.scalar(select(ToolRegistryRecord).where(
                    ToolRegistryRecord.uuid == uuid))).config_json
            assert "TOP-SECRET" not in config and json.loads(config)["oauthClientId"] == "client-1"

            # tokens present -> connected; listing and get agree; the secret is never returned
            await store.patch_tool_oauth(uuid, {"tokens": {"access_token": "AT", "token_type": "Bearer"}})
            listed = (await client.get("/api/v1/tool-registry", headers=auth())).json()
            by_alias = {item["alias"]: item for item in listed}
            assert by_alias["Mail"]["oauthConnected"] is True and by_alias["G"]["oauthConnected"] is None
            fetched = (await client.get(f"/api/v1/tool-registry/{uuid}", headers=auth())).text
            assert "TOP-SECRET" not in fetched and '"AT"' not in fetched

            body = {"alias": "Mail", "toolType": "mcp", "endpointUrl": "https://mail.example/mcp",
                    "authType": "oauth", "oauthClientId": "client-1", "oauthScopes": "mail.read mail.send"}
            kept = await client.put(f"/api/v1/tool-registry/{uuid}", headers=auth(), json=body)
            assert kept.json()["oauthConnected"] is True  # identical settings keep tokens
            assert (await store.get_tool_oauth(uuid))["client_secret"] == "TOP-SECRET"
            changed = await client.put(f"/api/v1/tool-registry/{uuid}", headers=auth(),
                                       json={**body, "oauthScopes": "mail.read"})
            assert changed.json()["oauthConnected"] is False  # other scopes -> stale tokens dropped
            assert (await store.get_tool_oauth(uuid)).get("client_secret") == "TOP-SECRET"
            cleared = await client.put(f"/api/v1/tool-registry/{uuid}", headers=auth(), json={
                **body, "clearOauthClientSecret": True})
            assert "client_secret" not in await store.get_tool_oauth(uuid) and cleared.status_code == 200

            await store.patch_tool_oauth(uuid, {"tokens": {"access_token": "AT2", "token_type": "Bearer"}})
            moved = await client.put(f"/api/v1/tool-registry/{uuid}", headers=auth(),
                                     json={**body, "endpointUrl": "https://other.example/mcp"})
            assert moved.json()["oauthConnected"] is False and await store.get_tool_oauth(uuid) == {}

            await store.patch_tool_oauth(uuid, {"tokens": {"access_token": "AT3", "token_type": "Bearer"}})
            away = await client.put(f"/api/v1/tool-registry/{uuid}", headers=auth(), json={
                "alias": "Mail", "toolType": "mcp", "endpointUrl": "https://other.example/mcp"})
            assert away.json()["oauthConnected"] is None and await store.get_tool_oauth(uuid) == {}

            await client.put(f"/api/v1/tool-registry/{uuid}", headers=auth(), json={**body, "endpointUrl":
                             "https://other.example/mcp"})
            await store.patch_tool_oauth(uuid, {"tokens": {"access_token": "AT4", "token_type": "Bearer"}})
            assert (await client.delete(f"/api/v1/tool-registry/{uuid}", headers=auth())).status_code == 204
            assert await store.get_tool_oauth(uuid) == {}

    run(scenario())


def test_authorize_and_forget_reject_tools_that_are_not_oauth(tmp_path):
    async def scenario():
        async with oauth_app(tmp_path) as (client, app, _):
            cli = (await client.post("/api/v1/tool-registry", headers=auth(), json={
                "alias": "Git", "toolType": "cli", "command": "git"})).json()
            assert (await client.post(f"/api/v1/tool-registry/{cli['uuid']}/authorize", headers=auth())).status_code == 400
            assert (await client.delete(f"/api/v1/tool-registry/{cli['uuid']}/oauth", headers=auth())).status_code == 400
            assert (await client.post("/api/v1/tool-registry/missing/authorize", headers=auth())).status_code == 404
            assert (await client.delete("/api/v1/tool-registry/missing/oauth", headers=auth())).status_code == 404

    run(scenario())


# --- end to end: a real OAuth-protected MCP server ---------------------------------------------------
async def sign_in_via_api(client, app, fake, uuid):
    """authorize -> browse -> engine callback; returns after the connection is up."""
    started = await client.post(f"/api/v1/tool-registry/{uuid}/authorize", headers=auth())
    assert started.status_code == 202, started.text
    body = started.json()
    assert body["status"] == "pending" and body["authId"] and body["url"].startswith(fake.base)
    location = await browse(body["url"])
    assert location.startswith(CALLBACK)
    page = await client.get(callback_path(location))  # no bearer: the browser has none
    assert page.status_code == 200 and "You can close this tab" in page.text
    await wait_for(lambda: app.state.configured_tools._connections.get(uuid) is not None)
    return location


def test_end_to_end_sign_in_use_refresh_restart_and_disconnect(tmp_path):
    async def scenario():
        async with fake_oauth_mcp(access_ttl=2) as fake, oauth_app(tmp_path) as (client, app, store):
            runtime = app.state.configured_tools
            created = await create_oauth_tool(client, fake.url, oauthScopes="mail.read mail.send")
            uuid = created["uuid"]
            # Not signed in: a turn skips the tool at once and the test endpoint says why.
            started = time.monotonic()
            assert await runtime.tools_for_turn(ApprovalConfig()) == []
            assert time.monotonic() - started < 2
            assert fake.mcp_requests_without_token == 0 and await runtime.status(uuid) == "needs_auth"
            tested = (await client.post(f"/api/v1/tool-registry/{uuid}/test", headers=auth())).json()
            assert tested == {"ok": False, "tools": [], "error": "Sign-in required.", "needsAuth": True}

            location = await sign_in_via_api(client, app, fake, uuid)
            assert fake.registrations == 1 and fake.scopes_requested == ["mail.read mail.send"]
            assert (await client.get(f"/api/v1/tool-registry/{uuid}", headers=auth())).json()["oauthConnected"] is True
            assert await runtime.status(uuid) == "connected"
            tools = {tool.name: tool for tool in await runtime.tools_for_turn(ApprovalConfig())}
            assert await tools["mail__ping"].function() == "pong"
            replay = await client.get(callback_path(location))
            assert replay.status_code == 400  # the state was single use

            # Nothing secret leaks through any DTO / test result / log-friendly status.
            state = await store.get_tool_oauth(uuid)
            secrets_ = [state["tokens"]["access_token"], state["tokens"]["refresh_token"]]
            for path in ("/api/v1/tool-registry", f"/api/v1/tool-registry/{uuid}", "/api/v1/oauth/pending"):
                text = (await client.get(path, headers=auth())).text
                assert not any(secret in text for secret in secrets_)
            assert state["oauth_metadata"]["token_endpoint"].endswith("/oauth/token")

            # Access token (2 s) expires; an engine restart (new connection) refreshes with the
            # stored refresh token against the stored token endpoint - no new sign-in.
            await runtime.invalidate(uuid)
            await asyncio.sleep(2.3)
            before = list(fake.token_grants)
            tools = {tool.name: tool for tool in await runtime.tools_for_turn(ApprovalConfig())}
            assert await tools["mail__ping"].function() == "pong"
            assert fake.token_grants[len(before):] == ["refresh_token"] and fake.registrations == 1
            assert (await store.get_tool_oauth(uuid))["tokens"]["access_token"] != secrets_[0]

            # Disconnect forgets everything and the tool is skipped again.
            assert (await client.delete(f"/api/v1/tool-registry/{uuid}/oauth", headers=auth())).status_code == 204
            assert (await client.get(f"/api/v1/tool-registry/{uuid}", headers=auth())).json()["oauthConnected"] is False
            assert "tokens" not in await store.get_tool_oauth(uuid) and uuid not in runtime._connections
            assert await runtime.tools_for_turn(ApprovalConfig()) == []

    run(scenario())


def test_revoked_refresh_token_marks_needs_auth_without_waiting_for_a_person(tmp_path):
    async def scenario():
        async with fake_oauth_mcp(access_ttl=1) as fake, oauth_app(tmp_path) as (client, app, store):
            runtime = app.state.configured_tools
            uuid = (await create_oauth_tool(client, fake.url))["uuid"]
            await sign_in_via_api(client, app, fake, uuid)
            await runtime.invalidate(uuid)
            await asyncio.sleep(1.3)
            fake.refresh_tokens.clear()  # the server forgot the grant
            started = time.monotonic()
            assert await runtime.tools_for_turn(ApprovalConfig()) == []
            assert time.monotonic() - started < 5
            assert await runtime.status(uuid) == "needs_auth"
            assert app.state.oauth_broker.pending_for_tool(uuid) is None  # no sign-in card was raised
            tested = await runtime.test(uuid)
            assert tested["needsAuth"] is True and tested["error"] == "Sign-in required."

    run(scenario())


def test_paste_fallback_cancel_and_preregistered_client(tmp_path):
    async def scenario():
        async with fake_oauth_mcp(require_client_secret="shh") as fake, oauth_app(tmp_path) as (client, app, store):
            runtime = app.state.configured_tools
            broker = app.state.oauth_broker
            created = await create_oauth_tool(client, fake.url, oauthClientId="preregistered",
                                              oauthClientSecret="shh")
            uuid = created["uuid"]
            started = (await client.post(f"/api/v1/tool-registry/{uuid}/authorize", headers=auth())).json()
            assert parse_qs(urlsplit(started["url"]).query)["client_id"] == ["preregistered"]

            # A UI on another device cannot load the loopback page: it pastes the address instead.
            location = await browse(started["url"])
            pasted = await client.post(f"/api/v1/oauth/{started['authId']}/complete", headers=auth(),
                                       json={"redirectUrl": location})
            assert pasted.status_code == 200
            await wait_for(lambda: runtime._connections.get(uuid) is not None)
            assert fake.registrations == 0  # the supplied client replaced dynamic registration
            assert (await client.get(f"/api/v1/tool-registry/{uuid}", headers=auth())).json()["oauthConnected"] is True

            # Cancelling a second sign-in ends the flow and leaves nothing pending.
            await client.delete(f"/api/v1/tool-registry/{uuid}/oauth", headers=auth())
            again = (await client.post(f"/api/v1/tool-registry/{uuid}/authorize", headers=auth())).json()
            cancel = await client.post(f"/api/v1/oauth/{again['authId']}/cancel", headers=auth())
            assert cancel.status_code == 204
            await wait_for(lambda: uuid not in runtime._flows)
            assert broker.pending_for_tool(uuid) is None and await runtime.status(uuid) == "error"
            assert (await store.get_tool_oauth(uuid)).get("client_secret") == "shh"  # config survives disconnect

    run(scenario())


def test_listeners_see_request_and_resolved_for_a_flow_started_elsewhere(tmp_path):
    async def scenario():
        async with fake_oauth_mcp() as fake, oauth_app(tmp_path) as (client, app, _):
            frames = []

            async def notify(frame_type, data):
                frames.append((frame_type, data))

            app.state.oauth_broker.attach("turn-x", notify)
            uuid = (await create_oauth_tool(client, fake.url))["uuid"]
            await sign_in_via_api(client, app, fake, uuid)
            assert [kind for kind, _ in frames] == ["oauth.request", "oauth.resolved"]
            assert frames[0][1]["tool_uuid"] == uuid and frames[1][1]["status"] == "authorized"

    run(scenario())
