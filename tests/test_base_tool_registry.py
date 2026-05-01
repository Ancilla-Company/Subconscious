"""
Unit tests for subconscious.tools (BaseToolRegistry / base cross-platform registry).

These tests verify:
  - BaseToolRegistry loads all expected base slugs
  - ToolRegistry alias works
  - EngineContext dataclass
  - Registry API (get_tools, register, all_slugs)
  - Module-level singleton
"""

import pytest
from subconscious.tools import BaseToolRegistry, ToolRegistry, EngineContext, registry


# ---------------------------------------------------------------------------
# BaseToolRegistry construction
# ---------------------------------------------------------------------------

def test_base_registry_loads_expected_slugs():
  r = BaseToolRegistry()
  slugs = set(r.all_slugs())
  expected = {"time", "calculator", "weather", "todo", "memory", "notes", "contacts"}
  assert expected.issubset(slugs), f"Missing base slugs: {expected - slugs}"


def test_base_registry_does_not_load_desktop_slugs():
  """Base registry must NOT contain desktop-only tools."""
  r = BaseToolRegistry()
  slugs = set(r.all_slugs())
  desktop_only = {"web", "filesystem", "terminal", "clipboard", "images", "settings"}
  overlap = desktop_only & slugs
  assert not overlap, f"Base registry should not contain desktop tools: {overlap}"


def test_tool_registry_alias_is_base_registry():
  """ToolRegistry must be an alias for BaseToolRegistry."""
  assert ToolRegistry is BaseToolRegistry


def test_tool_registry_alias_instantiates():
  r = ToolRegistry()
  assert isinstance(r, BaseToolRegistry)


# ---------------------------------------------------------------------------
# Registry API
# ---------------------------------------------------------------------------

def test_all_slugs_returns_list():
  r = BaseToolRegistry()
  assert isinstance(r.all_slugs(), list)


def test_get_tools_single_slug():
  r = BaseToolRegistry()
  tools = r.get_tools(["time"])
  assert isinstance(tools, list)
  assert len(tools) >= 3


def test_get_tools_multiple_slugs():
  r = BaseToolRegistry()
  tools = r.get_tools(["time", "calculator"])
  assert len(tools) >= 6


def test_get_tools_unknown_slug_returns_empty():
  r = BaseToolRegistry()
  assert r.get_tools(["nonexistent"]) == []


def test_get_tools_empty_list():
  r = BaseToolRegistry()
  assert r.get_tools([]) == []


def test_get_tools_returns_callables():
  r = BaseToolRegistry()
  for tool in r.get_tools(r.all_slugs()):
    assert callable(tool)


def test_register_custom_slug():
  r = BaseToolRegistry()

  async def my_tool(ctx) -> str:
    return "ok"

  r.register("custom_x", [my_tool])
  assert "custom_x" in r.all_slugs()
  assert my_tool in r.get_tools(["custom_x"])


def test_register_overwrites_slug():
  r = BaseToolRegistry()

  async def v1(ctx) -> str:
    return "v1"

  async def v2(ctx) -> str:
    return "v2"

  r.register("overwrite_slug", [v1])
  r.register("overwrite_slug", [v2])
  tools = r.get_tools(["overwrite_slug"])
  assert v2 in tools
  assert v1 not in tools


# ---------------------------------------------------------------------------
# EngineContext dataclass (defined in tools.__init__)
# ---------------------------------------------------------------------------

def test_engine_context_required_fields():
  ctx = EngineContext(db=None, workspace_id=5, thread_id=3)
  assert ctx.workspace_id == 5
  assert ctx.thread_id == 3


def test_engine_context_defaults():
  ctx = EngineContext(db=None, workspace_id=1, thread_id=1)
  assert ctx.data_dir == ""
  assert ctx.engine is None


def test_engine_context_with_data_dir():
  ctx = EngineContext(db=None, workspace_id=1, thread_id=1, data_dir="/tmp/subconscious")
  assert ctx.data_dir == "/tmp/subconscious"


# ---------------------------------------------------------------------------
# Module-level singleton
# ---------------------------------------------------------------------------

def test_singleton_is_base_registry():
  assert isinstance(registry, BaseToolRegistry)


def test_singleton_is_populated():
  assert len(registry.all_slugs()) >= 7
