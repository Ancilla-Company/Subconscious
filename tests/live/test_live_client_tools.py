"""Scenario 6 (contracts.md section 3): client tools (browser extension / VS Code) registered over a live link."""

import asyncio

import httpx
import pytest

from hive_testkit import until
from live_clients import ThinClient
from live_support import LiveEngine, run

pytestmark = pytest.mark.live

SCHEMA = {"type": "object", "properties": {"tab_id": {"type": "integer"}}, "required": []}


def group_payload(group, *tool_ids, title="Browser"):
    return {
        "group": group, "title": title,
        "tools": [{"id": tool, "description": f"Run {tool}.", "input_schema": SCHEMA} for tool in tool_ids],
    }


def catalog(engine):
    response = httpx.get(engine.url + "/api/v1/tools/catalog", headers=engine.headers, timeout=15)
    assert response.status_code == 200, response.text
    return response.json()["builtin"]


def test_registered_client_groups_appear_in_the_engine_tool_catalog(server, engine, unique):
    """Bug class: a browser/VS Code client registers tools over its (relay) link but the engine never lists them
    in /tools/catalog, so the settings UI cannot toggle them and the model never sees them; also two clients
    registering different groups must not overwrite each other."""
    group_a, group_b = f"ext{unique.token}", f"code{unique.token}"

    async def scenario():
        extension = ThinClient(server.url, engine.account_info, name=unique.name("tools-ext"), platform="browser")
        editor = ThinClient(server.url, engine.account_info, name=unique.name("tools-vscode"), platform="windows")
        try:
            await extension.start()
            await editor.start()
            await extension.open_link(engine.node_id)
            await editor.open_link(engine.node_id)
            await extension.hello(engine.node_id)
            await editor.hello(engine.node_id)
            await extension.say(engine.node_id, "tool.register", group_payload(group_a, "read_page", "click"))
            await editor.say(engine.node_id, "tool.register", group_payload(group_b, "open_file", title="VS Code"))
            await until(lambda: group_a in catalog(engine) and group_b in catalog(engine), 20, step=0.2)
            listed = catalog(engine)
            assert {tool["name"] for tool in listed[group_a]} == {"read_page", "click"}
            assert {tool["name"] for tool in listed[group_b]} == {"open_file"}
            assert not extension.of_type("error") and not editor.of_type("error")
            # an invalid registration is refused with an error to the right client only
            await extension.say(engine.node_id, "tool.register", group_payload("Bad Group!", "x"))
            await extension.wait_for("error", timeout=15)
            assert not editor.of_type("error")
        finally:
            await extension.stop()
            await editor.stop()

    run(scenario())
    # after both clients are gone the groups are remembered (the settings can still toggle them)
    assert group_a in catalog(engine) and group_b in catalog(engine)


def test_a_client_tool_request_goes_to_the_right_client_and_is_answered(owned_server, tmp_path, unique, monkeypatch):
    """Bug class: the engine's client.tool.request is delivered to the wrong connected client (or to none) when two
    clients are attached, or the answer cannot be matched to the pending request. No model is involved: the
    dev Echo model cannot call tools, so the engine session's request hook is invoked directly while the
    frames cross the REAL server relay to the REAL thin clients."""
    from subconscious_engine.hive import service as service_module

    monkeypatch.setattr(service_module, "DIRECTORY_POLL_SECONDS", 0.3)
    monkeypatch.setattr(service_module, "REFRESH_DEBOUNCE_SECONDS", 0.2)
    server = owned_server
    account = server.fresh_account()
    group_a, group_b = f"ext{unique.token}", f"code{unique.token}"

    async def scenario():
        host = LiveEngine(tmp_path, "tools-host", server.url, account["refresh_tokens"][1], force_relay=True)
        right = ThinClient(server.url, account, name=unique.name("right"), platform="browser")
        wrong = ThinClient(server.url, account, name=unique.name("wrong"), platform="browser")
        try:
            await host.start()
            await until(lambda: host.service.state == "running", 40)
            await host.service.signaling.wait_connected(20)
            for client in (right, wrong):
                await client.start()
                await client.open_link(host.node_id)
                await client.hello(host.node_id)
            await right.say(host.node_id, "tool.register", group_payload(group_a, "read_page"))
            await wrong.say(host.node_id, "tool.register", group_payload(group_b, "open_file"))
            runtimes = host.service.node.runtimes
            await until(lambda: runtimes[right.node_id].session.session.client_tool_groups
                        and runtimes[wrong.node_id].session.session.client_tool_groups, 20, step=0.1)
            session = runtimes[right.node_id].session.session

            pending = asyncio.create_task(
                session._request_client_tool("turn-tools", "read_page", {"tab_id": 7}, group=group_a, timeout=20)
            )
            request = await right.wait_for("client.tool.request", "turn-tools", timeout=20)
            assert request.data["tool_name"] == "read_page" and request.data["group"] == group_a
            assert request.data["arguments"] == {"tab_id": 7}
            await right.say(
                host.node_id, "client.tool.result",
                {"request_id": request.data["request_id"], "ok": True, "result": {"title": "Hello page"}}, "turn-tools",
            )
            assert await asyncio.wait_for(pending, 20) == {"title": "Hello page"}
            assert not wrong.of_type("client.tool.request")  # the other client never saw it

            # a failed tool is reported to the caller, not swallowed
            failing = asyncio.create_task(
                session._request_client_tool("turn-fail", "read_page", {}, group=group_a, timeout=20)
            )
            request = await right.wait_for("client.tool.request", "turn-fail", timeout=20)
            await right.say(
                host.node_id, "client.tool.result",
                {"request_id": request.data["request_id"], "ok": False, "error": "tab is gone"}, "turn-fail",
            )
            with pytest.raises(RuntimeError, match="tab is gone"):
                await asyncio.wait_for(failing, 20)
        finally:
            await right.stop()
            await wrong.stop()
            await host.stop()

    run(scenario())
