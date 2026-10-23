"""Scenario 1 (contracts.md section 3): node identity, platform/name registration, transient vs durable nodes."""

import pytest

from live_clients import ThinClient
from live_support import engine_nodes, run, server_nodes

pytestmark = pytest.mark.live

TRANSIENT = ["web", "browser"]
DURABLE = ["android", "windows", "ios"]


@pytest.mark.parametrize("platform", TRANSIENT + DURABLE)
def test_thin_node_is_listed_with_the_exact_platform_and_name_it_sent(server, account, unique, platform):
    """Bug class: a thin client's platform/name is rewritten, dropped or defaulted on the way to the device
    list (e.g. the extension showing up as 'web' or under the OS name), so the UI labels it wrongly."""
    name = unique.name(f"thin-{platform}")

    async def scenario():
        thin = ThinClient(server.url, account, name=name, platform=platform)
        try:
            await thin.start()
            listed = server_nodes(server.url, account)[thin.node_id]
            assert (listed["kind"], listed["platform"], listed["name"]) == ("thin", platform, name)
            assert listed["status"] == "active"
            assert listed["public_key"] == thin.identity.public_key_b64u
        finally:
            await thin.stop()
            await thin.api.close()

    run(scenario())


def test_browser_and_web_are_both_transient_but_distinct(server, account, unique):
    """Bug class: the browser extension ('browser') and the web page ('web') get confused or only one of them
    is treated as transient; both must register under their own platform and be listed as such."""

    async def scenario():
        extension = ThinClient(server.url, account, name=unique.name("ext"), platform="browser")
        page = ThinClient(server.url, account, name=unique.name("page"), platform="web")
        try:
            await extension.start()
            await page.start()
            listing = server_nodes(server.url, account)
            assert listing[extension.node_id]["platform"] == "browser"
            assert listing[page.node_id]["platform"] == "web"
            assert listing[extension.node_id]["id"] != listing[page.node_id]["id"]
        finally:
            for client in (extension, page):
                await client.stop()
                await client.api.close()

    run(scenario())


@pytest.mark.parametrize("platform", TRANSIENT)
def test_delete_removes_a_transient_node(server, account, unique, platform):
    """Bug class: removing a browser/web device leaves a 'revoked' ghost row in the device list instead of
    deleting it (a returning browser then shows twice)."""

    async def scenario():
        thin = ThinClient(server.url, account, name=unique.name("gone"), platform=platform)
        try:
            await thin.start()
            assert thin.node_id in server_nodes(server.url, account)
            await thin.delete_node()
            assert thin.node_id not in server_nodes(server.url, account)
        finally:
            await thin.stop()
            await thin.api.close()

    run(scenario())


@pytest.mark.parametrize("platform", DURABLE)
def test_delete_only_revokes_a_durable_node(server, account, unique, platform):
    """Bug class: removing a phone/desktop deletes its row (losing the revocation record) or leaves it active;
    a durable node must stay listed as revoked so it can never silently come back."""

    async def scenario():
        thin = ThinClient(server.url, account, name=unique.name("durable"), platform=platform)
        try:
            await thin.start()
            await thin.delete_node()
            node = server_nodes(server.url, account)[thin.node_id]
            assert node["status"] == "revoked" and node["platform"] == platform
        finally:
            await thin.stop()
            await thin.api.close()

    run(scenario())


def test_the_real_engine_registers_as_a_durable_engine_with_its_configured_name(server, engine):
    """Bug class: the engine enrols under the machine name instead of the configured one, with the wrong kind,
    or as a transient platform (which would let the server purge it)."""
    listed = server_nodes(server.url, engine.account_info)[engine.node_id]
    assert listed["kind"] == "engine" and listed["name"] == engine.name
    assert listed["platform"] not in {"web", "browser"} and listed["status"] == "active"
    local = engine_nodes(engine)[engine.node_id]
    assert local["local"] is True and local["name"] == engine.name and local["kind"] == "engine"
