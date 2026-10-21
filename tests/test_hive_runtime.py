"""Hive runtime tests: signalling client, service lifecycle, routes, config, CLI."""

import asyncio
import json
from contextlib import asynccontextmanager
from types import SimpleNamespace

import httpx
import pytest

from subconscious_engine.__main__ import build_parser
from subconscious_engine.account import AccountUser
from subconscious_engine.api.app import create_app
from subconscious_engine.auth import EngineAuthToken
from subconscious_engine.config import EngineConfig, HiveConfig
from subconscious_engine.configuration_file import (
    ConfigurationFileError,
    set_configuration_value,
)
from subconscious_engine.hive.directory import HiveApiError
from subconscious_engine.hive.errors import HiveError
from subconscious_engine.hive.identity import (
    IdentityError,
    NodeIdentity,
    approval_message,
    b64u_encode,
    short_authentication_string,
    signal_auth_message,
    verify_signature,
)
from subconscious_engine.hive.service import HiveService
from subconscious_engine.hive.signaling import (
    BACKOFF_MAX_SECONDS,
    SignalingClient,
    backoff_delay,
    signal_url,
)
from subconscious_engine.storage import Database

ACCESS_TOKEN = "access-token-value-123"
TICKET = "ticket-value-abc"


def run(coro):
    return asyncio.run(coro)


async def until(predicate, timeout=10.0):
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while not predicate():
        if loop.time() > deadline:
            raise AssertionError("condition not reached")
        await asyncio.sleep(0.02)


# --- signalling client --------------------------------------------------------------


class FakeTicketApi:
    base_url = "https://api.example.test/"

    def __init__(self):
        self.tickets = 0

    async def signal_ticket(self, node_id):
        self.tickets += 1
        return {"ticket": TICKET, "challenge": f"challenge-{self.tickets}", "expires_in": 30}


class FakeSocket:
    def __init__(self, identity, reply="auth.ok"):
        self.identity = identity
        self.reply = reply
        self.sent = []
        self.inbox = asyncio.Queue()
        self.closed = False

    async def send(self, message):
        frame = json.loads(message)
        self.sent.append(frame)
        if frame["type"] == "auth":
            if self.reply == "auth.ok":
                data = {"node_id": self.identity.node_id, "hive_id": "hive-1"}
            else:
                data = {"code": "auth_failed"}
            self.inbox.put_nowait({"v": 1, "type": self.reply, "data": data})

    async def recv(self):
        item = await self.inbox.get()
        if item is None:
            raise ConnectionError("closed")
        return json.dumps(item)

    async def close(self, code=1000, reason=""):
        self.closed = True


def _signaling(identity, sockets, sleeps, replies=None):
    replies = list(replies or [])

    async def connect(url):
        assert url == "wss://api.example.test/signal"
        socket = FakeSocket(identity, replies.pop(0) if replies else "auth.ok")
        sockets.append(socket)
        return socket

    async def sleep(delay):
        if delay == 3600:  # the refresh timer: never fires during a test
            await asyncio.Event().wait()
        sleeps.append(delay)
        await asyncio.sleep(0)

    return SignalingClient(
        FakeTicketApi(), identity, connect=connect, refresh_interval=3600, sleep=sleep, rng=lambda: 0.5
    )


def test_backoff_has_jitter_and_is_capped():
    assert backoff_delay(0, rng=lambda: 1.0) == 1.0
    assert backoff_delay(3, rng=lambda: 1.0) == 8.0
    assert backoff_delay(30, rng=lambda: 1.0) == BACKOFF_MAX_SECONDS
    assert backoff_delay(5, rng=lambda: 0.0) == 0.5
    assert backoff_delay(5, rng=lambda: 0.25) < backoff_delay(5, rng=lambda: 0.75)


def test_signal_url_maps_scheme_and_appends_path():
    assert signal_url("https://api.example.test/") == "wss://api.example.test/signal"
    assert signal_url("http://127.0.0.1:8000") == "ws://127.0.0.1:8000/signal"


def test_signaling_authenticates_dispatches_refreshes_and_reconnects_with_backoff():
    async def scenario():
        identity = NodeIdentity.generate()
        sockets, sleeps, received = [], [], []
        client = _signaling(identity, sockets, sleeps)

        async def on_signal(data):
            received.append(data)

        client.on("signal", on_signal)
        client.start()
        try:
            await client.wait_connected(5)
            socket = sockets[0]
            auth = socket.sent[0]
            assert auth["type"] == "auth" and auth["data"]["node_id"] == identity.node_id
            assert auth["data"]["ticket"] == TICKET
            assert verify_signature(
                identity.public_key, auth["data"]["sig"],
                signal_auth_message("challenge-1", TICKET, identity.node_id),
            )
            assert client.hive_id == "hive-1"
            await until(lambda: any(f["type"] == "presence.set" for f in socket.sent))

            socket.inbox.put_nowait({"v": 1, "type": "signal", "data": {"sid": "s", "from": "n_x"}})
            await until(lambda: received)
            assert received[0]["from"] == "n_x"

            await client.refresh_auth()
            refresh = socket.sent[-1]
            assert refresh["type"] == "auth.refresh" and "node_id" not in refresh["data"]
            assert verify_signature(
                identity.public_key, refresh["data"]["sig"],
                signal_auth_message("challenge-2", TICKET, identity.node_id),
            )

            await client.send_signal("sid", "n_y", "bye", {}, None)
            assert socket.sent[-1]["data"] == {"sid": "sid", "to": "n_y", "kind": "bye", "body": {}}

            socket.inbox.put_nowait(None)  # connection drops
            await until(lambda: len(sockets) == 2)
            await client.wait_connected(5)
            assert sleeps and 0.5 <= sleeps[0] <= BACKOFF_MAX_SECONDS
            assert sockets[0].closed
        finally:
            await client.stop()
        assert not client.connected
        with pytest.raises(ConnectionError):
            await client.send("presence.set", {})
    run(scenario())


def test_signaling_sends_application_level_pings_so_the_server_idle_timeout_never_fires():
    async def scenario():
        identity = NodeIdentity.generate()
        socket = FakeSocket(identity)

        async def connect(url):
            return socket

        client = SignalingClient(
            FakeTicketApi(), identity, connect=connect, refresh_interval=3600, heartbeat_interval=0.05
        )
        client.start()
        try:
            await client.wait_connected(5)
            await until(lambda: sum(1 for f in socket.sent if f["type"] == "ping") >= 2)
        finally:
            await client.stop()
        count = sum(1 for f in socket.sent if f["type"] == "ping")
        await asyncio.sleep(0.2)
        assert sum(1 for f in socket.sent if f["type"] == "ping") == count  # stops with the session
    run(scenario())


def test_signaling_rejected_auth_never_connects_and_retries():
    async def scenario():
        identity = NodeIdentity.generate()
        sockets, sleeps = [], []
        client = _signaling(identity, sockets, sleeps, replies=["error", "error", "auth.ok"])
        client.start()
        try:
            await client.wait_connected(5)
            assert len(sockets) == 3 and client.failures == 2
            assert len(sleeps) == 2
        finally:
            await client.stop()
    run(scenario())


def test_signaling_rejects_oversized_frames():
    async def scenario():
        identity = NodeIdentity.generate()
        client = _signaling(identity, [], [])
        client.start()
        try:
            await client.wait_connected(5)
            with pytest.raises(ValueError):
                await client.send("signal", {"body": "x" * (70 * 1024)})
        finally:
            await client.stop()
    run(scenario())


# --- service lifecycle ---------------------------------------------------------------


class MemoryStore:
    def __init__(self, seed=None):
        self.value = seed

    def read(self):
        return self.value

    def write(self, seed):
        self.value = seed

    def delete(self):
        self.value = None


class FakeAccount:
    server_base_url = "http://127.0.0.1:9"

    def __init__(self):
        self.listeners = []
        self.current_account_user = None

    def subscribe(self, listener):
        self.listeners.append(listener)
        return lambda: self.listeners.remove(listener)

    def emit(self, user):
        self.current_account_user = user
        for listener in list(self.listeners):
            listener(user)

    def access_token(self):
        return ACCESS_TOKEN

    async def refresh_access_token(self):
        return ACCESS_TOKEN

    async def restore(self):
        return None


class FakeServerApi:
    """Stands in for the node registry; keeps its own node list like the server."""

    base_url = "http://127.0.0.1:9/"

    def __init__(self):
        self.nodes = []
        self.calls = []

    async def list_nodes(self):
        return {"hive_id": "hive-1", "nodes": [dict(n) for n in self.nodes]}

    async def register(self, body):
        self.calls.append(("register", body))
        entry = {
            "id": None, "kind": body["kind"], "name": body["name"], "platform": body["platform"],
            "app_version": body["app_version"], "protocol_version": 1, "public_key": body["public_key"],
            "status": "active" if not self.nodes else "pending", "approved_by": None,
            "approval_sig": None, "capabilities": {}, "online": False,
        }
        from subconscious_engine.hive.identity import b64u_decode, derive_node_id

        entry["id"] = derive_node_id(b64u_decode(body["public_key"]))
        self.nodes.append(entry)
        return entry

    async def signal_ticket(self, node_id):
        raise HiveApiError("offline", 503)  # the network layer retries quietly

    async def ice_config(self, node_id):
        return {"ice_servers": [], "ttl": 60}

    async def approve(self, node_id, approver_node_id, sig):
        self.calls.append(("approve", node_id, approver_node_id, sig))

    async def revoke(self, node_id):
        self.calls.append(("revoke", node_id))

    async def create_invite(self, node_id):
        return {"code": "invite-123", "expires_at": "later"}

    async def close(self):
        return None


def _user(identifier="user-1"):
    return AccountUser(id=identifier, email=f"{identifier}@example.test", connected_providers=())


def _service(tmp_path, account, api, store=None):
    service = HiveService(
        auto_approve_account_devices=False,  # these tests exercise the short-code path
        account=account,
        credential_store=SimpleNamespace(),
        data_directory=tmp_path,
        api=api,
        identity_store=store or MemoryStore(),
        node_name="test-node",
    )
    service.attach(SimpleNamespace(state=SimpleNamespace(client_registry=None)))
    return service


def test_service_starts_only_when_signed_in_and_tears_down_on_logout_and_account_change(tmp_path):
    async def scenario():
        account, api = FakeAccount(), FakeServerApi()
        service = _service(tmp_path, account, api)
        assert service.state == "stopped" and service.identity is None
        account.emit(_user("user-1"))
        await until(lambda: service.state == "running")
        snapshot = service.snapshot()
        assert [n["local"] and n["trusted"] and n["status"] == "active" for n in snapshot["nodes"]] == [True]
        assert snapshot["hive_id"] == "hive-1" and snapshot["node_id"] == service.identity.node_id
        assert ACCESS_TOKEN not in json.dumps(snapshot)
        assert service.signaling is not None and service.peers is not None
        first_identity = service.identity.node_id

        account.emit(None)  # logout
        await service._pending_apply
        assert service.state == "stopped"
        assert service.signaling is None and service.peers is None and service.directory is None

        api.nodes.clear()
        account.emit(_user("user-2"))  # a different account on the same machine
        await until(lambda: service.state == "running")
        assert service.directory.user_id == "user-2"
        assert service.identity.node_id == first_identity  # the node key belongs to the machine
        await service.shutdown()
        assert service.state == "stopped" and not account.listeners
    run(scenario())


def test_disabled_service_ignores_account_changes(tmp_path):
    async def scenario():
        account = FakeAccount()
        service = HiveService(
            account=account, credential_store=SimpleNamespace(), data_directory=tmp_path,
            enabled=False, api=FakeServerApi(), identity_store=MemoryStore(),
        )
        service.attach(SimpleNamespace(state=SimpleNamespace(client_registry=None)))
        account.emit(_user())
        await asyncio.sleep(0.1)
        assert service.state == "stopped" and service.snapshot()["enabled"] is False
        await service.startup()
        await service.shutdown()
    run(scenario())


def _entry(identity, status="active", approver=None, sig=None):
    return {
        "id": identity.node_id, "kind": "engine", "name": "n", "platform": "t", "app_version": "0",
        "protocol_version": 1, "public_key": identity.public_key_b64u, "status": status,
        "approved_by": approver.node_id if approver else None, "approval_sig": sig,
        "capabilities": {}, "online": False,
    }


def test_approval_requires_matching_short_code_and_signs_the_new_key(tmp_path):
    async def scenario():
        root, newcomer = NodeIdentity.generate(), NodeIdentity.generate()
        account, api = FakeAccount(), FakeServerApi()
        api.nodes = [_entry(root), _entry(newcomer, status="pending")]
        service = _service(tmp_path, account, api, MemoryStore(b64u_encode(root.seed())))
        account.emit(_user())
        await until(lambda: service.state == "running")
        code = short_authentication_string(root.public_key, newcomer.public_key)
        assert service.sas_for(newcomer.node_id) == code
        with pytest.raises(HiveError) as wrong:
            await service.approve(newcomer.node_id, "000000" if code != "000000" else "111111")
        assert wrong.value.status_code == 400
        with pytest.raises(HiveError) as missing:
            await service.approve("n_unknown", code)
        assert missing.value.status_code == 404
        with pytest.raises(HiveError) as root_again:
            await service.approve(root.node_id, code)  # already active, not pending
        assert root_again.value.status_code == 404
        assert not [c for c in api.calls if c[0] == "approve"]

        await service.approve(newcomer.node_id, code)
        _, node_id, approver_id, sig = next(c for c in api.calls if c[0] == "approve")
        assert node_id == newcomer.node_id and approver_id == root.node_id
        assert verify_signature(
            root.public_key, sig, approval_message("user-1", newcomer.public_key_b64u)
        )
        invite = await service.create_invite()
        assert invite["code"] == "invite-123"
        await service.revoke(newcomer.node_id)
        assert ("revoke", newcomer.node_id) in api.calls
        with pytest.raises(HiveError):
            await service.revoke("n_unknown")
        await service.shutdown()
    run(scenario())


def test_engine_registers_as_full_node_even_when_clients_are_already_listed(tmp_path):
    """Regression: a thin client signing in first used to leave the engine 'unenrolled' forever."""

    class ActivatingServerApi(FakeServerApi):
        async def register(self, body):
            entry = await super().register(body)
            if body["kind"] == "engine":
                entry["status"] = "active"  # the registry lists engines as full nodes
            return entry

    async def scenario():
        phone, web = NodeIdentity.generate(), NodeIdentity.generate()
        account, api = FakeAccount(), ActivatingServerApi()
        api.nodes = [
            {**_entry(phone), "kind": "thin", "name": "Phone"},
            {**_entry(web), "kind": "thin", "name": "Web"},
        ]
        service = _service(tmp_path, account, api)
        account.emit(_user())
        await until(lambda: service.state == "running")
        registers = [c for c in api.calls if c[0] == "register"]
        assert len(registers) == 1 and registers[0][1]["kind"] == "engine"
        nodes = service.snapshot()["nodes"]
        engine = next(n for n in nodes if n["local"])
        assert engine["kind"] == "engine" and engine["trusted"]
        assert engine["id"] == service.identity.node_id
        assert {n["kind"] for n in nodes if not n["local"]} == {"thin"}
        await service.shutdown()
    run(scenario())


def test_pending_local_node_does_not_wait_for_a_trust_root(tmp_path):
    async def scenario():
        root = NodeIdentity.generate()
        me = NodeIdentity.generate()
        account, api = FakeAccount(), FakeServerApi()
        api.nodes = [_entry(root), _entry(me, status="pending")]
        service = _service(tmp_path, account, api, MemoryStore(b64u_encode(me.seed())))
        account.emit(_user())
        await until(lambda: service.state == "running")
        assert service.signaling is not None
        await service.shutdown()
    run(scenario())


def test_snapshot_reports_signalling_state_and_local_online(tmp_path):
    async def scenario():
        account, api = FakeAccount(), FakeServerApi()
        service = _service(tmp_path, account, api)
        assert service.snapshot()["signalling"] == {
            "connected": False, "started": False, "reason": None, "failures": 0, "last_error": None,
            "last_error_detail": None}
        account.emit(_user())
        await until(lambda: service.state == "running")
        signalling = service.snapshot()["signalling"]
        assert signalling["connected"] is False and isinstance(signalling["failures"], int)
        service.signaling._connected.set()
        assert service.snapshot()["signalling"]["connected"] is True
        service.signaling._connected.clear()
        await service.shutdown()
    run(scenario())


def test_snapshot_online_flag_follows_signalling(tmp_path):
    async def scenario():
        account, api = FakeAccount(), FakeServerApi()
        service = _service(tmp_path, account, api)
        account.emit(_user())
        await until(lambda: service.state == "running")
        local = lambda: next(n for n in service.snapshot()["nodes"] if n["local"])
        assert local()["online"] is False
        service.signaling._connected.set()
        assert local()["online"] is True
        service.signaling._connected.clear()
        assert local()["online"] is False
        await service.shutdown()
    run(scenario())


# --- supervisor, traffic cuts, parent/clients, legacy fold ---------------------------


async def _quick_sleep(delay):
    await asyncio.sleep(0.01 if delay < 100 else 3600)  # >= 100 s is the reconcile tick


async def _reconcile_sleep(delay):
    await asyncio.sleep(0.01)


def _supervised(tmp_path, api, *, account=None, auto=False, sleep=_quick_sleep, store=None):
    service = HiveService(
        auto_approve_account_devices=auto, account=account or FakeAccount(),
        credential_store=SimpleNamespace(), data_directory=tmp_path, api=api,
        identity_store=store or MemoryStore(), node_name="test-node", sleep=sleep,
    )
    service.attach(SimpleNamespace(state=SimpleNamespace(client_registry=None)))
    return service


class FlakyApi(FakeServerApi):
    def __init__(self, errors):
        super().__init__()
        self.errors = list(errors)
        self.list_calls = 0

    async def list_nodes(self):
        self.list_calls += 1
        if self.errors:
            raise self.errors.pop(0)
        return await super().list_nodes()


def test_hive_service_retries_after_transient_error(tmp_path):
    async def scenario():
        account, api = FakeAccount(), FlakyApi([HiveApiError("down", 503)])
        service = _supervised(tmp_path, api, account=account)
        account.emit(_user())
        await until(lambda: service.state == "running")
        assert api.list_calls >= 2
        await service.shutdown()
    run(scenario())


def test_hive_service_stops_on_invalid_refresh_token(tmp_path):
    async def scenario():
        account, api = FakeAccount(), FlakyApi([HiveApiError("expired", 401)])
        service = _supervised(tmp_path, api, account=account)
        account.emit(_user())
        await until(lambda: service.state == "signed_out")
        await asyncio.sleep(0.1)
        assert api.list_calls == 1 and service._main.done()
        await service.shutdown()
    run(scenario())


def test_signed_out_service_restarts_on_account_change(tmp_path):
    async def scenario():
        account, api = FakeAccount(), FlakyApi([HiveApiError("expired", 401)])
        service = _supervised(tmp_path, api, account=account)
        account.emit(_user())
        await until(lambda: service.state == "signed_out")
        account.emit(_user())
        await until(lambda: service.state == "running")
        await service.shutdown()
    run(scenario())


def test_cancel_during_backoff_stops_cleanly(tmp_path):
    async def scenario():
        gate = asyncio.Event()

        async def blocked(delay):
            await gate.wait()

        account, api = FakeAccount(), FlakyApi([HiveApiError("down", 503)])
        service = _supervised(tmp_path, api, account=account, sleep=blocked)
        account.emit(_user())
        await until(lambda: service.state == "retrying")
        await asyncio.wait_for(service.shutdown(), 5)
        assert service.state == "stopped"
    run(scenario())


@pytest.mark.parametrize(
    "error,n404,used,action,state",
    [
        (HiveApiError("x", 503), 0, False, "retry", "retrying"),
        (HiveApiError("x", 429), 0, False, "retry", "retrying"),
        (HiveApiError("x", 502, reachable=False), 0, False, "retry", "retrying"),
        (HiveError("x", 502), 0, False, "retry", "retrying"),
        (HiveApiError("x", 404), 5, False, "retry", "retrying"),
        (HiveApiError("x", 404), 6, False, "retry", "error"),
        (HiveApiError("x", 401), 0, False, "stop", "signed_out"),
        (HiveApiError("x", 400), 0, False, "retry", "error"),
        (HiveApiError("x", 409), 0, True, "stop", "error"),
        (IdentityError("bad"), 0, False, "stop", "error"),
    ],
)
def test_supervisor_classification_table(error, n404, used, action, state):
    from subconscious_engine.hive.service import classify_failure

    verdict = classify_failure(error, consecutive_404=n404, bounded_used=used)
    assert (verdict.action, verdict.state) == (action, state)
    if state == "error" and action == "retry":
        assert verdict.delay == 60.0
    with pytest.raises(asyncio.CancelledError):
        classify_failure(asyncio.CancelledError())


class CountingApi(FakeServerApi):
    def __init__(self):
        super().__init__()
        self.list_calls = 0

    async def list_nodes(self):
        self.list_calls += 1
        return await super().list_nodes()


def test_presence_update_does_not_refresh_known_node(tmp_path, monkeypatch):
    from subconscious_engine.hive import service as service_module

    monkeypatch.setattr(service_module, "REFRESH_DEBOUNCE_SECONDS", 0.01)

    async def scenario():
        account, api = FakeAccount(), CountingApi()
        service = _supervised(tmp_path, api, account=account)
        account.emit(_user())
        await until(lambda: service.state == "running")
        before = api.list_calls
        me = service.identity.node_id
        await service._on_presence({"node_id": me, "online": False, "status": "active"})
        await service._on_presence({"node_id": me, "online": True, "status": "active"})
        await asyncio.sleep(0.15)
        assert api.list_calls == before
        await service.shutdown()
    run(scenario())


def test_presence_update_refreshes_on_revoked_status_or_parent_change(tmp_path, monkeypatch):
    from subconscious_engine.hive import service as service_module

    monkeypatch.setattr(service_module, "REFRESH_DEBOUNCE_SECONDS", 0.01)

    async def scenario():
        account, api = FakeAccount(), CountingApi()
        service = _supervised(tmp_path, api, account=account)
        account.emit(_user())
        await until(lambda: service.state == "running")
        me = service.identity.node_id
        before = api.list_calls
        await service._on_presence({"node_id": me, "online": True, "status": "revoked"})
        await until(lambda: api.list_calls > before)
        before = api.list_calls
        await service._on_presence({"node_id": me, "online": True, "status": "active", "parent_node_id": "n_p"})
        await until(lambda: api.list_calls > before)
        await service.shutdown()
    run(scenario())


def test_list_nodes_route_throttles_refresh(tmp_path):
    async def scenario():
        account, api = FakeAccount(), CountingApi()
        service = _supervised(tmp_path, api, account=account)
        account.emit(_user())
        await until(lambda: service.state == "running")
        service._last_refresh = -1e9
        before = api.list_calls
        await service.refresh()
        await service.refresh()
        assert api.list_calls == before + 1
        await service.refresh(force=True)
        assert api.list_calls == before + 2
        await service.shutdown()
    run(scenario())


def test_auto_approve_gives_up_after_two_attempts(tmp_path):
    async def scenario():
        root, phone = NodeIdentity.generate(), NodeIdentity.generate()
        account, api = FakeAccount(), FakeServerApi()
        api.nodes = [_entry(root), {**_entry(phone, status="pending"), "kind": "thin"}]
        service = _supervised(tmp_path, api, account=account, auto=True,
                              store=MemoryStore(b64u_encode(root.seed())))
        account.emit(_user())
        await until(lambda: service.state == "running")
        for _ in range(5):
            await service._auto_approve_pending()
        assert len([c for c in api.calls if c[0] == "approve"]) == 2
        await service.shutdown()
    run(scenario())


def test_reconcile_runs_only_while_signalling_down(tmp_path):
    async def scenario():
        account, api = FakeAccount(), CountingApi()
        service = _supervised(tmp_path, api, account=account, sleep=_reconcile_sleep)
        account.emit(_user())
        await until(lambda: service.state == "running")
        await until(lambda: api.list_calls >= 4)  # signalling is down: the reconcile ticks
        real = service.signaling
        await real.stop()
        service.signaling = SimpleNamespace(connected=True, failures=0, last_error=None, stop=real.stop)
        await asyncio.sleep(0.05)
        settled = api.list_calls
        await asyncio.sleep(0.2)
        assert api.list_calls == settled
        await service.shutdown()
    run(scenario())


def test_snapshot_rows_include_parent_and_clients(tmp_path):
    async def scenario():
        root, child = NodeIdentity.generate(), NodeIdentity.generate()
        account, api = FakeAccount(), FakeServerApi()
        api.nodes = [
            {**_entry(root), "clients": ["Local"]},
            {**_entry(child), "kind": "thin", "parent_node_id": root.node_id},
        ]
        service = _supervised(tmp_path, api, account=account, store=MemoryStore(b64u_encode(root.seed())))
        account.emit(_user())
        await until(lambda: service.state == "running")
        service._clients = ("Desktop",)
        rows = {n["id"]: n for n in service.snapshot()["nodes"]}
        assert rows[child.node_id]["parent_node_id"] == root.node_id and rows[child.node_id]["clients"] == []
        assert rows[root.node_id]["parent_node_id"] is None and rows[root.node_id]["clients"] == ["Desktop"]
        await service.shutdown()
    run(scenario())


class ParentApi(FakeServerApi):
    def __init__(self, error=None):
        super().__init__()
        self.parents = []
        self.error = error

    async def set_parent(self, node_id, parent):
        if self.error:
            raise self.error
        self.parents.append((node_id, parent))


def _thin(identity, name="Phone", **extra):
    import platform as platform_module

    return {**_entry(identity), "kind": "thin", "name": name,
            "platform": platform_module.system().lower(), **extra}


async def _fold_service(tmp_path, nodes, api=None):
    root = NodeIdentity.generate()
    account, api = FakeAccount(), api or ParentApi()
    api.nodes = [_entry(root)] + nodes
    service = _supervised(tmp_path, api, account=account, store=MemoryStore(b64u_encode(root.seed())))
    account.emit(_user())
    await until(lambda: service.state == "running")
    return service, api, root


def test_set_parent_404_and_405_are_skipped(tmp_path):
    async def scenario():
        for status in (404, 405):
            phone = NodeIdentity.generate()
            service, api, _ = await _fold_service(
                tmp_path, [_thin(phone)], ParentApi(HiveApiError("nope", status))
            )
            service.note_gui_client("Phone", None)
            await service._fold_gui_clients()  # must not raise
            assert service._gui_store.mapping == {}
            await service.shutdown()
    run(scenario())


def test_engine_parents_matching_thin_client_once(tmp_path):
    async def scenario():
        phone = NodeIdentity.generate()
        service, api, root = await _fold_service(tmp_path, [_thin(phone)])
        service.note_gui_client("Phone", "cid-1")
        await service._fold_gui_clients()
        await service._fold_gui_clients()
        assert api.parents == [(phone.node_id, root.node_id)]
        assert service._gui_store.mapping == {"cid-1": phone.node_id}
        await service.shutdown()
    run(scenario())


def test_fold_skips_ambiguous_match(tmp_path):
    async def scenario():
        one, two = NodeIdentity.generate(), NodeIdentity.generate()
        service, api, _ = await _fold_service(tmp_path, [_thin(one), _thin(two)])
        service.note_gui_client("Phone", None)
        await service._fold_gui_clients()
        assert api.parents == []
        await service.shutdown()
    run(scenario())


def test_fold_skips_connected_row(tmp_path):
    async def scenario():
        phone = NodeIdentity.generate()
        service, api, _ = await _fold_service(tmp_path, [_thin(phone, online=True)])
        service.note_gui_client("Phone", None)
        await service._fold_gui_clients()
        assert api.parents == []
        await service.shutdown()
    run(scenario())


def test_fold_uses_stored_client_id_mapping(tmp_path):
    async def scenario():
        phone = NodeIdentity.generate()
        service, api, root = await _fold_service(tmp_path, [_thin(phone, name="Renamed")])
        service._gui_store.mapping["cid-9"] = phone.node_id
        service.note_gui_client("Phone", "cid-9")
        await service._fold_gui_clients()
        assert api.parents == [(phone.node_id, root.node_id)]
        await service.shutdown()
    run(scenario())


class LoginAccount:
    def __init__(self):
        self.logins = []

    async def login(self, email, password):
        self.logins.append(email)
        return _user()


def test_login_rejects_bad_device_name_and_client_id(tmp_path):
    async def scenario():
        account, hive = LoginAccount(), SimpleNamespace(noted=[])
        hive.note_gui_client = lambda name, cid: hive.noted.append((name, cid))
        database = Database(tmp_path / "login.db")
        await database.initialize()
        app = create_app(database, EngineAuthToken("secret-token"), account_session_service=account)
        app.state.hive_service = hive
        auth = {"Authorization": "Bearer secret-token"}
        base = {"email": "a@example.test", "password": "pw"}
        try:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as client:
                for extra in (
                    {"device_name": 5}, {"device_name": "  "}, {"device_name": "x" * 65},
                    {"client_id": ""}, {"client_id": "a" * 65}, {"client_id": "bad id!"},
                    {"client_id": 7},
                ):
                    response = await client.post("/api/v1/account/login", json={**base, **extra}, headers=auth)
                    assert response.status_code == 400, extra
                assert account.logins == []
                ok = await client.post(
                    "/api/v1/account/login",
                    json={**base, "device_name": " Brian-XPS ", "client_id": "abc_DEF-1"}, headers=auth,
                )
                assert ok.status_code == 200 and hive.noted == [("Brian-XPS", "abc_DEF-1")]
        finally:
            await database.close()
    run(scenario())


def test_login_without_new_fields_unchanged(tmp_path):
    async def scenario():
        account, hive = LoginAccount(), SimpleNamespace(noted=[])
        hive.note_gui_client = lambda name, cid: hive.noted.append((name, cid))
        database = Database(tmp_path / "login2.db")
        await database.initialize()
        app = create_app(database, EngineAuthToken("secret-token"), account_session_service=account)
        app.state.hive_service = hive
        try:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as client:
                response = await client.post(
                    "/api/v1/account/login", json={"email": "a@example.test", "password": "pw"},
                    headers={"Authorization": "Bearer secret-token"},
                )
                assert response.status_code == 200 and response.json()["authenticated"] is True
                assert account.logins == ["a@example.test"] and hive.noted == [(None, None)]
        finally:
            await database.close()
    run(scenario())


def test_management_calls_without_a_session_are_rejected(tmp_path):
    async def scenario():
        service = _service(tmp_path, FakeAccount(), FakeServerApi())
        for call in (service.enroll(None), service.create_invite(), service.approve("n_x", "1"), service.revoke("n_x")):
            with pytest.raises(HiveError) as error:
                await call
            assert error.value.status_code == 409
    run(scenario())


# --- routes --------------------------------------------------------------------------


@asynccontextmanager
async def route_client(tmp_path, hive_service):
    database = Database(tmp_path / "routes.db")
    await database.initialize()

    async def resolve(identifier):
        return None

    app = create_app(
        database, EngineAuthToken("secret-token"),
        model_configuration_store=SimpleNamespace(resolve=resolve),
    )
    app.state.hive_service = hive_service
    try:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as client:
            yield client
    finally:
        await database.close()


class StubHive:
    def __init__(self):
        self.approved = []

    def snapshot(self):
        return {"enabled": True, "state": "running", "detail": "", "node_id": "n_a", "hive_id": "h", "nodes": []}

    async def enroll(self, invite):
        if invite == "bad":
            raise HiveError("Invite is not valid.", 400)
        return self.snapshot()

    async def create_invite(self):
        return {"code": "c", "expires_at": "e"}

    async def approve(self, node_id, sas):
        if sas != "123456":
            raise HiveError("The short authentication code does not match.", 400)
        self.approved.append(node_id)

    async def revoke(self, node_id):
        raise HiveError("Unknown node.", 404)


def test_hive_routes_require_the_engine_bearer_and_report_errors(tmp_path):
    async def scenario():
        auth = {"Authorization": "Bearer secret-token"}
        async with route_client(tmp_path, StubHive()) as client:
            for method, path in (
                ("GET", "/api/v1/hive/nodes"), ("POST", "/api/v1/hive/enroll"),
                ("POST", "/api/v1/hive/invites"), ("POST", "/api/v1/hive/nodes/n_x/approve"),
                ("DELETE", "/api/v1/hive/nodes/n_x"),
            ):
                assert (await client.request(method, path)).status_code == 401
                assert (await client.request(method, path, headers={"Authorization": "Bearer nope"})).status_code == 401
            listing = await client.get("/api/v1/hive/nodes", headers=auth)
            assert listing.status_code == 200 and listing.json()["state"] == "running"
            assert ACCESS_TOKEN not in listing.text and "access_token" not in listing.text
            assert (await client.post("/api/v1/hive/enroll", json={"invite_code": "bad"}, headers=auth)).status_code == 400
            assert (await client.post("/api/v1/hive/enroll", json={}, headers=auth)).status_code == 200
            assert (await client.post("/api/v1/hive/invites", json={}, headers=auth)).json()["code"] == "c"
            missing_code = await client.post("/api/v1/hive/nodes/n_x/approve", json={}, headers=auth)
            assert missing_code.status_code == 400
            wrong = await client.post("/api/v1/hive/nodes/n_x/approve", json={"sas": "000000"}, headers=auth)
            assert wrong.status_code == 400 and "does not match" in wrong.json()["error"]
            ok = await client.post("/api/v1/hive/nodes/n_x/approve", json={"sas": "123456"}, headers=auth)
            assert ok.status_code == 200
            assert (await client.delete("/api/v1/hive/nodes/n_x", headers=auth)).status_code == 404
    run(scenario())


def test_hive_routes_degrade_when_the_service_is_absent(tmp_path):
    async def scenario():
        auth = {"Authorization": "Bearer secret-token"}
        async with route_client(tmp_path, None) as client:
            listing = (await client.get("/api/v1/hive/nodes", headers=auth)).json()
            assert listing["enabled"] is False and listing["nodes"] == []
            assert (await client.post("/api/v1/hive/enroll", json={}, headers=auth)).status_code == 503
    run(scenario())


def test_account_session_access_token_is_not_served_by_any_route(tmp_path):
    from subconscious_engine.account import AccountSessionService

    assert callable(AccountSessionService.access_token)

    async def scenario():
        async with route_client(tmp_path, None) as client:
            auth = {"Authorization": "Bearer secret-token"}
            for path in ("/api/v1/account", "/api/v1/account/session", "/api/v1/hive/nodes"):
                response = await client.get(path, headers=auth)
                assert "access_token" not in response.text and "accessToken" not in response.text
    run(scenario())


# --- configuration + CLI --------------------------------------------------------------


def test_hive_config_defaults_and_validation(tmp_path):
    config = EngineConfig()
    assert config.hive == HiveConfig(enabled=True, server_url=None, stun_servers=(), node_name=None)
    assert config.resolved_hive_server_url == config.resolved_account_server_url
    path = tmp_path / "config.yaml"
    set_configuration_value(path, "engine.hive.enabled", "false")
    set_configuration_value(path, "engine.hive.stun_servers", "[\"stun:stun.example.test:3478\"]")
    set_configuration_value(path, "engine.hive.node_name", "my-vps")
    text = path.read_text(encoding="utf-8")
    assert "enabled: false" in text and "my-vps" in text
    for key, value in (
        ("engine.hive.enabled", "yes please"), ("engine.hive.server_url", "ftp://x"),
        ("engine.hive.stun_servers", "[\"http://x\"]"), ("engine.hive.bogus", "1"),
        ("engine.hive.node_name", "[1]"),
    ):
        with pytest.raises(ConfigurationFileError):
            set_configuration_value(path, key, value)


def test_node_cli_parses_every_subcommand():
    parser = build_parser()
    assert parser.parse_args(["node", "list"]).node_command == "list"
    enroll = parser.parse_args(["node", "enroll", "--invite", "abc"])
    assert enroll.node_command == "enroll" and enroll.invite == "abc"
    assert parser.parse_args(["node", "invite"]).node_command == "invite"
    approve = parser.parse_args(["node", "approve", "n_abc", "--sas", "123456"])
    assert (approve.node_id, approve.sas) == ("n_abc", "123456")
    assert parser.parse_args(["node", "revoke", "n_abc"]).node_id == "n_abc"
    with pytest.raises(SystemExit):
        parser.parse_args(["node"])


def test_node_cli_shows_the_short_code_for_pending_nodes(capsys, monkeypatch):
    from subconscious_engine import __main__ as cli

    nodes = [{"id": "n_new", "name": "vps", "status": "pending", "local": False, "online": True, "sas": "042517"}]

    async def fake_request(method, path, body=None, **kwargs):
        if path == "nodes" and method == "GET":
            return {"state": "running", "detail": "", "nodes": nodes}
        if path.endswith("/approve"):
            assert body == {"sas": "042517"}
            return {"approved": True}
        raise AssertionError(path)

    monkeypatch.setattr("subconscious_engine.client.hive_request", fake_request)
    args = build_parser().parse_args(["node", "approve", "n_new", "--sas", "042517"])
    assert cli._run_node(args) == 0
    output = capsys.readouterr().out
    assert "042517" in output and "approved" in output.lower()
    args = build_parser().parse_args(["node", "list"])
    assert cli._run_node(args) == 0
    assert "code 042517" in capsys.readouterr().out



# --- connectivity: TLS trust, visible failures, forced refresh ----------------------


def test_outbound_tls_uses_the_certifi_bundle_for_wss_and_https_only():
    import ssl

    from subconscious_engine.tls import client_ssl_context, ssl_for_url

    context = client_ssl_context()
    assert context.verify_mode == ssl.CERT_REQUIRED and context.check_hostname
    assert context.cert_store_stats()["x509_ca"] > 0  # certifi roots, not the OS fallback
    assert ssl_for_url("wss://api.example.test/signal") is context
    assert ssl_for_url("https://api.example.test/") is context
    assert ssl_for_url("ws://127.0.0.1:5050/signal") is None
    assert ssl_for_url("http://127.0.0.1:5050/") is None


def test_signalling_failures_are_logged_at_warning_with_the_cause(caplog):
    async def scenario():
        identity = NodeIdentity.generate()
        attempts = []

        async def connect(url):
            attempts.append(url)
            raise ConnectionError("certificate verify failed: certificate has expired")

        sleeps = []

        async def sleep(delay):
            if delay == 3600:
                await asyncio.Event().wait()
            sleeps.append(delay)
            await asyncio.sleep(0)

        client = SignalingClient(
            FakeTicketApi(), identity, connect=connect, refresh_interval=3600, sleep=sleep,
            rng=lambda: 0.5,
        )
        with caplog.at_level("WARNING", logger="uvicorn.error"):
            client.start()
            try:
                await until(lambda: len(attempts) >= 3)
            finally:
                await client.stop()
        assert client.last_error == "ConnectionError"
        assert "certificate has expired" in (client.last_error_detail or "")
        warnings = [r for r in caplog.records if r.levelname == "WARNING" and "Signalling" in r.message]
        assert warnings and "certificate has expired" in warnings[0].getMessage()
        assert "shows offline" in warnings[0].getMessage()
        # The same cause repeating is condensed, not logged at WARNING every attempt.
        assert len(warnings) < len(attempts)
    run(scenario())


def test_signalling_wake_skips_the_reconnect_backoff():
    async def scenario():
        identity = NodeIdentity.generate()
        attempts = []

        async def connect(url):
            attempts.append(url)
            raise ConnectionError("down")

        async def sleep(delay):
            await asyncio.Event().wait()  # backoff never ends on its own

        client = SignalingClient(
            FakeTicketApi(), identity, connect=connect, refresh_interval=3600, sleep=sleep
        )
        client.start()
        try:
            await until(lambda: len(attempts) == 1)
            await asyncio.sleep(0.05)
            assert len(attempts) == 1  # parked in backoff
            client.wake()
            await until(lambda: len(attempts) == 2)
        finally:
            await client.stop()
    run(scenario())


class CallerAwareServerApi(FakeServerApi):
    """A registry that answers ``caller_online`` when the caller names itself."""

    def __init__(self):
        super().__init__()
        self.callers = []

    async def list_nodes(self, caller_node_id=None):
        listing = await super().list_nodes()
        if caller_node_id is not None:
            self.callers.append(caller_node_id)
            listing["caller_online"] = False
        return listing


def test_force_refresh_reports_and_logs_why_this_engine_is_offline(tmp_path, caplog):
    async def scenario():
        account, api = FakeAccount(), CallerAwareServerApi()
        service = _service(tmp_path, account, api)
        account.emit(_user("user-1"))
        await until(lambda: service.state == "running")
        with caplog.at_level("WARNING", logger="uvicorn.error"):
            snapshot = await service.force_refresh(wait=0.3)
        try:
            assert snapshot["signalling"]["connected"] is False
            problem = snapshot["problem"]
            assert problem and "not connected" in problem and "offline" in problem
            assert api.callers == [service.identity.node_id]  # the server was asked about us
            assert any("not online" in r.getMessage() for r in caplog.records)
            assert snapshot["signalling"]["last_error_detail"] == "offline"
        finally:
            await service.shutdown()
    run(scenario())


def test_force_refresh_without_a_session_says_the_engine_is_not_signed_in(tmp_path):
    async def scenario():
        account, api = FakeAccount(), CallerAwareServerApi()
        service = _service(tmp_path, account, api)
        snapshot = await service.force_refresh(wait=0.1)
        assert snapshot["problem"] == "The engine is not signed in to your account."
        await service.shutdown()
    run(scenario())
