"""A client that greets twice must not be rejected as a duplicate of itself."""

import asyncio
from types import SimpleNamespace
from unittest.mock import AsyncMock

from subconscious_engine.api.websocket import ClientRegistry, WebSocketSession


class Socket:
    def __init__(self, registry):
        self.app = SimpleNamespace(state=SimpleNamespace(
            client_registry=registry, event_bus=SimpleNamespace(publish=AsyncMock())))
        self.sent = []

    async def accept(self):
        return None

    async def receive_json(self):
        raise NotImplementedError

    async def send_json(self, value):
        self.sent.append(value)


def run(coro):
    return asyncio.run(coro)


def test_same_session_hello_twice_is_acknowledged_both_times():
    async def scenario():
        registry = ClientRegistry()
        socket = Socket(registry)
        session = WebSocketSession(socket)
        hello = {"type": "client.hello", "data": {"clientId": "peer:n_abc", "clientName": "A"}}
        await session._handle(hello)
        await session._handle(hello)
        types = [frame["type"] for frame in socket.sent]
        assert types == ["client.hello.ack", "client.hello.ack"]
        assert [client.client_id for client in registry.snapshot()] == ["peer:n_abc"]
    run(scenario())


def test_a_different_session_with_the_same_id_is_still_rejected():
    async def scenario():
        registry = ClientRegistry()
        first, second = Socket(registry), Socket(registry)
        hello = {"type": "client.hello", "data": {"clientId": "peer:n_abc"}}
        await WebSocketSession(first)._handle(hello)
        await WebSocketSession(second)._handle(hello)
        assert first.sent[0]["type"] == "client.hello.ack"
        assert second.sent[0]["type"] == "client.hello.reject"
    run(scenario())
