"""
Unit tests for subconscious.server_tools.

Tests cover:
  - ServerToolRegistry construction and slug inventory
  - Inherits base cross-platform tools
  - Includes server-appropriate desktop tools (web, filesystem, terminal, images, settings)
  - Excludes clipboard (desktop UI dependency)
"""

from subconscious.tools import BaseToolRegistry
from subconscious.server_tools import ToolRegistry, EngineContext


class TestServerToolRegistry:
  def test_inherits_base_registry(self):
    r = ToolRegistry()
    assert isinstance(r, BaseToolRegistry)

  def test_base_slugs_present(self):
    r = ToolRegistry()
    base_slugs = {"time", "calculator", "weather", "todo", "memory", "notes", "contacts"}
    assert base_slugs.issubset(set(r.all_slugs()))

  def test_server_slugs_present(self):
    r = ToolRegistry()
    server_slugs = {"web", "filesystem", "terminal", "images", "settings"}
    assert server_slugs.issubset(set(r.all_slugs()))

  def test_clipboard_excluded(self):
    """Server registry must NOT include clipboard (requires desktop UI)."""
    r = ToolRegistry()
    assert "clipboard" not in r.all_slugs()

  def test_all_tools_callable(self):
    r = ToolRegistry()
    for tool in r.get_tools(r.all_slugs()):
      assert callable(tool)

  def test_singleton_populated(self):
    from subconscious.server_tools import registry
    assert isinstance(registry, ToolRegistry)
    assert len(registry.all_slugs()) >= 12

  def test_engine_context_importable(self):
    """EngineContext must be re-exported from server_tools."""
    ctx = EngineContext(db=None, workspace_id=1, thread_id=1)
    assert ctx.workspace_id == 1
