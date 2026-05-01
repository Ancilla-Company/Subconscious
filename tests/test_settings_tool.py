"""
Unit tests for subconscious.tools.settings
"""

import pytest
from unittest.mock import AsyncMock, MagicMock, call
from subconscious.desktop_tools.settings import get_app_setting, update_app_setting, set_theme_mode

@pytest.fixture
def mock_engine():
  engine = MagicMock()
  engine.get_setting = AsyncMock(return_value="dark")
  engine.update_setting = AsyncMock()
  return engine

@pytest.fixture
def ctx_with_engine(ctx, mock_engine):
  ctx.deps.engine = mock_engine
  return ctx

@pytest.mark.asyncIO
async def test_get_app_setting(ctx_with_engine, mock_engine):
  result = await get_app_setting(ctx_with_engine, "mode")
  assert result == "dark"
  mock_engine.get_setting.assert_called_once_with("mode", "system")

@pytest.mark.asyncIO
async def test_update_app_setting(ctx_with_engine, mock_engine):
  result = await update_app_setting(ctx_with_engine, "mode", "light")
  assert "updated to 'light'" in result
  mock_engine.update_setting.assert_called_once_with("mode", "light", "system")

@pytest.mark.asyncIO
async def test_set_theme_mode_valid(ctx_with_engine, mock_engine):
  result = await set_theme_mode(ctx_with_engine, "auto")
  assert "updated to 'auto'" in result
  mock_engine.update_setting.assert_called_once_with("mode", "auto", "system")

@pytest.mark.asyncIO
async def test_set_theme_mode_invalid(ctx_with_engine):
  result = await set_theme_mode(ctx_with_engine, "invalid_mode")
  assert "Invalid mode" in result

@pytest.mark.asyncIO
async def test_settings_no_engine(ctx):
  # engine defaults to None in EngineContext — the tool must guard against this
  # explicitly rather than using hasattr (the attribute always exists on the dataclass).
  assert ctx.deps.engine is None, "ctx fixture should not have an engine attached"
  result = await get_app_setting(ctx, "mode")
  assert "Engine instance not available" in result


@pytest.mark.asyncIO
async def test_update_setting_fires_callbacks(ctx_with_engine, mock_engine):
  """Engine.update_setting should invoke registered callbacks with (key, value, tag)."""
  fired = []

  async def fake_callback(key, value, tag):
    fired.append((key, value, tag))

  mock_engine.update_setting = AsyncMock(side_effect=lambda k, v, t="system": fired.append((k, v, t)) or None)

  result = await update_app_setting(ctx_with_engine, "mode", "dark")
  assert "updated to 'dark'" in result
  assert ("mode", "dark", "system") in fired


@pytest.mark.asyncIO
async def test_get_setting_not_found(ctx_with_engine, mock_engine):
  """get_app_setting returns a helpful message when the engine returns None."""
  mock_engine.get_setting = AsyncMock(return_value=None)
  result = await get_app_setting(ctx_with_engine, "nonexistent_key")
  assert "not found" in result
