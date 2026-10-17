import asyncio
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import AsyncMock

from subconscious_engine import client_identity
from subconscious_engine.api.websocket import ClientRegistry, WebSocketSession
from subconscious_engine.client_identity import (
    ClientInfo,
    build_client_info,
    client_menu_labels,
    is_local_address,
    parse_identity,
)


def info(kind, local=True, address=None, name=None):
    identity = parse_identity({"client_type": kind})
    return build_client_info(
        "id", identity, address=address, is_local=local, node_name=name
    )


def test_parse_unknown_type_and_sanitise():
    assert parse_identity({"client_type": "evil"}).type == "unknown"
    assert parse_identity({}).type == "unknown"
    assert parse_identity({"client_type": "TUI"}).type == "tui"
    assert parse_identity({"client_type": "Browser-Extension"}).type == "browser_extension"
    identity = parse_identity({"client_name": "a\x00b\n  c" + "x" * 200, "client_version": "1" * 99})
    assert "\x00" not in identity.name and "\n" not in identity.name
    assert len(identity.name) == 64 and len(identity.version) == 32


def test_parse_non_str_query_precedence_and_token_ignored():
    assert parse_identity({"client_type": 5}, {"clientType": "mobile"}).type == "mobile"
    assert parse_identity({"client_type": "tui"}, {"clientType": "mobile"}).type == "tui"
    identity = parse_identity({"token": "SECRET", "client_type": "cli"}, {"token": "SECRET"})
    assert "SECRET" not in repr(identity)


def test_is_local_address(monkeypatch):
    for host in ("127.0.0.1", "127.5.5.5", "::1", "::ffff:127.0.0.1"):
        assert is_local_address(host)
    monkeypatch.setattr(client_identity, "_own_addresses", frozenset({"10.0.0.7"}))
    assert is_local_address("10.0.0.7")
    assert not is_local_address("192.168.1.5")
    assert not is_local_address("garbage")
    assert not is_local_address(None)


def test_labels():
    assert client_menu_labels(()) == ("No clients connected",)
    clients = (
        info("desktop", False, "192.168.1.5"),
        info("tui"),
        info("desktop"),
        info("desktop"),
        info("mobile", False, None, name="Phone"),
    )
    assert client_menu_labels(clients) == (
        "Desktop x2 (local)",
        "TUI (local)",
        "Desktop (remote, 192.168.1.5)",
        "Phone (remote)",
    )


def test_label_has_no_port_or_peer_id_for_local():
    labels = client_menu_labels((info("tui", True, "127.0.0.1"),))
    assert labels == ("TUI (local)",)


def test_registry_stores_client_info():
    async def scenario():
        registry = ClientRegistry()
        seen = []
        registry.subscribe(seen.append)
        ident = parse_identity({"client_type": "tui", "client_version": "1.2"})
        assert await registry.acquire("a", identity=ident, address="127.0.0.1", is_local=True) == "a"
        assert await registry.acquire("a") is None
        (client,) = registry.snapshot()
        assert isinstance(client, ClientInfo)
        assert (client.type, client.version, client.is_local) == ("tui", "1.2", True)
        assert client.connected_at.tzinfo is not None
        await registry.release("a")
        assert seen[-1] == ()

    asyncio.run(scenario())


class _Socket:
    def __init__(self, registry, query, host, link=None, display_name=""):
        self.app = SimpleNamespace(state=SimpleNamespace(
            client_registry=registry, event_bus=SimpleNamespace(publish=AsyncMock())))
        self.query_params = query
        self.client = SimpleNamespace(host=host, port=5555)
        self.headers = {"x-forwarded-for": "127.0.0.1"}
        if link is not None:
            self.link = link
            self.display_name = display_name
        self.sent = []

    async def send_json(self, value):
        self.sent.append(value)


def _hello(socket, data=None):
    async def scenario():
        session = WebSocketSession(socket)
        await session._hello(data or {})
        return session

    return asyncio.run(scenario())


def test_session_hello_local_and_remote():
    registry = ClientRegistry()
    _hello(_Socket(registry, {"client_type": "tui", "token": "S", "client": "flutter"}, "127.0.0.1"))
    _hello(_Socket(registry, {"client_type": "desktop"}, "203.0.113.9"))
    assert client_menu_labels(registry.snapshot()) == (
        "TUI (local)", "Desktop (remote, 203.0.113.9)")


def test_session_hello_peer_is_remote():
    registry = ClientRegistry()
    _hello(_Socket(registry, {}, "peer:abc", link=object(), display_name="Phone"),
           {"clientId": "peer:abc", "clientType": "mobile"})
    (client,) = registry.snapshot()
    assert not client.is_local and client.address is None
    assert client_menu_labels((client,)) == ("Phone (remote)",)
