"""
Unit / example tests for `Engine._init_system_info` (spec:
system-information-context, task 8.2).

Covers:
  - Happy path: the service is created with the config's data_dir and its
    one-time load-or-collect (`ensure_profile`) is invoked; the instance is
    stored on `engine.system_info` for later ambient-context resolution
    (Reqs 3.1, 4.1, 4.2, 4.3).
  - Resilience (Req 8.3): when service construction or `ensure_profile` raises,
    `_init_system_info` swallows the error, logs it, leaves
    `engine.system_info` as None, and never propagates — so startup continues.

These build the Engine via __new__ to avoid standing up the full startup
pipeline, mirroring the approach in test_engine_share_system_context.py.
"""

import types

import pytest

from subconscious.engine import Engine
import subconscious.engine as engine_mod


def _make_engine(tmp_path) -> Engine:
  """Construct an Engine with just enough state for _init_system_info."""
  engine = Engine.__new__(Engine)
  # _init_system_info reads self.config.data_dir; a lightweight stand-in avoids
  # constructing a full Config.
  engine.config = types.SimpleNamespace(data_dir=tmp_path)
  return engine


class TestInitSystemInfoHappyPath:
  async def test_creates_service_with_data_dir_and_ensures_profile(
    self, tmp_path, monkeypatch
  ):
    """The service is built with the config data_dir and ensure_profile runs."""
    calls = {"data_dir": None, "ensured": 0}

    class FakeService:
      def __init__(self, data_dir):
        calls["data_dir"] = data_dir

      def ensure_profile(self):
        calls["ensured"] += 1

    monkeypatch.setattr(engine_mod, "SystemInformationService", FakeService)

    engine = _make_engine(tmp_path)
    await engine._init_system_info()

    assert isinstance(engine.system_info, FakeService)
    assert calls["data_dir"] == str(tmp_path)
    assert calls["ensured"] == 1


class TestInitSystemInfoResilience:
  async def test_startup_continues_when_construction_raises(
    self, tmp_path, monkeypatch
  ):
    """A failure constructing the service is swallowed; system_info is None."""

    def _boom(*args, **kwargs):
      raise RuntimeError("construction blew up")

    monkeypatch.setattr(engine_mod, "SystemInformationService", _boom)

    engine = _make_engine(tmp_path)

    # Must not raise (Req 8.3): startup would otherwise abort.
    await engine._init_system_info()

    assert engine.system_info is None

  async def test_startup_continues_when_ensure_profile_raises(
    self, tmp_path, monkeypatch
  ):
    """A failure inside ensure_profile is swallowed; system_info is None."""

    class FakeService:
      def __init__(self, data_dir):
        pass

      def ensure_profile(self):
        raise RuntimeError("collection blew up")

    monkeypatch.setattr(engine_mod, "SystemInformationService", FakeService)

    engine = _make_engine(tmp_path)

    # Must not raise (Req 8.3).
    await engine._init_system_info()

    assert engine.system_info is None

  async def test_failure_is_logged(self, tmp_path, monkeypatch, caplog):
    """The guarded failure is logged at error level so it is not silent."""

    def _boom(*args, **kwargs):
      raise RuntimeError("kaboom")

    monkeypatch.setattr(engine_mod, "SystemInformationService", _boom)

    engine = _make_engine(tmp_path)
    with caplog.at_level("ERROR", logger="subconscious"):
      await engine._init_system_info()

    assert any("System information initialization failed" in r.message
               for r in caplog.records)
