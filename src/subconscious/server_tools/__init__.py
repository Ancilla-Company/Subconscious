# Server/standalone engine tool registry for Subconscious.
# Extends the base cross-platform tool registry with server-safe tools.
#
# The server/standalone engine is essentially the desktop engine minus any
# UI-dependent features.  It runs headless (no Flet page, no system tray)
# and is safe to deploy as a background service or cloud function.
#
# Included over base:
#   filesystem  – full server-side filesystem access
#   terminal    – shell command execution (useful for automation)
#   web_tools   – web browsing and scraping (httpx + beautifulsoup4)
#   images      – image processing (Pillow required on server)
#   settings    – app settings via DB
#
# Excluded vs desktop:
#   clipboard   – no desktop clipboard on a headless server
#   tray / notifications – no desktop UI

from ..tools import BaseToolRegistry, EngineContext  # noqa: F401 – re-export EngineContext


class ToolRegistry(BaseToolRegistry):
  """
  Server/standalone engine variant of ToolRegistry.
  Inherits all base cross-platform tools and adds server-appropriate tools.
  """

  def __init__(self):
    super().__init__()          # loads base cross-platform tools
    self._load_server_tools()

  def _load_server_tools(self):
    """Load server-appropriate additional tool modules (from desktop_tools)."""
    from ..desktop_tools import web_tools, filesystem, terminal, images, settings

    modules = {
      "web":        web_tools,
      "filesystem": filesystem,
      "terminal":   terminal,
      "images":     images,
      "settings":   settings,
    }

    for slug, module in modules.items():
      self._registry[slug] = getattr(module, "TOOLS", [])


# Module-level singleton for convenience
registry = ToolRegistry()
