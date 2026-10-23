"""Shared helpers for the live tests: an in-process engine on the real server, raw signalling-socket helpers."""

import asyncio
import json
from contextlib import suppress
from types import SimpleNamespace

import httpx
from websockets.asyncio.client import connect as ws_connect
from websockets.exceptions import ConnectionClosed

from hive_testkit import MemEngine, until
from subconscious_engine.account import AccountServerClient, AccountSessionService
from subconscious_engine.api.app import create_app
from subconscious_engine.auth import EngineAuthToken
from subconscious_engine.hive.identity import signal_auth_message
from subconscious_engine.hive.service import HiveService
from subconscious_engine.hive.signaling import signal_url
from subconscious_engine.storage import Database

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
        self.app = create_app(
            self.database, EngineAuthToken(LOCAL_TOKEN), model_configuration_store=store,
            dev_models=True,
        )
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


# --- helpers shared by the scenario tests ---------------------------------------------------------


def run(coro):
    """Run one async scenario to completion (each test owns its event loop)."""
    return asyncio.run(coro)


def bearer(account):
    return {"Authorization": f"Bearer {account['access_token']}"}


def server_nodes(server_url, account):
    """The account's nodes as the SERVER lists them (``GET /nodes``), keyed by node id."""
    response = httpx.get(f"{server_url}/nodes", headers=bearer(account), timeout=15)
    assert response.status_code == 200, response.text
    return {node["id"]: node for node in response.json()["nodes"]}


async def server_node_is(server_url, account, node_id, predicate, timeout=15.0, what="server state"):
    """Poll the server until ``predicate(node_or_None)`` holds; returns the node (or None)."""
    seen = {}

    async def check():
        seen["node"] = server_nodes(server_url, account).get(node_id)
        return predicate(seen["node"])

    try:
        await until(check, timeout, step=0.15)
    except AssertionError:
        raise AssertionError(f"{what}: not reached for {node_id}; last seen {seen.get('node')!r}") from None
    return seen["node"]


def engine_nodes(engine):
    """The engine's own device list (``GET /api/v1/hive/nodes``), keyed by node id."""
    response = engine.get("/api/v1/hive/nodes")
    assert response.status_code == 200, response.text
    return {node["id"]: node for node in response.json()["nodes"]}


async def engine_node_is(engine, node_id, predicate, timeout=20.0, what="engine device list"):
    seen = {}

    async def check():
        seen["node"] = engine_nodes(engine).get(node_id)
        return predicate(seen["node"])

    try:
        await until(check, timeout, step=0.2)
    except AssertionError:
        raise AssertionError(f"{what}: not reached for {node_id}; last seen {seen.get('node')!r}") from None
    return seen["node"]


def make_workspace(engine, name="Live W"):
    """A workspace on a real engine process (default model: the dev echo model)."""
    response = httpx.post(
        engine.url + "/api/v1/workspaces", headers=engine.headers, json={"name": name, "defaultModelId": "echo"}, timeout=15
    )
    assert response.status_code in {200, 201}, response.text
    return response.json()["uuid"]
