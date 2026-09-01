import asyncio
import json
from unittest.mock import AsyncMock, patch

import pytest

from subconscious_engine.auth import BearerAuthMiddleware, EngineAuthToken


def run(coro):
    return asyncio.run(coro)


def scope(kind="http", path="/api/v1/models", headers=(), query=b""):
    return {
        "type": kind,
        "path": path,
        "headers": list(headers),
        "query_string": query,
        "method": "GET",
    }


async def invoke(middleware, request_scope):
    messages = []

    async def send(message):
        messages.append(message)

    await middleware(request_scope, AsyncMock(), send)
    return messages


def test_token_generation_uses_cryptographically_random_urlsafe_value():
    with patch("subconscious_engine.auth.secrets.token_urlsafe", return_value="generated") as generate:
        assert EngineAuthToken.generate() == EngineAuthToken("generated")
    generate.assert_called_once_with(32)


@pytest.mark.parametrize("path", ["/", "/api/v1/health", "/api/v1/health/details"])
def test_public_paths_bypass_authentication(path):
    app = AsyncMock()
    middleware = BearerAuthMiddleware(app, EngineAuthToken("expected"))
    assert run(invoke(middleware, scope(path=path))) == []
    app.assert_awaited_once()


def test_valid_bearer_header_is_case_insensitive_and_trimmed():
    app = AsyncMock()
    middleware = BearerAuthMiddleware(app, EngineAuthToken("expected"))
    request = scope(headers=[(b"Authorization", b"BEARER   expected  ")])
    assert run(invoke(middleware, request)) == []
    app.assert_awaited_once()


@pytest.mark.parametrize("header", [None, b"Basic expected", b"Bearer wrong", b"Bearer"])
def test_http_missing_or_invalid_credentials_return_json_401(header):
    app = AsyncMock()
    middleware = BearerAuthMiddleware(app, EngineAuthToken("expected"))
    headers = [] if header is None else [(b"authorization", header)]
    messages = run(invoke(middleware, scope(headers=headers)))
    app.assert_not_awaited()
    assert messages[0]["type"] == "http.response.start"
    assert messages[0]["status"] == 401
    assert json.loads(messages[1]["body"]) == {"error": "Missing or invalid bearer token."}


def test_websocket_accepts_query_token_when_header_is_absent():
    app = AsyncMock()
    middleware = BearerAuthMiddleware(app, EngineAuthToken("a b"))
    request = scope("websocket", query=b"token=a+b")
    assert run(invoke(middleware, request)) == []
    app.assert_awaited_once()


def test_websocket_rejects_invalid_token_with_private_unauthorized_code():
    app = AsyncMock()
    middleware = BearerAuthMiddleware(app, EngineAuthToken("expected"))
    messages = run(invoke(middleware, scope("websocket", query=b"token=wrong")))
    app.assert_not_awaited()
    assert messages == [{"type": "websocket.close", "code": 4401}]


def test_invalid_authorization_header_cannot_be_overridden_by_query_token():
    app = AsyncMock()
    middleware = BearerAuthMiddleware(app, EngineAuthToken("expected"))
    request = scope("websocket", headers=[(b"authorization", b"Bearer wrong")],
                    query=b"token=expected")
    assert run(invoke(middleware, request)) == [{"type": "websocket.close", "code": 4401}]
    app.assert_not_awaited()
