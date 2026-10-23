"""Scenario 3 (contracts.md section 3): presence, as the server reports it and as the engine's device list shows it."""

import pytest

from live_clients import ThinClient
from live_support import engine_node_is, engine_nodes, run, server_node_is

pytestmark = pytest.mark.live


def test_a_node_is_online_while_its_socket_is_open_and_offline_after_the_grace(server, engine, unique):
    """Bug class: presence sticks (a closed client stays 'online' forever) or never turns on (a connected client
    shows offline); the server and the engine's device list must both follow the signalling socket."""
    account = engine.account_info

    async def scenario():
        thin = ThinClient(server.url, account, name=unique.name("presence"), platform="browser")
        try:
            await thin.start()
            # registered nodes are offline until they hold a signalling socket; this one does
            await server_node_is(server.url, account, thin.node_id, lambda n: n and n["online"], what="server online")
            await engine_node_is(engine, thin.node_id, lambda n: n and n["online"], what="engine sees it online")
            assert thin.online.get(engine.node_id) is True  # and the thin client sees the engine online

            await thin.disconnect_signalling()
            # presence_offline_grace_seconds is 1 in the live settings
            await server_node_is(server.url, account, thin.node_id, lambda n: n and not n["online"], timeout=15, what="server offline")
            await engine_node_is(engine, thin.node_id, lambda n: n and not n["online"], what="engine sees it offline")
        finally:
            await thin.stop()

    run(scenario())


def test_a_node_that_never_connected_is_offline(server, engine, unique):
    """Bug class: registration alone marks a node online (stale 'ghost' devices that can never answer)."""
    account = engine.account_info

    async def scenario():
        thin = ThinClient(server.url, account, name=unique.name("never"), platform="android")
        try:
            await thin.register()
            await server_node_is(server.url, account, thin.node_id, lambda n: n and n["online"] is False, what="offline")
        finally:
            await thin.api.close()

    run(scenario())


def test_the_engine_flags_exactly_itself_as_this_device(server, engine, unique):
    """Bug class: the device list shows no 'this device', or marks a thin client / two rows as local, so the UI
    cannot tell the user which row is the machine they are on."""
    account = engine.account_info

    async def scenario():
        thin = ThinClient(server.url, account, name=unique.name("notlocal"), platform="browser")
        try:
            await thin.start()
            await engine_node_is(engine, thin.node_id, lambda n: n is not None, what="thin listed")
            nodes = engine_nodes(engine)
            local = [node_id for node_id, node in nodes.items() if node["local"]]
            assert local == [engine.node_id]
            assert nodes[engine.node_id]["online"] is True and nodes[thin.node_id]["local"] is False
            assert (nodes[thin.node_id]["kind"], nodes[thin.node_id]["platform"]) == ("thin", "browser")
        finally:
            await thin.stop()

    run(scenario())


def test_presence_of_another_account_is_never_visible(server, engine, unique):
    """Bug class: presence/frames leak across accounts (a stranger's node appears in someone else's device list)."""
    stranger_account = server.accounts["B"] if server.attached else server.fresh_account()

    async def scenario():
        stranger = ThinClient(server.url, stranger_account, name=unique.name("stranger"), platform="browser")
        try:
            await stranger.start()
            await server_node_is(server.url, stranger_account, stranger.node_id, lambda n: n and n["online"])
            assert stranger.node_id not in engine_nodes(engine)
            assert engine.node_id not in stranger.online
        finally:
            await stranger.stop()

    run(scenario())
