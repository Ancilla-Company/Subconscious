import asyncio
import logging

import httpx
import pytest

from subconscious_engine.account import AccountError, AccountServerClient
from subconscious_engine.http_log import format_body, safe_url


def _client(status: int, payload: dict) -> AccountServerClient:
    transport = httpx.MockTransport(lambda request: httpx.Response(status, json=payload))
    base = "http://127.0.0.1:5050/"
    return AccountServerClient(
        base, httpx.AsyncClient(base_url=base, transport=transport)
    )


def test_rejected_login_is_logged_without_secrets(caplog, monkeypatch):
    monkeypatch.delenv("SUBCONSCIOUS_HTTP_LOG", raising=False)
    caplog.set_level(logging.INFO)
    client = _client(401, {"detail": "Invalid email or password"})
    with pytest.raises(AccountError):
        asyncio.run(client.login("a@example.com", "hunter2-secret"))
    text = caplog.text
    assert "status=401" in text
    assert "Invalid email or password" in text
    assert "auth/email/login" in text
    assert "hunter2-secret" not in text
    assert "body=" not in text


def test_verbose_body_is_redacted(caplog, monkeypatch):
    monkeypatch.setenv("SUBCONSCIOUS_HTTP_LOG", "verbose")
    caplog.set_level(logging.INFO)
    client = _client(401, {"detail": "nope"})
    with pytest.raises(AccountError):
        asyncio.run(client.login("a@example.com", "hunter2-secret"))
    assert "body=" in caplog.text
    assert "hunter2-secret" not in caplog.text
    assert "a***@example.com" in caplog.text


def test_helpers_redact():
    assert "tok123" not in format_body({"refresh_token": "tok123", "x": [{"password": "p"}]})
    assert safe_url("http://h/p?code=abc") == "http://h/p"
