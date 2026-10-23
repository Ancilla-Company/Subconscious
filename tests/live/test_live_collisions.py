"""Scenario 2 (contracts.md section 3): client identity collisions against a REAL engine process."""

import asyncio

import pytest

from live_clients import LocalClient, ThinClient
from live_support import make_workspace, run

pytestmark = pytest.mark.live


def test_hello_twice_on_one_session_is_acknowledged_both_times(engine, unique):
    """Bug class: a client that greets again on the same socket (reconnect logic over a link that is still up)
    is rejected as 'Client_ID already in use' by its own earlier session."""
    client_id = unique.name("twice")

    async def scenario():
        async with LocalClient(engine, client_id=client_id) as client:
            first = await client.hello()
            second = await client.hello()
            assert first["type"] == second["type"] == "client.hello.ack"
            assert first["data"]["clientId"] == second["data"]["clientId"] == client_id

    run(scenario())


def test_the_same_client_id_on_two_sockets_is_still_rejected(engine, unique):
    """Guard for the collision fix: it must only forgive the SAME session, never let a second live socket
    steal an identity (that would let one client impersonate another)."""
    client_id = unique.name("dup")

    async def scenario():
        async with LocalClient(engine, client_id=client_id) as first, LocalClient(engine, client_id=client_id) as second:
            assert (await first.hello())["type"] == "client.hello.ack"
            assert (await second.hello())["type"] == "client.hello.reject"
            assert (await first.hello())["type"] == "client.hello.ack"  # the owner is unaffected

    run(scenario())


def test_two_extension_slots_connect_and_chat_concurrently(engine, unique):
    """Bug class: the extension popup and side panel share one hive identity, so the second page is refused;
    each instance slot has its own node identity and both must be accepted and usable at once."""
    workspace = make_workspace(engine)
    account = engine.account_info

    async def scenario():
        slot0 = ThinClient(engine.server_url, account, name=unique.name("ext-slot0"), platform="browser")
        slot1 = ThinClient(engine.server_url, account, name=unique.name("ext-slot1"), platform="browser")
        try:
            await slot0.start()
            await slot1.start()
            assert slot0.node_id != slot1.node_id
            await slot0.open_link(engine.node_id)
            await slot1.open_link(engine.node_id)
            replies = await asyncio.gather(slot0.hello(engine.node_id), slot1.hello(engine.node_id))
            assert [r.type for r in replies] == ["client.hello.ack", "client.hello.ack"]
            assert replies[0].data["clientId"] != replies[1].data["clientId"]
            texts = await asyncio.gather(
                slot0.chat(engine.node_id, workspace, "from slot zero", turn_id="t-slot0"),
                slot1.chat(engine.node_id, workspace, "from slot one", turn_id="t-slot1"),
            )
            assert "from slot zero" in texts[0] and "from slot one" not in texts[0]
            assert "from slot one" in texts[1] and "from slot zero" not in texts[1]
        finally:
            await slot0.stop()
            await slot1.stop()

    run(scenario())


def test_a_replaced_link_is_accepted_promptly(engine, unique):
    """Bug class: a client reconnects with the same node identity while its old link still exists (network
    change, page reload); the new session's hello is rejected as a duplicate of the dying old one."""
    account = engine.account_info

    async def scenario():
        first = ThinClient(engine.server_url, account, name=unique.name("replace"), platform="browser")
        second = None
        try:
            await first.start()
            await first.open_link(engine.node_id)
            assert (await first.hello(engine.node_id)).type == "client.hello.ack"
            # the same identity connects again from a new socket while the old link is still up
            second = ThinClient(
                engine.server_url, account, name=first.name, platform="browser", identity=first.identity
            )
            await second.start()
            await second.open_link(engine.node_id)
            started = asyncio.get_running_loop().time()
            reply = await second.hello(engine.node_id)
            assert reply.type == "client.hello.ack", reply.data
            assert asyncio.get_running_loop().time() - started < 10
        finally:
            await first.stop()
            if second is not None:
                await second.stop()

    run(scenario())


def test_ten_rapid_reconnects_of_one_node_all_succeed(engine, unique):
    """Bug class: a reconnect loop ('Client_ID already in use' forever) when a client reconnects faster than the
    engine releases the previous session; every one of ten back-to-back reconnects must be acknowledged."""
    account = engine.account_info

    async def scenario():
        identity = None
        outcomes = []
        for index in range(10):
            client = ThinClient(
                engine.server_url, account, name=unique.name("flap"), platform="browser",
                **({"identity": identity} if identity else {}),
            )
            identity = client.identity
            try:
                await client.start()
                await client.open_link(engine.node_id)
                reply = await client.hello(engine.node_id)
                outcomes.append(reply.type)
            finally:
                await client.stop()  # no settle: the next attempt starts immediately
        assert outcomes == ["client.hello.ack"] * 10, outcomes

    run(scenario())


def test_ten_rapid_local_reconnects_with_one_client_id_all_succeed(engine, unique):
    """Bug class: the same loop on the engine's own WebSocket (desktop app / TUI / loopback extension): the
    previous socket's registry entry is still held when the next hello with the same client id arrives."""
    client_id = unique.name("local-flap")

    async def scenario():
        outcomes = []
        for _ in range(10):
            client = await LocalClient(engine, client_id=client_id).connect()
            try:
                outcomes.append((await client.hello())["type"])
            finally:
                await client.close()
        assert outcomes == ["client.hello.ack"] * 10, outcomes

    run(scenario())

    # and the registry is clean afterwards: the id is free again
    async def free_again():
        async with LocalClient(engine, client_id=client_id) as client:
            assert (await client.hello())["type"] == "client.hello.ack"

    run(free_again())
