# Desktop tool registry for Subconscious.
# Extends the base cross-platform tool registry with desktop-specific tools
# that require OS APIs (filesystem, terminal, clipboard, images, etc.).

from ..tools import BaseToolRegistry, EngineContext  # noqa: F401 – re-export EngineContext

# ---------------------------------------------------------------------------
# Desktop-extended Registry
# ---------------------------------------------------------------------------

class ToolRegistry(BaseToolRegistry):
  """
  Desktop variant of ToolRegistry.
  Inherits all base (cross-platform) tools and adds:
    - filesystem  – full read/write access via pathlib
    - terminal    – shell command execution
    - clipboard   – OS clipboard via pyperclip / flet
    - web_tools   – web browsing and scraping (httpx + beautifulsoup4)
    - images      – image inspection and processing
    - settings    – app settings read/write via DB
  """

  def __init__(self):
    super().__init__()          # loads base cross-platform tools
    self._load_desktop_tools()

  def _load_desktop_tools(self):
    """Load desktop-specific tool modules."""
    from . import web_tools, filesystem, terminal
    from . import clipboard, images, settings

    modules = {
      "web":        web_tools,
      "filesystem": filesystem,
      "terminal":   terminal,
      "clipboard":  clipboard,
      "images":     images,
      "settings":   settings,
    }

    for slug, module in modules.items():
      self._registry[slug] = getattr(module, "TOOLS", [])


# Module-level singleton for convenience
registry = ToolRegistry()


# Singleton used by the engine
registry = ToolRegistry()
