"""
Unit tests for the Engine / DesktopEngine split.

Tests cover:
  - Base Engine.show_notification is a no-op (logs, doesn't raise)
  - DesktopEngine.show_notification calls desktop_notifier (mocked)
  - DesktopEngine.start_engine swaps in the DesktopToolRegistry
  - Base Engine uses the base ToolRegistry by default after start
  - show_notification override is the only behavioural difference tested
    (full engine lifecycle requires a real DB and config — out of scope here)
"""

import pytest
import logging
from unittest.mock import AsyncMock, MagicMock, patch


# ---------------------------------------------------------------------------
# Base Engine.show_notification
# ---------------------------------------------------------------------------

class TestBaseEngineShowNotification:
  @pytest.mark.asyncio
  async def test_show_notification_does_not_raise(self, caplog):
    """Base engine show_notification is a silent no-op that logs at INFO."""
    # Import Engine lazily to avoid triggering heavy optional deps at collection time
    from subconscious.engine import Engine

    engine = Engine.__new__(Engine)  # bypass __init__ (avoids DB setup)
    engine.tool_registry = None

    with caplog.at_level(logging.INFO, logger="subconscious"):
      await engine.show_notification("Test Title", "Test message")

    # Should have logged the notification
    assert any("Test Title" in r.message or "Test message" in r.message for r in caplog.records)

  @pytest.mark.asyncio
  async def test_show_notification_is_overrideable(self):
    """Subclasses can override show_notification without calling super."""
    from subconscious.engine import Engine

    called_with = []

    class MyEngine(Engine):
      async def show_notification(self, title: str, message: str) -> None:
        called_with.append((title, message))

    engine = MyEngine.__new__(MyEngine)
    await engine.show_notification("Hello", "World")
    assert called_with == [("Hello", "World")]


# ---------------------------------------------------------------------------
# DesktopEngine.show_notification (mocked desktop_notifier)
# ---------------------------------------------------------------------------

class TestDesktopEngineShowNotification:
  @pytest.mark.asyncio
  async def test_show_notification_calls_notifier(self):
    """DesktopEngine.show_notification must delegate to DesktopNotifier.send."""
    mock_notifier = AsyncMock()
    mock_icon = MagicMock()

    with patch("subconscious.desktop.engine.DesktopNotifier", return_value=mock_notifier), \
         patch("subconscious.desktop.engine.Icon", return_value=mock_icon):
      from importlib import import_module, reload
      import subconscious.desktop.engine as de_mod
      reload(de_mod)  # ensure patched DesktopNotifier is used

      engine = de_mod.DesktopEngine.__new__(de_mod.DesktopEngine)
      engine._notifier = mock_notifier

      await engine.show_notification("Title", "Body")

    mock_notifier.send.assert_awaited_once_with(title="Title", message="Body")

  @pytest.mark.asyncio
  async def test_show_notification_swallows_notifier_error(self, caplog):
    """If desktop_notifier.send raises, DesktopEngine logs a warning and continues."""
    from subconscious.desktop.engine import DesktopEngine

    engine = DesktopEngine.__new__(DesktopEngine)
    mock_notifier = AsyncMock()
    mock_notifier.send = AsyncMock(side_effect=RuntimeError("OS notification service unavailable"))
    engine._notifier = mock_notifier

    with caplog.at_level(logging.WARNING, logger="subconscious"):
      # Should not raise
      await engine.show_notification("Oops", "error test")

    assert any("notification" in r.message.lower() or "OS notification" in r.message
               for r in caplog.records)


# ---------------------------------------------------------------------------
# DesktopEngine.start_engine — tool registry replacement
# ---------------------------------------------------------------------------

class TestDesktopEngineStartEngine:
  @pytest.mark.asyncio
  async def test_start_engine_sets_desktop_tool_registry(self):
    """After start_engine, tool_registry must be a DesktopToolRegistry instance."""
    from subconscious.desktop.engine import DesktopEngine
    from subconscious.desktop_tools import ToolRegistry as DesktopToolRegistry

    engine = DesktopEngine.__new__(DesktopEngine)
    engine._notifier = AsyncMock()

    # Mock super().start_engine so we don't need a real DB/config
    with patch("subconscious.engine.Engine.start_engine", new_callable=AsyncMock) as mock_super:
      mock_cfg = MagicMock()
      await engine.start_engine(mock_cfg)

    mock_super.assert_awaited_once_with(mock_cfg)
    assert isinstance(engine.tool_registry, DesktopToolRegistry)


# ---------------------------------------------------------------------------
# Engine base class doesn't import desktop_notifier at module level
# ---------------------------------------------------------------------------

class TestEngineImportIsolation:
  def test_base_engine_importable_without_desktop_notifier(self):
    """Importing subconscious.engine must NOT require desktop_notifier."""
    import importlib
    import sys

    # Temporarily hide desktop_notifier from the import system
    original = sys.modules.get("desktop_notifier")
    sys.modules["desktop_notifier"] = None  # type: ignore

    try:
      # Force reimport to check for import-time desktop_notifier usage
      if "subconscious.engine" in sys.modules:
        del sys.modules["subconscious.engine"]
      importlib.import_module("subconscious.engine")
    except ImportError as exc:
      if "desktop_notifier" in str(exc):
        pytest.fail("subconscious.engine imports desktop_notifier at module level")
    finally:
      if original is None:
        sys.modules.pop("desktop_notifier", None)
      else:
        sys.modules["desktop_notifier"] = original
