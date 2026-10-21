"""Phase 2 hive tests: identity, directory, channels, handshake, authz, tunnel, peers."""

import asyncio
import base64
import json
import re
from contextlib import asynccontextmanager, suppress
from types import SimpleNamespace

import httpx
import pytest

from subconscious_engine.api.app import create_app
from subconscious_engine.auth import (
    PEER_STATE_KEY,
    EngineAuthToken,
    PeerPrincipal,
    trusted_peer,
)
from subconscious_engine.hive import authz
from subconscious_engine.hive.channels import (
    CHUNK_BYTES,
    MAX_MESSAGE_BYTES,
    MAX_REASSEMBLED_BYTES,
    ChannelEndpoint,
    ChannelError,
    Envelope,
    Reassembler,
    decode_message,
    encode_envelope,
    split_message,
)
from subconscious_engine.hive.directory import Directory, PinStore
from subconscious_engine.hive.handshake import HandshakeError, PeerHandshake, extract_fingerprint
from subconscious_engine.hive.http_tunnel import HttpTunnel
from subconscious_engine.hive.identity import (
    IdentityError,
    NodeIdentity,
    ResilientIdentitySeedStore,
    approval_message,
    b64u_decode,
    derive_node_id,
    load_or_create_identity,
    sdp_message,
    short_authentication_string,
    verify_signature,
)
from subconscious_engine.hive.peers import PeerManager, new_sid, sid_timestamp
from subconscious_engine.hive.session import PeerSession
from subconscious_engine.storage import Database

USER = "user-1"


def run(coro):
    return asyncio.run(coro)


# --- helpers -----------------------------------------------------------------


class MemoryStore:
    def __init__(self, fail=False):
        self.value = None
        self.fail = fail

    def read(self):
        if self.fail:
            raise IdentityError("down")
        return self.value

    def write(self, seed):
        if self.fail:
            raise IdentityError("down")
        self.value = seed

    def delete(self):
        self.value = None


def node_entry(identity, *, kind="engine", status="active", approver=None, sig=None):
    return {
        "id": identity.node_id,
        "kind": kind,
        "name": f"node-{identity.node_id[2:6]}",
        "platform": "test",
        "app_version": "0",
        "protocol_version": 1,
        "public_key": identity.public_key_b64u,
        "status": status,
        "approved_by": approver.node_id if approver else None,
        "approval_sig": sig,
        "capabilities": {},
        "online": True,
    }


def approve(approver, new, user=USER):
    return approver.sign(approval_message(user, new.public_key_b64u))


def make_directory(local, *entries):
    directory = Directory(USER, local.node_id, PinStore(None))
    directory.update(list(entries), "hive-1")
    return directory


class NullSignaler:
    def __init__(self):
        self.sent = []

    async def send_signal(self, sid, to, kind, body, sig):
        self.sent.append((sid, to, kind, body, sig))


async def no_ice():
    return {}


# --- identity ------------------------------------------------------------------


def test_node_id_is_derived_from_key_and_sign_verify_rejects_tampering():
    identity = NodeIdentity.generate()
    assert identity.node_id == derive_node_id(identity.public_key)
    assert identity.node_id.startswith("n_") and identity.node_id == identity.node_id.lower()
    message = b"sc-sdp-v1\nsid\na\nb\nhash"
    signature = identity.sign(message)
    assert verify_signature(identity.public_key, signature, message)
    assert not verify_signature(identity.public_key, signature, message + b"x")
    assert not verify_signature(NodeIdentity.generate().public_key, signature, message)
    assert not verify_signature(identity.public_key, "not base64 !!", message)
    assert not verify_signature(b"short", signature, message)
    flipped = bytearray(b64u_decode(signature))
    flipped[0] ^= 1
    assert not verify_signature(
        identity.public_key, base64.urlsafe_b64encode(bytes(flipped)).decode().rstrip("="), message
    )
    assert identity.seed().hex() not in repr(identity)


def test_identity_is_created_once_and_fallback_store_is_used_when_keyring_fails():
    store = MemoryStore()
    first = load_or_create_identity(store)
    assert load_or_create_identity(store).node_id == first.node_id
    primary, fallback = MemoryStore(fail=True), MemoryStore()
    resilient = ResilientIdentitySeedStore(primary, fallback)
    created = load_or_create_identity(resilient)
    assert fallback.value is not None
    assert load_or_create_identity(resilient).node_id == created.node_id


def test_short_authentication_string_is_symmetric_six_digits():
    a, b = NodeIdentity.generate(), NodeIdentity.generate()
    code = short_authentication_string(a.public_key, b.public_key)
    assert code == short_authentication_string(b.public_key, a.public_key)
    assert len(code) == 6 and code.isdigit()


# --- directory ---------------------------------------------------------------


def test_active_account_nodes_are_members_without_approval_signatures():
    root, other, thin = (NodeIdentity.generate() for _ in range(3))
    entries = [node_entry(root), node_entry(other), node_entry(thin, kind="thin")]
    directory = make_directory(root, *entries)
    for identity in (root, other, thin):
        assert directory.is_trusted(identity.node_id)


def test_revoked_pending_and_pinned_key_changes_are_not_trusted(tmp_path):
    root, member = NodeIdentity.generate(), NodeIdentity.generate()
    sig = approve(root, member)
    pins = PinStore(tmp_path / "pins.json")
    directory = Directory(USER, root.node_id, pins)
    directory.update([node_entry(root), node_entry(member, approver=root, sig=sig)])
    assert directory.is_trusted(member.node_id)
    directory.update([node_entry(root), node_entry(member, status="revoked", approver=root, sig=sig)])
    assert not directory.is_trusted(member.node_id)
    # a server swapping the key under a known id is ignored (id no longer matches)
    swapped = node_entry(member, approver=root, sig=sig)
    swapped["public_key"] = NodeIdentity.generate().public_key_b64u
    directory.update([node_entry(root), swapped])
    assert directory.get(member.node_id) is None
    # pins survive a restart
    assert PinStore(tmp_path / "pins.json").keys[member.node_id] == member.public_key_b64u


def test_key_swaps_and_non_active_nodes_are_still_not_members():
    root, pending = NodeIdentity.generate(), NodeIdentity.generate()
    directory = make_directory(root, node_entry(root), node_entry(pending, status="pending"))
    assert directory.is_trusted(root.node_id)
    assert not directory.is_trusted(pending.node_id)


# --- channels --------------------------------------------------------------------


def test_small_messages_are_not_chunked_and_large_ones_reassemble_within_limits():
    small = encode_envelope(Envelope("ping", {"a": 1}, "1", "n_a", "n_b"))
    assert split_message(small) == [small]
    big = encode_envelope(Envelope("blob", {"text": "é" * 100_000}, "7"))
    parts = split_message(big)
    assert len(parts) > 1
    assert all(len(p.encode()) <= MAX_MESSAGE_BYTES for p in parts)
    reassembler, result = Reassembler(), None
    for part in reversed(parts):
        result = decode_message(reassembler, part) or result
    assert result == Envelope("blob", {"text": "é" * 100_000}, "7")
    assert reassembler.open_streams == 0


def test_chunking_rejects_oversize_duplicate_malformed_and_nested_input():
    with pytest.raises(ChannelError):
        split_message(json.dumps({"v": 1, "type": "x", "data": "a" * (MAX_REASSEMBLED_BYTES + 10)}))
    with pytest.raises(ChannelError):
        decode_message(Reassembler(), "x" * (MAX_MESSAGE_BYTES + 1))
    with pytest.raises(ChannelError):
        decode_message(Reassembler(), b"binary")
    with pytest.raises(ChannelError):
        decode_message(Reassembler(), "not json")
    with pytest.raises(ChannelError):
        decode_message(Reassembler(), json.dumps({"v": 2, "type": "x"}))
    parts = [json.loads(p) for p in split_message(encode_envelope(Envelope("b", "z" * 40_000)))]
    reassembler = Reassembler()
    reassembler.feed(parts[0])
    with pytest.raises(ChannelError):
        reassembler.feed(parts[0])  # duplicate index
    with pytest.raises(ChannelError):
        Reassembler().feed({**parts[0], "total": 10**6})  # declared size over the cap
    small_cap = Reassembler(max_bytes=CHUNK_BYTES + 100)
    chunk_a = {"stream": "s", "index": 0, "total": 2, "data": base64.b64encode(b"a" * CHUNK_BYTES).decode()}
    chunk_b = {**chunk_a, "index": 1}
    small_cap.feed(chunk_a)
    with pytest.raises(ChannelError):
        small_cap.feed(chunk_b)  # running total passes the cap


def test_reassembly_times_out_and_limits_concurrent_streams():
    now = [0.0]
    reassembler = Reassembler(timeout=5, max_streams=2, clock=lambda: now[0])
    chunk = lambda s: {"stream": s, "index": 0, "total": 2, "data": "AA=="}  # noqa: E731
    reassembler.feed(chunk("a"))
    reassembler.feed(chunk("b"))
    with pytest.raises(ChannelError):
        reassembler.feed(chunk("c"))
    now[0] = 6.0
    assert reassembler.expire() == 2
    reassembler.feed(chunk("c"))
    assert reassembler.open_streams == 1


class FakeChannel:
    def __init__(self):
        self.readyState = "open"
        self.bufferedAmount = 0
        self.bufferedAmountLowThreshold = 0
        self.sent = []
        self.handlers = {}

    def on(self, event, f=None):
        self.handlers[event] = f
        return f

    def send(self, data):
        self.sent.append(data)

    def close(self):
        self.readyState = "closed"


def test_endpoint_backpressure_pauses_until_buffer_drains():
    async def scenario():
        channel = FakeChannel()
        endpoint = ChannelEndpoint("rpc", channel, lambda *_: None)
        channel.bufferedAmount = 10 * 1024 * 1024
        task = asyncio.ensure_future(endpoint.send(Envelope("x", 1)))
        await asyncio.sleep(0.05)
        assert channel.sent == [] and not task.done()
        channel.bufferedAmount = 0
        channel.handlers["bufferedamountlow"]()
        await asyncio.wait_for(task, 1)
        assert len(channel.sent) == 1
    run(scenario())


# --- handshake ---------------------------------------------------------------------


def _pair(offer_fp_a="sha-256 AA", answer_fp_a="sha-256 BB", offer_fp_b="sha-256 AA", answer_fp_b="sha-256 BB"):
    a, b = NodeIdentity.generate(), NodeIdentity.generate()
    ha = PeerHandshake(a, b.node_id, b.public_key, offer_fp_a, answer_fp_a, True)
    hb = PeerHandshake(b, a.node_id, a.public_key, offer_fp_b, answer_fp_b, False)
    return a, b, ha, hb


def test_handshake_authenticates_matching_fingerprints():
    _, _, ha, hb = _pair()
    proof_a, proof_b = ha.receive_hello(hb.hello()), hb.receive_hello(ha.hello())
    ha.receive_proof(proof_b)
    hb.receive_proof(proof_a)
    assert ha.authenticated and hb.authenticated


def test_handshake_fails_on_fingerprint_mismatch_wrong_node_and_reflection():
    _, _, ha, hb = _pair(answer_fp_b="sha-256 CC")  # a MITM terminated DTLS with another cert
    proof_a, proof_b = ha.receive_hello(hb.hello()), hb.receive_hello(ha.hello())
    with pytest.raises(HandshakeError):
        ha.receive_proof(proof_b)
    with pytest.raises(HandshakeError):
        hb.receive_proof(proof_a)
    _, _, ha, hb = _pair()
    with pytest.raises(HandshakeError):
        ha.receive_hello({"node_id": "n_other", "nonce": "x" * 16})
    with pytest.raises(HandshakeError):
        ha.receive_hello(ha.hello() | {"node_id": hb.hello()["node_id"]})  # reflected nonce
    with pytest.raises(HandshakeError):
        ha.receive_proof({"sig": "AAAA"})  # proof before hello


def test_extract_fingerprint_requires_exactly_one_value():
    sdp = "v=0\r\na=fingerprint:sha-256 AB:CD:EF\r\n"
    assert extract_fingerprint(sdp) == "sha-256 AB:CD:EF"
    # aiortc lists several hash algorithms for one certificate; sha-256 is bound
    assert extract_fingerprint(sdp + "a=fingerprint:sha-512 01:02\r\n") == "sha-256 AB:CD:EF"
    with pytest.raises(HandshakeError):
        extract_fingerprint("v=0\r\n")
    with pytest.raises(HandshakeError):
        extract_fingerprint(sdp + "a=fingerprint:sha-256 01:02:03\r\n")


# --- signed signalling: tamper, freshness, replay ---------------------------------


def _manager(local, directory, clock):
    return PeerManager(local, directory, NullSignaler(), no_ice, clock=clock)


def _offer(sender, recipient, sdp="v=0 test", sid=None, now=1000.0, kind="offer"):
    sid = sid or new_sid(now)
    return {
        "from": sender.node_id,
        "sid": sid,
        "kind": kind,
        "body": {"type": kind, "sdp": sdp},
        "sig": sender.sign(sdp_message(sid, sender.node_id, recipient.node_id, sdp)),
    }


def test_signed_offer_verifies_and_rejects_tamper_replay_staleness_and_strangers():
    local, remote, stranger = NodeIdentity.generate(), NodeIdentity.generate(), NodeIdentity.generate()
    directory = make_directory(
        local, node_entry(local), node_entry(remote, approver=local, sig=approve(local, remote))
    )
    now = [1000.0]
    manager = _manager(local, directory, lambda: now[0])
    good = _offer(remote, local)
    assert manager._verify_signal(good, "offer") is not None
    assert manager._verify_signal(good, "offer") is None  # replay
    tampered = _offer(remote, local)
    tampered["body"] = {"type": "offer", "sdp": "v=0 evil"}
    assert manager._verify_signal(tampered, "offer") is None
    misaddressed = _offer(remote, stranger)  # signed for someone else
    assert manager._verify_signal(misaddressed, "offer") is None
    assert manager._verify_signal(_offer(stranger, local), "offer") is None  # untrusted sender
    stale = _offer(remote, local, now=900.0)
    assert manager._verify_signal(stale, "offer") is None
    future = _offer(remote, local, now=1100.0)
    assert manager._verify_signal(future, "offer") is None
    now[0] = 1050.0
    assert manager._verify_signal(_offer(remote, local, now=1000.0), "offer") is not None
    assert sid_timestamp("abc") is None and sid_timestamp("12.x") == 12.0


def test_forged_offer_never_creates_a_peer_connection():
    local, remote, attacker = NodeIdentity.generate(), NodeIdentity.generate(), NodeIdentity.generate()
    directory = make_directory(
        local, node_entry(local), node_entry(remote, approver=local, sig=approve(local, remote))
    )
    signaler = NullSignaler()
    manager = PeerManager(local, directory, signaler, no_ice, clock=lambda: 1000.0)
    forged = _offer(attacker, local)
    forged["from"] = remote.node_id  # attacker impersonates a trusted node
    run(manager.handle_signal(forged))
    assert signaler.sent == [] and manager.links == {}
    assert manager.state_of(remote.node_id) == "disconnected"


# --- authz matrix --------------------------------------------------------------------

ALLOWED_HTTP = {
    ("GET", "/api/v1/health"),
    ("GET", "/api/v1/hive/tasks"),
    ("GET", "/api/v1/workspaces"),
    ("GET", "/api/v1/workspaces/x"),
    ("GET", "/api/v1/workspaces/x/threads"),
    ("POST", "/api/v1/threads"),
    ("GET", "/api/v1/threads/x"),
    ("GET", "/api/v1/threads/x/messages"),
    ("POST", "/api/v1/messages"),
    ("GET", "/api/v1/models"),
}
FRAMES = [
    "client.hello", "ping", "chat.send", "chat.cancel", "tool.approval.response",
    "client.tool.result", "tool.register", "tool.unregister", "profile.set",
    "chat.notification", "tool.call", "tool.result", "sync.pull", "sync.push", "task.create",
    "tool.list", "tool.list.result", "tool.cancel",
    "settings.update", "unknown", "",
]
COMMON_FRAMES = set(FRAMES[:9])


def _route_samples(app):
    for route in app.routes:
        path = getattr(route, "path", None)
        if not path or not path.startswith("/api/v1"):
            continue
        concrete = re.sub(r"\{[^}]+\}", "x", path)
        for method in getattr(route, "methods", None) or ["GET"]:
            yield method, concrete


@asynccontextmanager
async def engine_app(tmp_path, name="engine.db"):
    database = Database(tmp_path / name)
    await database.initialize()
    store = SimpleNamespace()

    async def resolve(identifier):
        return None

    store.resolve = resolve
    app = create_app(
        database, EngineAuthToken("secret-token"), model_configuration_store=store, dev_models=True
    )
    try:
        yield app
    finally:
        await database.close()


def test_authz_matrix_every_real_route_per_role(tmp_path):
    async def scenario():
        async with engine_app(tmp_path) as app:
            samples = set(_route_samples(app))
            assert ("GET", "/api/v1/workspaces") in samples
            for role in (authz.THIN_CLIENT, authz.HIVE_PEER):
                for method, path in samples:
                    expected = (method, path) in ALLOWED_HTTP
                    assert authz.authorize_http(role, method, path) is expected, (role, method, path)
                for method, path in sorted(ALLOWED_HTTP):
                    assert authz.authorize_http(role, method, path)
                    assert not authz.authorize_http(role, "PATCH", path)
            for denied in (
                "/api/v1/account/login", "/api/v1/settings", "/api/v1/model-configurations",
                "/api/v1/tools", "/api/v1/rag/index", "/api/v1/hive/nodes", "/api/v1/hive/enroll",
                "/api/v1/workspaces/x/files", "/api/v1/events", "/api/v1/hive/remote-tools",
            ):
                for role in authz.ROLES:
                    for method in ("GET", "POST", "PUT", "DELETE"):
                        assert not authz.authorize_http(role, method, denied)
            assert not authz.authorize_http("nobody", "GET", "/api/v1/health")
    run(scenario())


def test_authz_rejects_path_tricks_and_unknown_roles():
    for path in (
        "/api/v1/workspaces/../settings", "/api/v1//workspaces", "/api/v1/workspaces/%2e%2e/x",
        "api/v1/workspaces", "/api/v1/workspaces\\x", "/api/v1/workspaces/./x",
    ):
        assert authz.normalise_path(path) is None
        assert not authz.authorize_http(authz.HIVE_PEER, "GET", path)
    assert authz.role_for_kind("engine") == authz.HIVE_PEER
    assert authz.role_for_kind("thin") == authz.THIN_CLIENT
    assert authz.role_for_kind("bogus") is None


def test_authz_frame_matrix_per_role():
    for frame in FRAMES:
        thin = authz.authorize_frame(authz.THIN_CLIENT, frame)
        peer = authz.authorize_frame(authz.HIVE_PEER, frame)
        assert thin is (frame in COMMON_FRAMES), frame
        expected_peer = frame in COMMON_FRAMES or frame in {
            "chat.notification", "tool.call", "tool.result", "sync.pull", "sync.push", "task.create",
            "tool.list", "tool.list.result", "tool.cancel",
        }
        assert peer is expected_peer, frame
        assert not authz.authorize_frame("nobody", frame)
    assert not authz.authorize_frame(authz.HIVE_PEER, None)  # type: ignore[arg-type]


# --- tunnel principal ------------------------------------------------------------------


def test_external_requests_cannot_spoof_the_peer_principal(tmp_path):
    async def scenario():
        async with engine_app(tmp_path) as app:
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as client:
                spoof_headers = {PEER_STATE_KEY: "x", "x-hive-peer": "n_x", "state": "{}"}
                assert (await client.get("/api/v1/workspaces", headers=spoof_headers)).status_code == 401
                assert (await client.get(f"/api/v1/workspaces?{PEER_STATE_KEY}=1")).status_code == 401
            assert trusted_peer({"state": {PEER_STATE_KEY: {"node_id": "n", "role": "hive_peer"}}}) is None
            assert trusted_peer({"state": {PEER_STATE_KEY: "n_x"}}) is None
            assert trusted_peer({}) is None
            principal = PeerPrincipal("n_x", authz.HIVE_PEER)
            assert trusted_peer({"state": {PEER_STATE_KEY: principal}}) is principal
    run(scenario())


def _http(identifier, method, path, body=None):
    data = {"method": method, "path": path, "headers": {"authorization": "Bearer evil", "content-type": "application/json"}}
    if body is not None:
        data["body"] = base64.b64encode(json.dumps(body).encode()).decode()
    return Envelope("http.request", data, identifier)


def test_tunnel_serves_allowlisted_routes_without_a_bearer_and_denies_the_rest(tmp_path):
    async def scenario():
        async with engine_app(tmp_path) as app:
            tunnel = HttpTunnel(app, PeerPrincipal("n_peer", authz.THIN_CLIENT))
            try:
                ok = await tunnel.handle(_http("1", "GET", "/api/v1/workspaces"))
                assert ok.id == "1" and ok.data["status"] == 200
                assert json.loads(base64.b64decode(ok.data["body"])) == []
                for method, path in (
                    ("GET", "/api/v1/settings"), ("POST", "/api/v1/account/logout"),
                    ("POST", "/api/v1/hive/enroll"), ("GET", "/api/v1/workspaces/../settings"),
                    ("PATCH", "/api/v1/workspaces"),
                ):
                    denied = await tunnel.handle(_http("2", method, path))
                    assert denied.data["status"] in {400, 403}, (method, path)
                assert (await tunnel.handle(Envelope("http.request", "nope", "3"))).data["status"] == 400
                assert (await tunnel.handle(Envelope("other", {}, "4"))).data["status"] == 400
                # an allowlisted route still reaches the real app (404 here, not 401)
                missing = await tunnel.handle(_http("5", "GET", "/api/v1/threads/none"))
                assert missing.data["status"] == 404
                assert "authorization" not in missing.data["headers"]
            finally:
                await tunnel.aclose()
    run(scenario())


# --- loopback + glare over real aiortc with an in-memory signalling hub -------------------


class FakeHub:
    """Delivers signal frames between managers like the server would."""

    def __init__(self):
        self.managers = {}
        self.log = []

    def signaler_for(self, node_id):
        hub = self

        class Signaler:
            async def send_signal(self, sid, to, kind, body, sig):
                hub.log.append((node_id, to, kind))
                target = hub.managers.get(to)
                if target is None:
                    return
                frame = {"sid": sid, "from": node_id, "kind": kind, "body": body}
                if sig is not None:
                    frame["sig"] = sig
                asyncio.ensure_future(target.handle_signal(frame))

        return Signaler()


def _hive_pair():
    a, b = NodeIdentity.generate(), NodeIdentity.generate()
    entries = [node_entry(a), node_entry(b, approver=a, sig=approve(a, b))]
    return a, b, entries


def _build_managers(a, b, entries, hub, on_link_a=None, on_link_b=None):
    pa = PeerManager(a, make_directory(a, *entries), hub.signaler_for(a.node_id), no_ice, on_link=on_link_a)
    pb = PeerManager(b, make_directory(b, *entries), hub.signaler_for(b.node_id), no_ice, on_link=on_link_b)
    hub.managers[a.node_id], hub.managers[b.node_id] = pa, pb
    return pa, pb


def test_peer_loopback_chat_send_gets_echo_chat_done_over_peer_session(tmp_path):
    async def scenario():
        a, b, entries = _hive_pair()
        hub = FakeHub()
        async with engine_app(tmp_path) as app_b:
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app_b), base_url="http://t",
                headers={"Authorization": "Bearer secret-token"},
            ) as local:
                workspace = (await local.post(
                    "/api/v1/workspaces", json={"name": "W", "defaultModelId": "echo"}
                )).json()["uuid"]
            sessions, inbox = {}, asyncio.Queue()

            def on_link_b(link):
                session = PeerSession(app_b, link, "node-a")
                sessions[link.node_id] = session
                link.handler = lambda lk, ch, env: session.feed(env)
                session.start()

            def on_link_a(link):
                link.handler = lambda lk, ch, env: inbox.put_nowait((ch, env))

            pa, pb = _build_managers(a, b, entries, hub, on_link_a, on_link_b)
            try:
                link = await asyncio.wait_for(pa.connect(b.node_id), 30)
                assert link.tier == "direct" and link.role == authz.HIVE_PEER
                assert pa.state_of(b.node_id) == "connected"
                await link.send_frame("control", "client.hello", {"clientId": "spoofed"})
                await link.send_frame(
                    "control", "chat.send", {"workspace_uuid": workspace, "content": "hello hive"}, "turn-1"
                )
                frames = []
                while not any(env.type == "chat.done" for _, env in frames):
                    frames.append(await asyncio.wait_for(inbox.get(), 30))
                assert any(env.type == "client.hello.ack" for _, env in frames)
                deltas = [env.data["delta"] for _, env in frames if env.type == "chat.delta"]
                assert "hello hive" in "".join(deltas)
                assert any(ch == "events" for ch, env in frames if env.type == "chat.delta")
            finally:
                for session in sessions.values():
                    await session.stop()
                await pa.close()
                await pb.close()
    run(scenario())


def test_glare_both_sides_offer_simultaneously_and_converge_on_one_link(tmp_path):
    async def scenario():
        a, b, entries = _hive_pair()
        hub = FakeHub()
        pa, pb = _build_managers(a, b, entries, hub)
        try:
            results = await asyncio.wait_for(
                asyncio.gather(pa.connect(b.node_id), pb.connect(a.node_id), return_exceptions=True), 45
            )
            await asyncio.sleep(1.0)
            polite_first = a if a.node_id < b.node_id else b
            assert pa.is_polite(b.node_id) is (polite_first is a)
            assert sum(1 for r in results if not isinstance(r, Exception)) >= 1
            await asyncio.wait_for(_until(lambda: pa.link(b.node_id) and pb.link(a.node_id)), 30)
            # a working link in both directions
            la, lb = pa.link(b.node_id), pb.link(a.node_id)
            got = asyncio.Queue()
            lb.handler = lambda lk, ch, env: got.put_nowait(env)
            await la.send_frame("control", "ping", None, "p1")
            assert (await asyncio.wait_for(got.get(), 10)).type == "ping"
        finally:
            await pa.close()
            await pb.close()
    run(scenario())


async def _until(predicate):
    while not predicate():
        await asyncio.sleep(0.1)


def test_unknown_nodes_cannot_be_dialled():
    async def scenario():
        a, b, entries = _hive_pair()
        rogue = NodeIdentity.generate()
        manager = PeerManager(a, make_directory(a, *entries, node_entry(rogue, status="pending")), NullSignaler(), no_ice)
        with pytest.raises(ConnectionError):
            await manager.connect(rogue.node_id)
        with pytest.raises(ConnectionError):
            await manager.connect("n_unknown")
        with suppress(Exception):
            await manager.close()
    run(scenario())
