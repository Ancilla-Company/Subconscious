"""Scenario 5 (contracts.md section 3): a thin client reaches a REAL engine through the signalling relay."""

import asyncio
import json

import pytest

from live_clients import ThinClient
from live_support import UNKNOWN_NODE_ID, frame_of, make_workspace, raw_open, run

pytestmark = pytest.mark.live


def test_relay_client_hello_chat_and_rest_round_trip(server, engine, unique):
    """Bug class: with WebRTC unavailable (corporate network, extension, mobile) the relay fallback silently
    breaks: no hello ack, no chat stream, or the REST tunnel answers nothing."""
    workspace = make_workspace(engine, "Relay W")

    async def scenario():
        thin = ThinClient(server.url, engine.account_info, name=unique.name("relay"), platform="browser", force_relay=True)
        try:
            await thin.start()
            link = await thin.open_link(engine.node_id)
            assert link.tier == "ws-relay"
            assert (await thin.hello(engine.node_id)).type == "client.hello.ack"
            text = await thin.chat(engine.node_id, workspace, "hello through the relay", turn_id="relay-1")
            assert "hello through the relay" in text
            status, body = await thin.rest(engine.node_id, "GET", "/api/v1/workspaces")
            assert status == 200 and workspace in [w["uuid"] for w in body]
            status, _ = await thin.rest(engine.node_id, "GET", "/api/v1/settings")
            assert status in {400, 403}  # not on the thin-client allowlist
        finally:
            await thin.stop()

    run(scenario())


def test_two_concurrent_relay_clients_do_not_interfere(server, engine, unique):
    """Bug class: relay sessions share state (one client's stream arrives at the other, or the second client
    kills the first); two clients chatting at once must each get exactly their own reply."""
    workspace = make_workspace(engine, "Relay two")

    async def scenario():
        first = ThinClient(server.url, engine.account_info, name=unique.name("relay-a"), platform="browser")
        second = ThinClient(server.url, engine.account_info, name=unique.name("relay-b"), platform="web")
        try:
            await first.start()
            await second.start()
            await first.open_link(engine.node_id)
            await second.open_link(engine.node_id)
            await first.hello(engine.node_id)
            await second.hello(engine.node_id)
            texts = await asyncio.gather(
                first.chat(engine.node_id, workspace, "message of the first client", turn_id="turn-a"),
                second.chat(engine.node_id, workspace, "message of the second client", turn_id="turn-b"),
            )
            assert "message of the first client" in texts[0] and "second client" not in texts[0]
            assert "message of the second client" in texts[1] and "first client" not in texts[1]
            assert not first.of_type("chat.done", "turn-b") and not second.of_type("chat.done", "turn-a")
            # both links stay up and usable
            statuses = await asyncio.gather(
                first.rest(engine.node_id, "GET", "/api/v1/health"), second.rest(engine.node_id, "GET", "/api/v1/health")
            )
            assert [s for s, _ in statuses] == [200, 200]
        finally:
            await first.stop()
            await second.stop()

    run(scenario())


def test_another_accounts_client_cannot_reach_the_engine(server, engine, unique):
    """Bug class: account isolation holes on the relay path: a stranger's node can open a link to, address a
    relay frame at, or read presence of an engine that belongs to somebody else."""
    stranger_account = server.accounts["B"] if server.attached else server.fresh_account()
    assert stranger_account["user_id"] != engine.account_info["user_id"]

    async def scenario():
        stranger = ThinClient(server.url, stranger_account, name=unique.name("stranger"), platform="browser")
        try:
            await stranger.start()
            assert stranger.directory.get(engine.node_id) is None
            with pytest.raises(ConnectionError):
                await stranger.peers.connect(engine.node_id)
            # at protocol level: a relay frame addressed at the engine is answered 'unknown_node'
            socket, _ticket = await raw_open(stranger.api, stranger.identity)
            try:
                assert (await frame_of(socket))["type"] == "auth.ok"
                for target in (engine.node_id, UNKNOWN_NODE_ID):
                    await socket.send(json.dumps({"v": 1, "type": "relay", "data": {
                        "sid": f"1.{target[2:6]}", "to": target, "payload": "AQIDBA"}}))
                    reply = await frame_of(socket)
                    while reply["type"] in {"presence.snapshot", "presence.update"}:
                        reply = await frame_of(socket)
                    assert reply == {"v": 1, "type": "error", "data": {"code": "unknown_node"}}, reply
            finally:
                await socket.close()
        finally:
            await stranger.stop()

    run(scenario())
