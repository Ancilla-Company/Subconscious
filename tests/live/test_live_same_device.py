"""Scenario 4a (contracts.md section 3): a client on the same machine (loopback) as the engine."""

import pytest

from live_clients import LocalClient
from live_support import engine_node_is, make_workspace, run, server_nodes

pytestmark = pytest.mark.live


def test_loopback_browser_extension_is_a_local_client_of_the_engine(engine, unique):
    """Bug class: the extension running on the engine's own machine is reported as a remote/unknown client
    (or never shows up), so the tray and the device list cannot say 'Browser extension is connected here'."""

    async def scenario():
        async with LocalClient(engine, client_id=unique.name("ext-loop"), client_type="browser_extension") as client:
            ack = await client.hello()
            assert ack["type"] == "client.hello.ack" and ack["data"]["local"] is True
            node = await engine_node_is(
                engine, engine.node_id, lambda n: n and "Browser extension" in n["clients"], what="local client listed"
            )
            assert node["local"] is True
        # and it is removed again when the client disconnects
        await engine_node_is(
            engine, engine.node_id, lambda n: n and "Browser extension" not in n["clients"], what="local client removed"
        )

    run(scenario())


def test_a_loopback_extension_registers_no_thin_node(server, engine, unique):
    """Bug class: connecting to the engine over loopback also enrols a server-side thin node for the extension
    ('same device' must stay a plain local client, otherwise every machine lists itself twice)."""
    before = set(server_nodes(server.url, engine.account_info))

    async def scenario():
        async with LocalClient(engine, client_id=unique.name("ext-nothin"), client_type="browser_extension") as client:
            await client.hello()
            await engine_node_is(engine, engine.node_id, lambda n: n and "Browser extension" in n["clients"])
            await client.chat(make_workspace(engine), "hello from the same device", turn_id="same-device")

    run(scenario())
    assert set(server_nodes(server.url, engine.account_info)) == before


def test_each_client_type_gets_its_own_display_name(engine, unique):
    """Bug class: clients are all labelled 'Unknown' (client_type query parameter / hello field ignored)."""

    async def scenario():
        async with (
            LocalClient(engine, client_id=unique.name("t-vscode"), client_type="vscode") as vscode,
            LocalClient(engine, client_id=unique.name("t-desktop"), client_type="desktop") as desktop,
        ):
            await vscode.hello()
            await desktop.hello()
            await engine_node_is(
                engine, engine.node_id, lambda n: n and {"VS Code", "Desktop"} <= set(n["clients"]), what="both listed"
            )

    run(scenario())
