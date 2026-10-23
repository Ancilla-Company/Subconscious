"""Scenario 4b (contracts.md section 3): pairing a browser extension with a REAL engine through the REAL server.

server login -> pairing assertion -> engine ``POST /api/v1/pair`` -> paired token works for REST and WebSocket.
"""

import random
import secrets

import httpx
import pytest

from live_clients import LocalClient
from live_support import bearer, run, server_nodes

pytestmark = pytest.mark.live


def new_origin():
    """A fresh extension origin per call: the engine rate-limits pairing per origin (5 per minute)."""
    return "chrome-extension://" + "".join(random.choices("abcdefghijklmnop", k=32))


def new_nonce():
    return secrets.token_urlsafe(24)


def issue_assertion(server, account, engine, nonce, origin):
    return httpx.post(
        f"{server.url}/nodes/{engine.node_id}/pairing-assertion", headers=bearer(account),
        json={"client_nonce": nonce, "origin": origin}, timeout=15,
    )


def pair(engine, assertion, nonce, origin):
    return httpx.post(
        engine.url + "/api/v1/pair", json={"assertion": assertion, "client_nonce": nonce},
        headers={"Origin": origin}, timeout=30,
    )


def paired_token(server, engine):
    nonce, origin = new_nonce(), new_origin()
    assertion = issue_assertion(server, engine.account_info, engine, nonce, origin)
    assert assertion.status_code == 200, assertion.text
    reply = pair(engine, assertion.json()["assertion"], nonce, origin)
    assert reply.status_code == 200, reply.text
    return reply.json()


def test_pairing_flow_yields_a_token_that_works_for_rest_and_websocket(server, engine, unique):
    """Bug class: the pairing handshake between extension, server and engine breaks (assertion not accepted,
    token not honoured by REST or by the WebSocket query-token path), leaving the extension unable to connect."""
    nodes_before = set(server_nodes(server.url, engine.account_info))
    paired = paired_token(server, engine)
    assert paired["token"].startswith("scp_") and paired["client_id"]

    headers = {"Authorization": f"Bearer {paired['token']}"}
    assert httpx.get(engine.url + "/api/v1/workspaces", headers=headers, timeout=15).status_code == 200
    # the paired token never unlocks token management
    assert httpx.get(engine.url + "/api/v1/pair/clients", headers=headers, timeout=15).status_code == 401
    assert httpx.get(engine.url + "/api/v1/workspaces", timeout=15).status_code == 401

    async def over_websocket():
        async with LocalClient(engine, token=paired["token"], client_id=unique.name("paired")) as client:
            ack = await client.hello()
            assert ack["type"] == "client.hello.ack" and ack["data"]["local"] is True

    run(over_websocket())
    # an extension paired over loopback registers no thin node
    assert set(server_nodes(server.url, engine.account_info)) == nodes_before


def test_an_assertion_can_only_be_used_once(server, engine):
    """Bug class: a replayed pairing assertion mints a second token (anyone who sniffs it could pair)."""
    nonce, origin = new_nonce(), new_origin()
    assertion = issue_assertion(server, engine.account_info, engine, nonce, origin).json()["assertion"]
    assert pair(engine, assertion, nonce, origin).status_code == 200
    replay = pair(engine, assertion, nonce, origin)
    assert replay.status_code == 404 and "token" not in replay.text


def test_an_assertion_is_bound_to_its_nonce_and_origin(server, engine):
    """Bug class: an assertion is accepted with a different client nonce or from another extension origin, so a
    stolen assertion could be used by a different extension."""
    nonce, origin = new_nonce(), new_origin()
    assertion = issue_assertion(server, engine.account_info, engine, nonce, origin).json()["assertion"]
    assert pair(engine, assertion, new_nonce(), origin).status_code == 404
    # a wrong guess burns the assertion (the server always consumes it), so even the right nonce now fails
    assert pair(engine, assertion, nonce, origin).status_code == 404

    nonce, origin = new_nonce(), new_origin()
    assertion = issue_assertion(server, engine.account_info, engine, nonce, origin).json()["assertion"]
    assert pair(engine, assertion, nonce, new_origin()).status_code == 404


def test_only_extension_origins_may_pair(server, engine):
    """Bug class: a web page (any non-extension origin) can pair with the local engine."""
    nonce, origin = new_nonce(), new_origin()
    assertion = issue_assertion(server, engine.account_info, engine, nonce, origin).json()["assertion"]
    assert pair(engine, assertion, nonce, "https://evil.example").status_code == 403
    assert httpx.post(engine.url + "/api/v1/pair", json={"assertion": assertion, "client_nonce": nonce},
                      timeout=15).status_code == 403  # no Origin header at all


def test_another_account_cannot_get_an_assertion_for_this_engine(server, engine):
    """Bug class: account isolation hole in pairing: a stranger obtains an assertion for someone else's engine."""
    stranger = server.accounts["B"] if server.attached else server.fresh_account()
    assert stranger["user_id"] != engine.account_info["user_id"]
    reply = issue_assertion(server, stranger, engine, new_nonce(), new_origin())
    assert reply.status_code == 404


def test_a_revoked_paired_client_stops_working(server, engine):
    """Bug class: revoking a paired extension in the engine does not actually cut its access."""
    paired = paired_token(server, engine)
    headers = {"Authorization": f"Bearer {paired['token']}"}
    assert httpx.get(engine.url + "/api/v1/workspaces", headers=headers, timeout=15).status_code == 200
    revoked = httpx.delete(engine.url + f"/api/v1/pair/clients/{paired['client_id']}", headers=engine.headers, timeout=15)
    assert revoked.status_code == 200
    assert httpx.get(engine.url + "/api/v1/workspaces", headers=headers, timeout=15).status_code == 401
