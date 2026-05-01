"""
Unit tests for subconscious.tools.ToolRegistry
"""

import pytest
from subconscious.desktop_tools import ToolRegistry, EngineContext


# ---------------------------------------------------------------------------
# Default registry construction
# ---------------------------------------------------------------------------

def test_registry_loads_default_slugs():
  registry = ToolRegistry()
  slugs = registry.all_slugs()
  expected = {
    "time", "calculator", "web", "filesystem", "terminal",
    "todo", "memory", "clipboard", "weather", "notes", "contacts",
  }
  assert expected.issubset(set(slugs)), f"Missing slugs: {expected - set(slugs)}"


def test_registry_all_slugs_returns_list():
  registry = ToolRegistry()
  assert isinstance(registry.all_slugs(), list)


def test_registry_get_tools_single_slug():
  registry = ToolRegistry()
  tools = registry.get_tools(["time"])
  assert isinstance(tools, list)
  assert len(tools) >= 3  # get_current_time, get_current_date, convert_timezone, list_common_timezones


def test_registry_get_tools_multiple_slugs():
  registry = ToolRegistry()
  tools = registry.get_tools(["time", "calculator"])
  assert len(tools) >= 6  # 4 time tools + 3 calculator tools (with overlap tolerance)


def test_registry_get_tools_unknown_slug_returns_empty():
  registry = ToolRegistry()
  tools = registry.get_tools(["nonexistent_slug"])
  assert tools == []


def test_registry_get_tools_empty_list():
  registry = ToolRegistry()
  tools = registry.get_tools([])
  assert tools == []


def test_registry_get_tools_returns_callables():
  registry = ToolRegistry()
  tools = registry.get_tools(registry.all_slugs())
  for tool in tools:
    assert callable(tool), f"Expected callable, got {type(tool)}: {tool}"


# ---------------------------------------------------------------------------
# Custom registration
# ---------------------------------------------------------------------------

def test_registry_register_custom_slug():
  registry = ToolRegistry()

  async def my_tool(ctx, x: int) -> int:
    return x * 2

  registry.register("my_custom", [my_tool])
  assert "my_custom" in registry.all_slugs()
  tools = registry.get_tools(["my_custom"])
  assert my_tool in tools


def test_registry_register_overwrites_existing():
  registry = ToolRegistry()

  async def tool_v1(ctx) -> str:
    return "v1"

  async def tool_v2(ctx) -> str:
    return "v2"

  registry.register("overwrite_test", [tool_v1])
  registry.register("overwrite_test", [tool_v2])
  tools = registry.get_tools(["overwrite_test"])
  assert tool_v2 in tools
  assert tool_v1 not in tools


# ---------------------------------------------------------------------------
# EngineContext dataclass
# ---------------------------------------------------------------------------

def test_engine_context_fields():
  ctx = EngineContext(db=None, workspace_id=42, thread_id=7)
  assert ctx.workspace_id == 42
  assert ctx.thread_id == 7
  assert ctx.data_dir == ""  # default


def test_engine_context_with_data_dir():
  ctx = EngineContext(db=None, workspace_id=1, thread_id=1, data_dir="/some/path")
  assert ctx.data_dir == "/some/path"


# ---------------------------------------------------------------------------
# Singleton registry instance
# ---------------------------------------------------------------------------

def test_singleton_registry_is_populated():
  from subconscious.desktop_tools import registry
  assert len(registry.all_slugs()) >= 11
