# Default built-in tools for Subconscious.
# Each module registers its callables via TOOLS = [...] at module level.
# The ToolRegistry collects them by slug so the engine can attach the right
# set to any Agent at runtime.

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
  data_dir: str = ""


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

class ToolRegistry:
  """
  Maps tool slugs to lists of pydantic-ai compatible tool callables.

  Usage
  -----
  registry = ToolRegistry()
  tools = registry.get_tools(["time", "calculator", "web"])
  agent = Agent(model=..., tools=tools, deps_type=EngineContext)
  """

  def __init__(self):
    self._registry: dict[str, list[Callable]] = {}
    self._load_defaults()

  def _load_defaults(self):
    """Import every default tool module and register its TOOLS list."""
    from . import time_tools, calculator, web_tools, filesystem, terminal
    from . import todo, memory, clipboard, weather, notes, contacts

    modules = {
      "time":       time_tools,
      "calculator": calculator,
      "web":        web_tools,
      "filesystem": filesystem,
      "terminal":   terminal,
      "todo":       todo,
      "memory":     memory,
      "clipboard":  clipboard,
      "weather":    weather,
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


# Singleton used by the engine
registry = ToolRegistry()
