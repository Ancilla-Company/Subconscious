"""
Desktop Engine — extends the base Engine with desktop-only features.

Desktop-specific additions:
  - OS desktop notifications via desktop_notifier
  - Auto-update via pip/winget
  - Uses DesktopToolRegistry (full tool set)

The base Engine remains platform-agnostic and can be used by web, server,
and mobile platforms without pulling in desktop-only dependencies.
"""

import logging
import pathlib

from desktop_notifier import DesktopNotifier, Icon

from ..engine import Engine
from ..desktop_tools import ToolRegistry as DesktopToolRegistry

logger = logging.getLogger("subconscious")

_icon_path = pathlib.Path(__file__).parent.parent / "assets" / "icon_sm.png"


class DesktopEngine(Engine):
  """
  Engine variant for the desktop (Windows/macOS/Linux) platform.
  Adds OS-level notifications and auto-update functionality.
  """

  def __init__(self):
    super().__init__()
    self._notifier = DesktopNotifier(
      app_name="Subconscious",
      app_icon=Icon(path=_icon_path),
    )

  async def start_engine(self, config):
    """Start the engine and use the full desktop tool registry."""
    await super().start_engine(config)
    # Replace the base ToolRegistry with the full desktop-capable one
    self.tool_registry = DesktopToolRegistry()

  async def show_notification(self, title: str, message: str) -> None:
    """Send an OS desktop notification via desktop_notifier."""
    try:
      await self._notifier.send(title=title, message=message)
    except Exception as e:
      logger.warning(f"Desktop notification error: {e}")
