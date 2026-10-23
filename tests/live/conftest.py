"""Gating and fixtures for the live (end-to-end) tier. See ``README.md`` in this folder.

Gating: live tests are always COLLECTED (they show up in the Testing panel) but are SKIPPED with a clear
reason unless the run explicitly asks for them: env ``SC_LIVE=1``, an invocation argument naming the live
folder or a live test file/node (what the Testing panel passes when you run them), or ``-m live``.
So ``pytest tests`` (the unit run) stays fast and shows them as skipped.

Fixtures (session scoped, started lazily so a run of a single test pays only for what it uses):

* ``server``: its own hermetic ``RunningServer`` (random ports, throw-away data, a pool of seeded accounts),
  or, when env ``SC_LIVE_STACK`` points at a ``stack.json`` written by ``scripts/live_stack.py``, that stack.
* ``engine``: one REAL engine process (``--dev``, socket relay forced) signed in to its own account, or the first
  engine of the attached stack. ``engine.account_info`` is its account.
* ``engine_factory``: starts more real engines, stopped at test end.
* ``account`` / ``stranger``: function scoped fresh accounts (pool accounts; alice/bob when attached).
"""

from __future__ import annotations

import json
import os
import re
import sys
import uuid
import warnings
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

HERE = Path(__file__).resolve().parent
for entry in (str(HERE), str(HERE.parent)):  # live_server & friends, and tests/hive_testkit.py
    if entry not in sys.path:
        sys.path.insert(0, entry)

import live_server  # noqa: E402
from live_engines import EngineProcess, start_engine  # noqa: E402

SKIP_REASON = 'live test: run it from the Testing panel, "Test: Live ..." task, or set SC_LIVE=1'
POOL_SIZE = 40
_LIVE_MARK = re.compile(r"(?<!not )\blive\b")


def live_requested(config: pytest.Config) -> bool:
    """True when this run explicitly asks for the live tier (see the module docstring)."""
    if os.environ.get("SC_LIVE") == "1":
        return True
    if _LIVE_MARK.search(config.getoption("markexpr", default="") or ""):
        return True
    base = Path(config.invocation_params.dir)
    for argument in config.invocation_params.args:
        text = str(argument).split("::", 1)[0]
        if not text or text.startswith("-"):
            continue
        try:
            target = (base / text).resolve()
        except OSError:
            continue
        # a path argument that is the live folder, or something inside it (a file; node ids carry ::name)
        if target.exists() and (target == HERE or HERE in target.parents):
            return True
    return False


def _is_live(path: Any) -> bool:
    return HERE in Path(str(path)).resolve().parents


def pytest_configure(config: pytest.Config) -> None:
    config.addinivalue_line(
        "markers", "live: runs the real subconscious-server and real engines (skipped unless asked for; see tests/live/README.md)"
    )


def pytest_itemcollected(item: pytest.Item) -> None:
    if _is_live(item.path):
        item.add_marker(pytest.mark.live)


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    if live_requested(config):
        return
    skip = pytest.mark.skip(reason=SKIP_REASON)
    for item in items:
        if _is_live(item.path):
            item.add_marker(skip)


# --- fixtures -----------------------------------------------------------------------------------------


class LiveServer:
    """The server under test: hermetic (``RunningServer``) or attached (``stack.json``)."""

    def __init__(self, url: str, accounts: dict[str, dict[str, Any]], *, attached: bool, running: Any = None) -> None:
        self.url = url
        self.ws_url = "ws://" + url.split("://", 1)[1]
        self.accounts = accounts
        self.attached = attached
        self.running = running
        self.root: Path | None = getattr(running, "root", None)
        self._pool = [accounts[label] for label in accounts if label.startswith("P")]
        self._shared = [accounts["A"], accounts["B"]]

    def fresh_account(self) -> dict[str, Any]:
        """An account nobody else uses (a pool account); attached stacks only have alice/bob."""
        return self._pool.pop(0) if self._pool else self._shared[0]

    def fresh_pair(self) -> tuple[dict[str, Any], dict[str, Any]]:
        if len(self._pool) >= 2:
            return self._pool.pop(0), self._pool.pop(0)
        return self._shared[0], self._shared[1]


def _attached_accounts(stack: dict[str, Any]) -> dict[str, dict[str, Any]]:
    result = {}
    for label, name in (("A", "alice"), ("B", "bob")):
        raw = stack["accounts"][name]
        result[label] = {
            "user_id": raw["userId"], "email": raw["email"], "password": raw["password"],
            "access_token": raw["accessToken"], "refresh_token": raw["refreshToken"],
            "refresh_tokens": [raw["refreshToken"]],
        }
    return result


def attached_stack() -> dict[str, Any] | None:
    path = os.environ.get("SC_LIVE_STACK")
    if not path:
        return None
    file = Path(path)
    if not file.is_file():
        # A stale variable (a stack that was stopped) must not break the run: fall back to the hermetic stack.
        warnings.warn(f"SC_LIVE_STACK={path} does not exist; starting a private stack instead", stacklevel=2)
        return None
    return json.loads(file.read_text(encoding="utf-8"))


@pytest.fixture(scope="session")
def server(tmp_path_factory: pytest.TempPathFactory):
    if not live_server.server_available():
        pytest.skip("the subconscious-server venv is not available (../subconscious-server/.venv)")
    stack = attached_stack()
    if stack is not None:
        yield LiveServer(stack["server"]["url"], _attached_accounts(stack), attached=True)
        return
    running = live_server.RunningServer(
        tmp_path_factory.mktemp("live-server"), settings=live_server.LIVE_SETTINGS, pool=POOL_SIZE
    ).start()
    try:
        yield LiveServer(running.url, running.accounts, attached=False, running=running)
    finally:
        running.stop()


@pytest.fixture
def owned_server(server: LiveServer) -> LiveServer:
    """Tests that need the pristine accounts A and B of a server they own."""
    if server.attached:
        pytest.skip("needs its own server (accounts A and B untouched); not run against an attached stack")
    return server


@pytest.fixture(scope="session")
def engine(server: LiveServer, tmp_path_factory: pytest.TempPathFactory):
    """One real engine process, signed in and online; ``engine.account_info`` is its account."""
    stack = attached_stack()
    if stack is not None:
        descriptor = stack["engines"][0]
        accounts = _attached_accounts(stack)
        handle = EngineProcess(name=descriptor["name"], account=descriptor["account"], root=Path(descriptor["dataDir"]))
        handle.url, handle.token, handle.node_id, handle.pid = (
            descriptor["url"], descriptor["token"], descriptor["nodeId"], descriptor["pid"],
        )
        handle.account_info = accounts["A" if descriptor["account"] == "alice" else "B"]  # type: ignore[attr-defined]
        handle.server_url = server.url  # type: ignore[attr-defined]
        yield handle
        return
    account = server.fresh_account()
    handle = start_engine(tmp_path_factory.mktemp("live-engine"), "live-engine", server.url, account, "pool", relay=True)
    handle.account_info = account  # type: ignore[attr-defined]
    handle.server_url = server.url  # type: ignore[attr-defined]
    try:
        yield handle
    finally:
        handle.stop()


@pytest.fixture
def engine_factory(server: LiveServer, tmp_path_factory: pytest.TempPathFactory):
    """``factory(account, name=None, relay=True)`` -> a started, signed-in real engine process."""
    started: list[EngineProcess] = []

    def factory(account: dict[str, Any], name: str | None = None, *, relay: bool = True, sign_in: bool = True) -> EngineProcess:
        label = name or f"engine-{uuid.uuid4().hex[:6]}"
        handle = start_engine(
            tmp_path_factory.mktemp(label), label, server.url, account, "pool", relay=relay, sign_in=sign_in
        )
        handle.account_info = account  # type: ignore[attr-defined]
        handle.server_url = server.url  # type: ignore[attr-defined]
        started.append(handle)
        return handle

    try:
        yield factory
    finally:
        for handle in reversed(started):
            handle.stop()


@pytest.fixture
def account(server: LiveServer) -> dict[str, Any]:
    return server.fresh_account()


@pytest.fixture
def account_pair(server: LiveServer) -> tuple[dict[str, Any], dict[str, Any]]:
    return server.fresh_pair()


@pytest.fixture
def unique() -> SimpleNamespace:
    """Unique-per-test names so tests never depend on each other's nodes."""
    token = uuid.uuid4().hex[:8]
    return SimpleNamespace(token=token, name=lambda prefix: f"{prefix}-{token}")
