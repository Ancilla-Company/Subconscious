"""
Unit tests for the desktop ToolRegistry (subconscious.desktop_tools).

Verifies:
  - DesktopToolRegistry is a superset of BaseToolRegistry
  - All expected desktop slugs are present
  - Includes clipboard slug (desktop-only)
  - Registry API works correctly
  - Module-level singleton
  - EngineContext re-export
"""

from subconscious.tools import BaseToolRegistry
from subconscious.desktop_tools import ToolRegistry, EngineContext, registry


class TestDesktopToolRegistry:
  def test_inherits_base_registry(self):
    r = ToolRegistry()
    assert isinstance(r, BaseToolRegistry)

  def test_base_slugs_present(self):
    r = ToolRegistry()
    base_slugs = {"time", "calculator", "weather", "todo", "memory", "notes", "contacts"}
    assert base_slugs.issubset(set(r.all_slugs()))

  def test_desktop_slugs_present(self):
    r = ToolRegistry()
    desktop_slugs = {"web", "filesystem", "terminal", "clipboard", "images", "settings"}
    assert desktop_slugs.issubset(set(r.all_slugs()))

  def test_clipboard_included(self):
    """Desktop registry MUST include clipboard — distinguishes it from server."""
    r = ToolRegistry()
    assert "clipboard" in r.all_slugs()

  def test_all_tools_callable(self):
    r = ToolRegistry()
    for tool in r.get_tools(r.all_slugs()):
      assert callable(tool)

  def test_get_tools_unknown_slug(self):
    r = ToolRegistry()
    assert r.get_tools(["ghost"]) == []

  def test_register_custom_tool(self):
    r = ToolRegistry()

    async def custom(ctx) -> str:
      return "custom"

    r.register("custom_dt", [custom])
    assert custom in r.get_tools(["custom_dt"])

  def test_singleton_is_populated(self):
    assert len(registry.all_slugs()) >= 13

  def test_engine_context_re_exported(self):
    ctx = EngineContext(db=None, workspace_id=10, thread_id=2)
    assert ctx.workspace_id == 10
    assert ctx.thread_id == 2
    assert ctx.data_dir == ""
