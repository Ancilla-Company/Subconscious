# Base cross-platform tool registry for Subconscious.
# Contains tools that work on all platforms (desktop, web, mobile, server).
# Platform-specific registries (desktop_tools, mobile_tools, server_tools)
# extend this by importing and adding their additional tools.

from typing import Callable, Any
from dataclasses import dataclass


@dataclass
class EngineContext:
  """
  Dependency object injected into every tool via pydantic-ai RunContext.
  Gives tools access to the DB session factory, current workspace/thread
  identifiers, and the data directory path (for filesystem scoping).
  """
  db: Any                  # Database instance (db.session.Database)
  workspace_id: int
  thread_id: int
  engine: Any = None       # Subconscious Engine instance
  data_dir: str = ""


# ---------------------------------------------------------------------------
# Base Registry
# ---------------------------------------------------------------------------

class BaseToolRegistry:
  """
  Maps tool slugs to lists of pydantic-ai compatible tool callables.
  Contains only cross-platform tools safe to use on all platforms.

  Platform-specific registries subclass this and call super().__init__()
  then add their own tools.

  Usage
  -----
  registry = BaseToolRegistry()
  tools = registry.get_tools(["time", "calculator"])
  agent = Agent(model=..., tools=tools, deps_type=EngineContext)
  """

  def __init__(self):
    self._registry: dict[str, list[Callable]] = {}
    self._load_base_tools()

  def _load_base_tools(self):
    """Load tools that are safe on every platform (no OS/desktop APIs)."""
    from . import time_tools, calculator, weather
    from . import todo, memory, notes, contacts

    modules = {
      "time":       time_tools,
      "calculator": calculator,
      "weather":    weather,
      "todo":       todo,
      "memory":     memory,
      "notes":      notes,
      "contacts":   contacts,
    }

    for slug, module in modules.items():
      self._registry[slug] = getattr(module, "TOOLS", [])

  def register(self, slug: str, tools: list[Callable]) -> None:
    """Register an external or user-defined tool set under a slug."""
    self._registry[slug] = tools

  def get_tools(self, slugs: list[str]) -> list[Callable]:
    """Return the flat list of callables for the requested slugs."""
    result = []
    for slug in slugs:
      result.extend(self._registry.get(slug, []))
    return result

  def all_slugs(self) -> list[str]:
    return list(self._registry.keys())


# Convenience alias — the base registry is also usable as ToolRegistry
ToolRegistry = BaseToolRegistry

# Module-level singleton for convenience
registry = BaseToolRegistry()
