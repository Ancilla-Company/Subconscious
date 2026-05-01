# Mobile tool registry for Subconscious.
# Extends the base cross-platform tool registry with mobile-safe tools.
#
# Mobile constraints:
#   - No shell/terminal execution (no subprocess on Android/iOS sandboxes)
#   - No pyperclip / desktop clipboard (use Flet's page.set_clipboard instead)
#   - No desktop_notifier (use Flet local notifications or push services)
#   - No heavy C-extension wheels (docx, pypdf, openpyxl) unless wheels are
#     available on pypi.flet.dev for the target architecture
#   - Filesystem access scoped to the app's sandbox data directory
#   - No images processing (Pillow wheels not always available on mobile)
#
# Wheel availability note (as of 2026-05):
#   pydantic-ai, aiosqlite, httpx, sqlalchemy are available on pypi.flet.dev
#   for arm64/arm32.  New wheels should be verified before adding imports.

from ..tools import BaseToolRegistry, EngineContext  # noqa: F401 – re-export EngineContext


class ToolRegistry(BaseToolRegistry):
  """
  Mobile (Android/iOS) variant of ToolRegistry.
  Inherits all base cross-platform tools and adds a sandboxed filesystem.

  Intentionally excludes:
    terminal   – no subprocess shell on mobile
    clipboard  – handled directly by Flet page.set_clipboard / page.get_clipboard
    web_tools  – heavy dependency on beautifulsoup4 (wheel availability varies)
    images     – Pillow wheel not guaranteed on all mobile architectures
    settings   – uses a simplified in-memory + DB approach for mobile
  """

  def __init__(self):
    super().__init__()          # loads base cross-platform tools
    self._load_mobile_tools()

  def _load_mobile_tools(self):
    """Load mobile-safe additional tool modules."""
    from . import filesystem, web_search

    modules = {
      "filesystem": filesystem,   # sandboxed to app data dir
      "web_search": web_search,   # lightweight HTTP-only (no html parsing)
    }

    for slug, module in modules.items():
      self._registry[slug] = getattr(module, "TOOLS", [])


# Module-level singleton for convenience
registry = ToolRegistry()
