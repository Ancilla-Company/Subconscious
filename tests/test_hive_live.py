"""Live interop: the REAL server app talking to REAL engines (no fakes in between).

* The server (``subconscious-server``) runs as a subprocess under its own venv, on a
  free loopback port, with a throw-away data dir and random secrets (see
  ``live_server.py``). Accounts are seeded through the server's own models and jwt
  service; the engines then sign in with the real ``/auth/refresh`` flow.
* Two (three) engines run in this process: real ``AccountSessionService``,
  ``HiveService`` (HiveApi, Directory, SignalingClient, PeerManager) and HiveNode with
  the real sync/task wiring. WebRTC is real aiortc over loopback host candidates.

Run with ``pytest -m live`` (skipped when the server venv is missing). The session
expiry test takes ~70 s of wall clock; deselect it with ``-k "not expiry"``.
"""

import asyncio
import base64
import json
import time
from contextlib import asynccontextmanager, suppress
from types import SimpleNamespace

import httpx
import pytest
from websockets.asyncio.client import connect as ws_connect
from websockets.exceptions import ConnectionClosed

import live_server
from hive_testkit import MemEngine, converged, until
from subconscious_engine.account import AccountServerClient, AccountSessionService
from subconscious_engine.api.app import create_app
from subconscious_engine.auth import EngineAuthToken
from subconscious_engine.hive import authz
from subconscious_engine.hive import service as service_module
from subconscious_engine.hive.directory import HiveApi, HiveApiError
from subconscious_engine.hive.identity import (
    NodeIdentity,
    approval_message,
    register_message,
    signal_auth_message,
    verify_signature,
)
from subconscious_engine.hive.service import HiveService
from subconscious_engine.hive.signaling import SignalingClient, default_connect, signal_url
from subconscious_engine.hive.tasks import PEER_EVENT_FRAMES
from subconscious_engine.storage import Database

pytestmark = [
    pytest.mark.live,
    pytest.mark.skipif(not live_server.server_available(), reason="the subconscious-server venv is not available"),
]
LOCAL_TOKEN = "secret-token"
UNKNOWN_NODE_ID = "n_" + "a" * 26


class MemStore:
    """In-memory stand-in for the keyring/vault (refresh token or identity seed)."""

    def __init__(self, value=None):
        self.value = value

    def read(self):
        return self.value

    def write(self, value):
        self.value = value

    def delete(self):
        self.value = None


@pytest.fixture(scope="module")
def server(tmp_path_factory):
    running = live_server.RunningServer(tmp_path_factory.mktemp("live-server")).start()
    try:
        yield running
    finally:
        running.stop()


class LiveEngine:
    """A whole engine: database, ASGI app, real account session and HiveService."""

    workspace, thread, message, fingerprint = (
        MemEngine.workspace, MemEngine.thread, MemEngine.message, MemEngine.fingerprint,
    )

    def __init__(self, tmp_path, name, server_url, refresh_token, **hive_options):
        self.name = name
        self.hive_options = hive_options
        self.database = Database(tmp_path / f"{name}.db")
        self.server_url = server_url
        self.account = AccountSessionService(AccountServerClient(server_url), store=MemStore(refresh_token))
        self.tmp_path = tmp_path
        self.service = None
        self.http = None
        self.app = None

    async def start(self):
        await self.database.initialize()
        store = SimpleNamespace()

        async def resolve(identifier):
            return None

        async def listing():
            return []

        store.resolve, store.list = resolve, listing
        self.app = create_app(self.database, EngineAuthToken(LOCAL_TOKEN), model_configuration_store=store)
        self.service = HiveService(
            account=self.account, credential_store=SimpleNamespace(), data_directory=self.tmp_path / f"{self.name}-data",
            server_url=self.server_url, node_name=self.name, identity_store=MemStore(),
            **self.hive_options,
        )
        self.app.state.hive_service = self.service
        self.service.attach(self.app)
        self.http = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=self.app), base_url="http://engine",
            headers={"Authorization": f"Bearer {LOCAL_TOKEN}"},
        )
        assert await self.account.restore() is not None, "sign-in with the seeded refresh token failed"
        await self.service.startup()
        return self

    async def stop(self):
        with suppress(Exception):
            await self.service.shutdown()
        if self.http is not None:
            await self.http.aclose()
        with suppress(Exception):
            await self.account.close()
        await self.database.close()

    @property
    def node_id(self):
        return self.service.identity.node_id

    async def hive(self, method, path, **kwargs):
        response = await self.http.request(method, "/api/v1/hive" + path, **kwargs)
        return response

    async def nodes(self):
        response = await self.hive("GET", "/nodes")
        assert response.status_code == 200, response.text
        return response.json()


async def reach(engine, state, timeout=30):
    try:
        await until(lambda: engine.service.state == state, timeout)
    except AssertionError:
        raise AssertionError(
            f"{engine.name} is {engine.service.state!r} ({engine.service.detail}), wanted {state!r}"
        ) from None


def node_view(snapshot, node_id):
    return next((n for n in snapshot["nodes"] if n["id"] == node_id), None)


# --- raw signalling-socket helpers (protocol level, independent of SignalingClient) ---------


async def raw_open(api, identity, *, ticket=None, claim=None):
    """Open ``/signal`` and send an ``auth`` frame; returns ``(socket, ticket)``."""
    ticket = ticket or await api.signal_ticket(identity.node_id)
    claimed = claim or identity.node_id
    ws = await ws_connect(signal_url(api.base_url), max_size=64 * 1024, open_timeout=10)
    sig = identity.sign(signal_auth_message(ticket["challenge"], ticket["ticket"], claimed))
    await ws.send(json.dumps({"v": 1, "type": "auth", "data": {"ticket": ticket["ticket"], "node_id": claimed, "sig": sig}}))
    return ws, ticket


async def frame_of(ws, timeout=5.0):
    return json.loads(await asyncio.wait_for(ws.recv(), timeout))


async def closed_with(ws, timeout=10.0):
    """Drain a socket until the server closes it; returns ``(frames, close_code)``."""
    frames = []
    try:
        while True:
            frames.append(await frame_of(ws, timeout))
    except ConnectionClosed as closed:
        return frames, closed.rcvd.code if closed.rcvd else None


async def expect_auth_rejected(ws):
    frames, code = await closed_with(ws)
    assert code == 4401, (frames, code)
    assert [f["data"]["code"] for f in frames if f["type"] == "error"] == ["auth_failed"], frames
    assert not any(f["type"] in {"auth.ok", "presence.snapshot"} for f in frames)


# --- the scenario ---------------------------------------------------------------------------


def test_live_two_engines_and_a_stranger(server, tmp_path, monkeypatch):
    monkeypatch.setattr(service_module, "DIRECTORY_POLL_SECONDS", 0.3)
    monkeypatch.setattr(service_module, "REFRESH_DEBOUNCE_SECONDS", 0.2)
    started = time.monotonic()
    asyncio.run(_scenario(server, tmp_path))
    print(f"live scenario took {time.monotonic() - started:.1f}s")


async def _scenario(server, tmp_path):
    account_a, account_b = server.accounts["A"], server.accounts["B"]
    e1 = LiveEngine(tmp_path, "e1", server.url, account_a["refresh_tokens"][1])
    e2 = LiveEngine(tmp_path, "e2", server.url, account_a["refresh_tokens"][2])
    e3 = LiveEngine(tmp_path, "e3", server.url, account_b["refresh_tokens"][1])
    engines = [e1, e2, e3]
    extra_sockets = []
    try:
        # ---- (1) enrolment: first node active, second pending, short-code approval --------
        await e1.start()
        await reach(e1, "running", 30)
        n1 = e1.node_id
        await e1.service.signaling.wait_connected(20)
        listing = await e1.service.api.list_nodes()
        assert listing["hive_id"] == account_a["user_id"]
        first = next(n for n in listing["nodes"] if n["id"] == n1)
        assert first["status"] == "active" and first["approved_by"] is None and first["kind"] == "engine"
        assert first["online"] is True  # signalling is up

        await e2.start()
        await reach(e2, "unenrolled", 30)
        enrolled = await e2.hive("POST", "/enroll", json={})
        assert enrolled.status_code == 200, enrolled.text
        n2 = e2.node_id
        await reach(e2, "pending", 30)
        assert node_view(await e2.nodes(), n2)["status"] == "pending"

        # engine 1 learns about the pending node by listing (no presence frame exists for it)
        view = None
        deadline = time.monotonic() + 10
        while view is None and time.monotonic() < deadline:
            view = node_view(await e1.nodes(), n2)
            await asyncio.sleep(0.2)
        assert view is not None and view["status"] == "pending" and view["trusted"] is False
        sas = view["sas"]
        assert sas and len(sas) == 6 and sas == node_view(await e2.nodes(), n1)["sas"]  # both sides show the same code
        wrong = await e1.hive("POST", f"/nodes/{n2}/approve", json={"sas": "000000" if sas != "000000" else "111111"})
        assert wrong.status_code == 400
        approved = await e1.hive("POST", f"/nodes/{n2}/approve", json={"sas": sas})
        assert approved.status_code == 200, approved.text
        await reach(e2, "running", 30)

        listing = await e1.service.api.list_nodes()
        second = next(n for n in listing["nodes"] if n["id"] == n2)
        assert second["status"] == "active" and second["approved_by"] == n1
        assert verify_signature(
            e1.service.identity.public_key, second["approval_sig"],
            approval_message(account_a["user_id"], second["public_key"]),
        )
        assert e2.service.directory.is_trusted(n1) and e1.service.directory.is_trusted(n2)

        # presence: the server reports both online and each engine heard it
        await until(lambda: e1.service._online.get(n2) is True and e2.service._online.get(n1) is True, 20)
        listing = await e1.service.api.list_nodes()
        assert {n["id"]: n["online"] for n in listing["nodes"]} == {n1: True, n2: True}

        # ---- (2) direct aiortc link via real signalling ----------------------------------
        await until(lambda: e1.service.peers.link(n2) and e2.service.peers.link(n1), 40)
        link1, link2 = e1.service.peers.link(n2), e2.service.peers.link(n1)
        assert link1.tier == link2.tier == "direct"
        assert link1.role == link2.role == authz.HIVE_PEER
        assert e1.service.peers.state_of(n2) == "connected"
        assert node_view(await e1.nodes(), n2)["connection"] == "connected"

        # engine 2 drives engine 1 over the link: chat.send -> chat.done, and the rpc tunnel
        created = await e1.http.post("/api/v1/workspaces", json={"name": "Live W", "defaultModelId": "echo"})
        assert created.status_code in {200, 201}, created.text
        workspace = created.json()["uuid"]
        inbox = asyncio.Queue()
        original = link2.handler

        def tap(link, channel, envelope):
            inbox.put_nowait((channel, envelope))
            if channel == "sync" or envelope.type in PEER_EVENT_FRAMES or envelope.type.startswith("tool."):
                original(link, channel, envelope)

        link2.handler = tap
        await link2.send_frame("control", "chat.send", {"workspace_uuid": workspace, "content": "hello live"}, "turn-1")
        frames = []
        while not any(env.type == "chat.done" for _, env in frames):
            frames.append(await asyncio.wait_for(inbox.get(), 40))
        assert "hello live" in "".join(env.data["delta"] for _, env in frames if env.type == "chat.delta")
        assert any(env.type == "chat.done" and env.id == "turn-1" for _, env in frames)

        await link2.send_frame("rpc", "http.request", {"method": "GET", "path": "/api/v1/workspaces"}, "rpc-1")
        response = None
        while response is None:
            channel, env = await asyncio.wait_for(inbox.get(), 20)
            if env.type == "http.response" and env.id == "rpc-1":
                response = env
        assert response.data["status"] == 200
        listed = json.loads(base64.b64decode(response.data["body"]))
        assert [w["uuid"] for w in listed] == [workspace] or workspace in [w["uuid"] for w in listed]
        await link2.send_frame("rpc", "http.request", {"method": "GET", "path": "/api/v1/settings"}, "rpc-2")
        while True:
            channel, env = await asyncio.wait_for(inbox.get(), 20)
            if env.type == "http.response" and env.id == "rpc-2":
                assert env.data["status"] in {400, 403}  # not on the peer allowlist
                break

        # ---- (3) sync ---------------------------------------------------------------------
        await converged(e1, e2, timeout=40)  # the chat turn replicated
        thread = await e1.thread(workspace, "Synced thread")
        message = await e1.message(thread, "synced message body")
        await converged(e1, e2, timeout=40)
        fingerprint = await e2.fingerprint()
        assert fingerprint["threads"][thread][1] == "Synced thread"
        assert fingerprint["messages"][message][2] == "synced message body"

        # ---- (4) cross-account isolation --------------------------------------------------
        await e3.start()
        await reach(e3, "running", 30)
        n3 = e3.node_id
        assert n3 not in {n["id"] for n in (await e1.service.api.list_nodes())["nodes"]}
        b_nodes = await e3.service.api.list_nodes()
        assert b_nodes["hive_id"] == account_b["user_id"] != account_a["user_id"]
        assert [n["id"] for n in b_nodes["nodes"]] == [n3]
        await asyncio.sleep(1.0)
        assert n3 not in e1.service._online and n3 not in e2.service._online
        assert n3 not in {n["id"] for n in (await e1.nodes())["nodes"]}
        assert n1 not in e3.service._online and n2 not in e3.service._online

        # REST: another account's node ids are indistinguishable from nonexistent ones
        token_b = e3.account.access_token()
        async with httpx.AsyncClient(base_url=server.url, headers={"Authorization": f"Bearer {token_b}"}) as raw:
            bodies = set()
            for target in (n1, n2, UNKNOWN_NODE_ID):
                for method, path in (("POST", "signal-ticket"), ("POST", "ice-config"), ("DELETE", ""),
                                     ("POST", "approve")):
                    url = f"/nodes/{target}" + (f"/{path}" if path else "")
                    reply = await raw.request(method, url, json={"approver_node_id": n3, "approval_sig": "x" * 86})
                    assert reply.status_code == 404, (target, path, reply.status_code)
                    bodies.add((path, reply.text))
            assert len(bodies) == 4  # one body per endpoint, identical for own-other-account and unknown ids
        for blocked in (e3.service.api.signal_ticket(n1), e3.service.api.ice_config(n1)):
            with pytest.raises(HiveApiError) as error:
                await blocked
            assert error.value.status_code == 404
        still_active = {n["id"]: n["status"] for n in (await e1.service.api.list_nodes())["nodes"]}
        assert still_active == {n1: "active", n2: "active"}  # B's DELETE attempts changed nothing

        # signalling: B's authenticated socket cannot address A's nodes (or nonexistent ones)
        ws3, _ = await raw_open(e3.service.api, e3.service.identity)
        extra_sockets.append(ws3)
        auth_ok, snapshot = await frame_of(ws3), await frame_of(ws3)
        assert auth_ok["type"] == "auth.ok" and auth_ok["data"] == {"node_id": n3, "hive_id": account_b["user_id"]}
        assert snapshot["type"] == "presence.snapshot"
        assert {n["node_id"] for n in snapshot["data"]["nodes"]} == {n3}
        for entry in snapshot["data"]["nodes"]:
            assert set(entry) >= {"node_id", "online", "clients", "capabilities"} and entry["online"] is True
        errors = []
        for target in (n1, n2, UNKNOWN_NODE_ID):
            await ws3.send(json.dumps({"v": 1, "type": "signal", "data": {
                "sid": f"{int(time.time())}.x", "to": target, "kind": "offer", "body": {"type": "offer", "sdp": "v=0"},
                "sig": "x"}}))
            errors.append(await frame_of(ws3))
        assert errors == [{"v": 1, "type": "error", "data": {"code": "unknown_node"}}] * 3
        assert not link1.closed.is_set() and not link2.closed.is_set()  # A's link was not disturbed

        # B's credentials do not authenticate as A's nodes, tickets are single use
        stolen, ticket_b = await raw_open(e3.service.api, e3.service.identity, claim=n1)
        await expect_auth_rejected(stolen)
        replay, _ = await raw_open(e3.service.api, e3.service.identity, ticket=ticket_b)
        await expect_auth_rejected(replay)
        crossed, _ = await raw_open(e1.service.api, e1.service.identity, claim=n3)
        await expect_auth_rejected(crossed)
        forged, _ = await raw_open(e3.service.api, NodeIdentity.generate(), ticket=await e3.service.api.signal_ticket(n3), claim=n3)
        await expect_auth_rejected(forged)  # a valid ticket without the node key is useless
        await ws3.close()
        extra_sockets.remove(ws3)

        # ---- (5) revocation -----------------------------------------------------------------
        watcher, _ = await raw_open(e2.service.api, e2.service.identity)  # a second socket of node 2
        extra_sockets.append(watcher)
        assert (await frame_of(watcher))["type"] == "auth.ok"
        # contract: the engine sends `bye` (and candidates) unsigned; the server must relay them
        # (it used to answer bad_request, so a teardown never reached the other side)
        assert (await frame_of(watcher))["type"] == "presence.snapshot"
        for kind, body in (("bye", {}), ("candidate", {"candidate": "candidate:1 1 udp 1 127.0.0.1 9 typ host"})):
            await watcher.send(json.dumps({"v": 1, "type": "signal", "data": {
                "sid": f"{int(time.time())}.unmatched", "to": n1, "kind": kind, "body": body}}))
        await watcher.send(json.dumps({"v": 1, "type": "ping", "data": {}}))
        reply = await frame_of(watcher)
        while reply["type"] == "presence.update":
            reply = await frame_of(watcher)
        assert reply["type"] == "pong", reply  # not an `error` frame
        assert e1.service.peers.link(n2) is link1  # the unmatched sid did not disturb the live link
        revoked = await e1.hive("DELETE", f"/nodes/{n2}")
        assert revoked.status_code == 200, revoked.text
        frames, code = await closed_with(watcher)
        assert code == 4401, (frames, code)  # revocation closes node 2's sockets immediately
        extra_sockets.remove(watcher)
        await until(lambda: e1.service.peers.link(n2) is None, 15)
        await until(lambda: e2.service.peers.link(n1) is None, 20)
        assert link1.closed.is_set() and link2.closed.is_set()
        await until(lambda: not e2.service.signaling.connected, 15)
        listing = await e1.service.api.list_nodes()
        assert next(n for n in listing["nodes"] if n["id"] == n2)["status"] == "revoked"
        assert next(n for n in listing["nodes"] if n["id"] == n2)["online"] is False
        with pytest.raises(ConnectionError):
            await e1.service.peers.connect(n2)  # no longer a trusted member
        with pytest.raises(ConnectionError):
            await e2.service.peers.connect(n1)  # node 2 cannot signal any more
        with pytest.raises(HiveApiError) as error:
            await e2.service.api.signal_ticket(n2)
        assert error.value.status_code == 403
        await asyncio.sleep(2.5)  # its reconnect loop keeps failing
        assert not e2.service.signaling.connected and e2.service.signaling.failures >= 1
        assert e1.service.peers.link(n2) is None and e2.service.peers.link(n1) is None
        # engine 1 still works alone
        assert (await e1.http.get("/api/v1/workspaces")).status_code == 200
    finally:
        for socket in extra_sockets:
            with suppress(Exception):
                await socket.close()
        for engine in reversed(engines):
            with suppress(Exception):
                await engine.stop()


# --- (6) session expiry and refresh ------------------------------------------------------------


@asynccontextmanager
async def _expiry_node(server, tmp_path):
    account = AccountSessionService(
        AccountServerClient(server.url), store=MemStore(server.accounts["A"]["refresh_token"]))
    user = await account.restore()
    api = HiveApi(server.url, account.access_token, account.refresh_access_token)
    identity = NodeIdentity.generate()
    await api.register({
        "kind": "engine", "name": "expiry", "platform": "test", "app_version": "0", "protocol_version": 1,
        "public_key": identity.public_key_b64u, "proof": identity.sign(register_message(user.id, identity.public_key_b64u)),
    })
    try:
        yield account, api, identity
    finally:
        await api.close()
        await account.close()


def test_signalling_session_expiry_and_auth_refresh(tmp_path_factory):
    """access tokens/sessions last 1 minute here: a refreshing client survives, a stale socket is closed."""
    root = tmp_path_factory.mktemp("live-expiry")
    expiring = live_server.RunningServer(root, access_token_minutes=1).start()

    async def scenario():
        async with _expiry_node(expiring, root) as (account, api, identity):
            connects, sent = [], []

            class Recording:
                def __init__(self, inner):
                    self._inner = inner

                async def send(self, message):
                    sent.append(json.loads(message)["type"])
                    await self._inner.send(message)

                async def recv(self):
                    return await self._inner.recv()

                async def close(self, *args, **kwargs):
                    await self._inner.close(*args, **kwargs)

            async def counting_connect(url):
                connects.append(url)
                return Recording(await default_connect(url))

            client = SignalingClient(
                api, identity, connect=counting_connect, refresh_interval=15.0, heartbeat_interval=10.0)
            client.start()
            stale = None
            try:
                await client.wait_connected(15)
                begin = time.monotonic()
                stale, _ = await raw_open(api, identity)  # same node, never refreshed
                assert (await frame_of(stale))["type"] == "auth.ok"
                # the 401 path: a dead access token is replaced through the real /auth/refresh
                account._access_token = "not-a-token"
                assert (await api.list_nodes())["nodes"][0]["id"] == identity.node_id
                assert account.access_token() != "not-a-token"
                # keep the stale socket from idling out (60 s) so it can only hit session expiry
                frames = []
                code = None
                while code is None:
                    try:
                        await stale.send(json.dumps({"v": 1, "type": "ping", "data": {}}))
                        pause = time.monotonic() + 10
                        while time.monotonic() < pause:
                            frames.append(await frame_of(stale, max(0.1, pause - time.monotonic())))
                    except TimeoutError:
                        pass
                    except ConnectionClosed as closed:
                        code = closed.rcvd.code if closed.rcvd else -1
                    assert time.monotonic() - begin < 80, "the stale session was never closed"
                waited = time.monotonic() - begin
                assert code == 4401 and 45 < waited < 70, (code, waited)  # closed at session expiry
                assert any(f["type"] == "pong" for f in frames)
                await asyncio.sleep(max(0.0, 66 - (time.monotonic() - begin)))
                # the refreshing client kept the very same socket alive past the expiry
                assert client.connected and len(connects) == 1 and client.failures == 0
                assert sent.count("auth.refresh") >= 3 and "ping" in sent
            finally:
                if stale is not None:
                    with suppress(Exception):
                        await stale.close()
                await client.stop()

    try:
        asyncio.run(scenario())
    finally:
        expiring.stop()


# --- (7) socket relay fallback -------------------------------------------------------------------
# Direct WebRTC is made to fail deterministically with ``force_relay=True`` (the documented
# test/diagnostic switch, ``engine.hive.force_relay``): no offer is made or answered, so the
# only way two engines can talk is the encrypted relay over the signalling socket of the REAL
# server. A fresh server instance keeps the account directory clean for this scenario.


def test_live_relay_fallback_chat_rpc_sync_and_account_isolation(tmp_path_factory, monkeypatch):
    monkeypatch.setattr(service_module, "DIRECTORY_POLL_SECONDS", 0.3)
    monkeypatch.setattr(service_module, "REFRESH_DEBOUNCE_SECONDS", 0.2)
    root = tmp_path_factory.mktemp("live-relay")
    relay_server = live_server.RunningServer(root).start()
    started = time.monotonic()
    try:
        asyncio.run(_relay_scenario(relay_server, root))
    finally:
        relay_server.stop()
    print(f"live relay scenario took {time.monotonic() - started:.1f}s")


async def _relay_scenario(server, tmp_path):
    account_a, account_b = server.accounts["A"], server.accounts["B"]
    e1 = LiveEngine(tmp_path, "r1", server.url, account_a["refresh_tokens"][1], force_relay=True)
    e2 = LiveEngine(tmp_path, "r2", server.url, account_a["refresh_tokens"][2], force_relay=True)
    e3 = LiveEngine(tmp_path, "r3", server.url, account_b["refresh_tokens"][1], force_relay=True)
    engines = [e1, e2, e3]
    sockets = []
    try:
        # enrolment as in the main scenario
        await e1.start()
        await reach(e1, "running", 30)
        n1 = e1.node_id
        await e2.start()
        await reach(e2, "unenrolled", 30)
        assert (await e2.hive("POST", "/enroll", json={})).status_code == 200
        n2 = e2.node_id
        await reach(e2, "pending", 30)
        view = None
        deadline = time.monotonic() + 10
        while view is None and time.monotonic() < deadline:
            view = node_view(await e1.nodes(), n2)
            await asyncio.sleep(0.2)
        assert view is not None
        approved = await e1.hive("POST", f"/nodes/{n2}/approve", json={"sas": view["sas"]})
        assert approved.status_code == 200, approved.text
        await reach(e2, "running", 30)

        # ---- the link is a relay link on both sides (no WebRTC was attempted) ----------------
        await until(lambda: e1.service.peers.link(n2) and e2.service.peers.link(n1), 40)
        link1, link2 = e1.service.peers.link(n2), e2.service.peers.link(n1)
        assert link1.tier == link2.tier == "ws-relay"
        assert link1.role == link2.role == authz.HIVE_PEER
        assert not e1.service.peers._attempts and not e2.service.peers._attempts  # direct never tried
        assert node_view(await e1.nodes(), n2)["tier"] == "ws-relay"
        assert node_view(await e2.nodes(), n1)["connection"] == "connected"

        # ---- chat.send -> chat.done through the relay ------------------------------------------
        created = await e1.http.post("/api/v1/workspaces", json={"name": "Relay W", "defaultModelId": "echo"})
        assert created.status_code in {200, 201}, created.text
        workspace = created.json()["uuid"]
        inbox = asyncio.Queue()
        original = link2.handler

        def tap(link, channel, envelope):
            inbox.put_nowait((channel, envelope))
            if channel == "sync" or envelope.type in PEER_EVENT_FRAMES or envelope.type.startswith("tool."):
                original(link, channel, envelope)

        link2.handler = tap
        await link2.send_frame("control", "chat.send", {"workspace_uuid": workspace, "content": "hello relay"}, "turn-1")
        frames = []
        while not any(env.type == "chat.done" for _, env in frames):
            frames.append(await asyncio.wait_for(inbox.get(), 60))
        assert "hello relay" in "".join(env.data["delta"] for _, env in frames if env.type == "chat.delta")
        assert any(env.type == "chat.done" and env.id == "turn-1" for _, env in frames)

        # ---- rpc GET through the relay ----------------------------------------------------------
        await link2.send_frame("rpc", "http.request", {"method": "GET", "path": "/api/v1/workspaces"}, "rpc-1")
        response = None
        while response is None:
            _channel, env = await asyncio.wait_for(inbox.get(), 30)
            if env.type == "http.response" and env.id == "rpc-1":
                response = env
        assert response.data["status"] == 200
        assert workspace in [w["uuid"] for w in json.loads(base64.b64decode(response.data["body"]))]

        # ---- sync round trip over the relay (both directions) -----------------------------------------
        await converged(e1, e2, timeout=60)  # the chat turn replicated
        thread = await e1.thread(workspace, "Relay thread")
        message = await e1.message(thread, "relay synced body")
        await converged(e1, e2, timeout=60)
        fingerprint = await e2.fingerprint()
        assert fingerprint["threads"][thread][1] == "Relay thread"
        assert fingerprint["messages"][message][2] == "relay synced body"
        back = await e2.message(thread, "written on the other node")
        await converged(e1, e2, timeout=60)
        assert (await e1.fingerprint())["messages"][back][2] == "written on the other node"
        assert e1.service.peers.link(n2) is link1 and link1.tier == "ws-relay"  # still the same relay link

        # ---- account isolation: B cannot relay to A's nodes, in either direction ------------------------
        await e3.start()
        await reach(e3, "running", 30)
        n3 = e3.node_id
        await e3.service.signaling.wait_connected(20)
        ws3, _ = await raw_open(e3.service.api, e3.service.identity)
        sockets.append(ws3)
        assert (await frame_of(ws3))["type"] == "auth.ok" and (await frame_of(ws3))["type"] == "presence.snapshot"
        ws1, _ = await raw_open(e1.service.api, e1.service.identity)  # a second socket of A's node 1
        sockets.append(ws1)
        assert (await frame_of(ws1))["type"] == "auth.ok" and (await frame_of(ws1))["type"] == "presence.snapshot"
        relays_before = len(e1.service.peers._relay.sessions)
        for target in (n1, n2, UNKNOWN_NODE_ID):  # B -> A's nodes and a nonexistent node look the same
            await ws3.send(json.dumps({"v": 1, "type": "relay", "data": {
                "sid": f"{int(time.time())}.iso", "to": target, "payload": "AQIDBA"}}))
            reply = await frame_of(ws3)
            while reply["type"] == "presence.update":
                reply = await frame_of(ws3)
            assert reply == {"v": 1, "type": "error", "data": {"code": "unknown_node"}}, reply
        await ws1.send(json.dumps({"v": 1, "type": "relay", "data": {
            "sid": f"{int(time.time())}.iso", "to": n3, "payload": "AQIDBA"}}))  # A -> B's node
        reply = await frame_of(ws1)
        while reply["type"] == "presence.update":
            reply = await frame_of(ws1)
        assert reply == {"v": 1, "type": "error", "data": {"code": "unknown_node"}}, reply
        # B's engine cannot even start a handshake with A's node: it is not in B's directory
        with pytest.raises(ConnectionError):
            await e3.service.peers._relay.connect(n1)
        await asyncio.sleep(1.0)
        assert len(e1.service.peers._relay.sessions) == relays_before  # nothing reached A's engines
        assert e1.service.peers.link(n2) is link1 and not link1.closed.is_set() and not link2.closed.is_set()
        # the relay link still works after the isolation probes
        await link2.send_frame("rpc", "http.request", {"method": "GET", "path": "/api/v1/workspaces"}, "rpc-2")
        while True:
            _channel, env = await asyncio.wait_for(inbox.get(), 30)
            if env.type == "http.response" and env.id == "rpc-2":
                assert env.data["status"] == 200
                break
    finally:
        for socket in sockets:
            with suppress(Exception):
                await socket.close()
        for engine in reversed(engines):
            with suppress(Exception):
                await engine.stop()
