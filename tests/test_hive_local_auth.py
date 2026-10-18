"""Local-peer detection and signed-in (no short code) hive device approval."""
import asyncio
from types import SimpleNamespace

import pytest

from subconscious_engine.account import AccountUser
from subconscious_engine.api.websocket import WebSocketSession
from subconscious_engine.auth import PEER_STATE_KEY, PeerPrincipal
from subconscious_engine.hive.directory import Directory, PinStore
from subconscious_engine.hive.errors import HiveError
from subconscious_engine.hive.identity import (
    NodeIdentity,
    approval_message,
    b64u_encode,
    register_message,
    verify_signature,
)
from subconscious_engine.hive.service import AUTO_APPROVE_LIMIT, HiveService
from subconscious_engine.locality import is_local_peer

USER = "user-1"


def run(coro):
    return asyncio.run(coro)


async def until(predicate, timeout=10.0):
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while not predicate():
        if loop.time() > deadline:
            raise AssertionError("condition not reached")
        await asyncio.sleep(0.02)


# --- locality ---------------------------------------------------------------------
@pytest.mark.parametrize("host", ["127.0.0.1", "127.5.4.3", "::1", "::ffff:127.0.0.1"])
def test_loopback_transport_peers_are_local(host):
    assert is_local_peer({"type": "websocket", "client": (host, 5000), "headers": []})
    assert is_local_peer(SimpleNamespace(client=SimpleNamespace(host=host, port=1)))


@pytest.mark.parametrize("host", ["192.168.1.5", "10.0.0.2", "8.8.8.8", "testclient", "", None, "garbage", 7])
def test_lan_and_unknown_peers_are_remote(host):
    assert not is_local_peer({"type": "websocket", "client": (host, 5000)})
    assert not is_local_peer(SimpleNamespace(client=SimpleNamespace(host=host, port=1)))
    assert not is_local_peer({"type": "websocket"})
    assert not is_local_peer(None)


def test_forwarded_headers_never_make_a_remote_peer_local():
    headers = [
        (b"x-forwarded-for", b"127.0.0.1"),
        (b"forwarded", b"for=127.0.0.1"),
        (b"x-real-ip", b"127.0.0.1"),
        (b"host", b"localhost"),
    ]
    assert not is_local_peer({"type": "http", "client": ("192.168.1.9", 1), "headers": headers})


def test_tunnel_peers_are_remote_even_with_a_loopback_looking_address():
    link = SimpleNamespace(node_id="n_x")
    socket = SimpleNamespace(link=link, client=SimpleNamespace(host="127.0.0.1", port=None))
    assert not is_local_peer(socket)
    principal = PeerPrincipal("n_x", "hive_peer")
    scope = {"type": "http", "client": ("127.0.0.1", 1), "state": {PEER_STATE_KEY: principal}}
    assert not is_local_peer(scope)
    assert not is_local_peer(SimpleNamespace(scope=scope, client=SimpleNamespace(host="127.0.0.1")))


class _Registry:
    async def acquire(self, requested, label=None, **kwargs):
        return requested or "c1"

    async def release(self, identifier):
        return None

    async def register_session(self, identifier, session):
        return None


def _hello_ack(socket):
    async def scenario():
        sent = []
        socket.app = SimpleNamespace(state=SimpleNamespace(client_registry=_Registry()))

        async def send_json(data):
            sent.append(data)

        socket.send_json = send_json
        session = WebSocketSession(socket)
        await session._hello({"clientId": "abc", "local": True})  # a client-sent flag is ignored
        return sent[0]["data"]

    return run(scenario())


def test_hello_ack_reports_local_only_for_loopback_transport():
    local = _hello_ack(SimpleNamespace(client=SimpleNamespace(host="127.0.0.1", port=1)))
    remote = _hello_ack(SimpleNamespace(client=SimpleNamespace(host="192.168.1.5", port=1)))
    peer = _hello_ack(SimpleNamespace(link=object(), client=SimpleNamespace(host="peer:n_x", port=None)))
    assert local["local"] is True
    assert remote["local"] is False and peer["local"] is False


# --- trust roots ------------------------------------------------------------------
def _node(identity, *, kind="engine", status="active", approver=None, proof=True, platform="test"):
    sig = approver.sign(approval_message(USER, identity.public_key_b64u)) if approver else None
    entry = {
        "id": identity.node_id, "kind": kind, "name": "n", "platform": platform, "app_version": "0",
        "protocol_version": 1, "public_key": identity.public_key_b64u, "status": status,
        "approved_by": approver.node_id if approver else None, "approval_sig": sig,
        "capabilities": {}, "online": False,
    }
    if proof is True:
        entry["proof"] = identity.sign(register_message(USER, identity.public_key_b64u))
    elif isinstance(proof, str):
        entry["proof"] = proof
    return entry


def test_thin_and_engine_nodes_are_both_members_once_active():
    thin, engine = NodeIdentity.generate(), NodeIdentity.generate()
    directory = Directory(USER, thin.node_id, PinStore(None))
    directory.update([_node(thin, kind="thin")], "hive-1")
    assert directory.is_trusted(thin.node_id)
    directory = Directory(USER, engine.node_id, PinStore(None))
    directory.update([_node(thin, kind="thin"), _node(engine)], "hive-1")
    assert directory.is_trusted(engine.node_id) and directory.is_trusted(thin.node_id)


# --- signed-in auto approval -------------------------------------------------------
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
        return "access-token"

    async def refresh_access_token(self):
        return "access-token"

    async def restore(self):
        return None


class FakeApi:
    base_url = "http://127.0.0.1:9/"

    def __init__(self, nodes):
        self.nodes = nodes
        self.approvals = []

    async def list_nodes(self):
        return {"hive_id": "hive-1", "nodes": [dict(n) for n in self.nodes]}

    async def register(self, body):
        return {}

    async def signal_ticket(self, node_id):
        from subconscious_engine.hive.directory import HiveApiError

        raise HiveApiError("offline", 503)

    async def ice_config(self, node_id):
        return {"ice_servers": [], "ttl": 60}

    async def approve(self, node_id, approver_node_id, sig):
        self.approvals.append((node_id, approver_node_id, sig))
        for node in self.nodes:
            if node["id"] == node_id:
                node.update(status="active", approved_by=approver_node_id, approval_sig=sig)

    async def revoke(self, node_id):
        return None

    async def close(self):
        return None


def _user(identifier=USER):
    return AccountUser(id=identifier, email="u@example.test", connected_providers=())


async def _running(tmp_path, root, nodes, *, auto=True):
    account, api = FakeAccount(), FakeApi(nodes)
    service = HiveService(
        account=account, credential_store=SimpleNamespace(), data_directory=tmp_path, api=api,
        identity_store=MemoryStore(b64u_encode(root.seed())), node_name="engine",
        auto_approve_account_devices=auto,
    )
    service.attach(SimpleNamespace(state=SimpleNamespace(client_registry=None)))
    account.emit(_user())
    await until(lambda: service.state == "running")
    return service, account, api


def test_pending_account_device_is_approved_without_a_short_code(tmp_path):
    async def scenario():
        root, phone = NodeIdentity.generate(), NodeIdentity.generate()
        service, _, api = await _running(tmp_path, root, [_node(root), _node(phone, kind="thin", status="pending")])
        await service._auto_approve_pending()
        assert [a[0] for a in api.approvals] == [phone.node_id]
        _, approver, sig = api.approvals[0]
        assert approver == root.node_id
        assert verify_signature(root.public_key, sig, approval_message(USER, phone.public_key_b64u))
        assert service.directory.is_trusted(phone.node_id)  # the chain verifies in Directory
        assert service.snapshot()["autoApprove"] is True
        await service.shutdown()

    run(scenario())


def test_auto_approval_is_refused_for_untrusted_cases(tmp_path):
    async def scenario():
        root, bad_proof, no_platform, impostor, victim = (NodeIdentity.generate() for _ in range(5))
        forged = _node(bad_proof, kind="thin", status="pending", proof=b64u_encode(b"x" * 64))
        other_kind = _node(no_platform, kind="server", status="pending")
        mismatched = _node(impostor, kind="thin", status="pending")
        mismatched["id"] = victim.node_id  # id != hash(key)
        service, _, api = await _running(
            tmp_path, root, [_node(root), forged, other_kind, mismatched]
        )
        await service._auto_approve_pending()
        assert api.approvals == []
        await service.shutdown()

    run(scenario())


def test_flag_off_keeps_the_short_code_path(tmp_path):
    async def scenario():
        root, phone = NodeIdentity.generate(), NodeIdentity.generate()
        service, _, api = await _running(
            tmp_path, root, [_node(root), _node(phone, kind="thin", status="pending")], auto=False
        )
        assert await service._auto_approve_pending() == 0
        assert api.approvals == [] and service.snapshot()["autoApprove"] is False
        code = service.sas_for(phone.node_id)
        with pytest.raises(HiveError) as wrong:
            await service.approve(phone.node_id, "000000" if code != "000000" else "111111")
        assert wrong.value.status_code == 400
        await service.approve(phone.node_id, code)
        assert len(api.approvals) == 1
        await service.shutdown()

    run(scenario())


def test_changed_account_does_not_auto_approve(tmp_path):
    async def scenario():
        root, phone = NodeIdentity.generate(), NodeIdentity.generate()
        trusted, _, api = await _running(tmp_path, root, [_node(root), _node(phone, kind="thin", status="pending")])
        trusted._account.current_account_user = _user("someone-else")  # account changed mid-loop
        assert await trusted._auto_approve_pending() == 0 and api.approvals == []
        await trusted.shutdown()

    run(scenario())


def test_auto_approval_is_rate_limited_and_signed_out_service_cannot_approve(tmp_path):
    async def scenario():
        root = NodeIdentity.generate()
        phones = [NodeIdentity.generate() for _ in range(AUTO_APPROVE_LIMIT + 2)]
        nodes = [_node(root)] + [_node(p, kind="thin", status="pending") for p in phones]
        service, account, api = await _running(tmp_path, root, nodes)
        await service._auto_approve_pending()
        assert len(api.approvals) == AUTO_APPROVE_LIMIT
        account.emit(None)
        await service._pending_apply
        assert await service._auto_approve_pending() == 0
        with pytest.raises(HiveError) as signed_out:
            await service.approve("n_x", "123456")
        assert signed_out.value.status_code == 409
        await service.shutdown()

    run(scenario())
