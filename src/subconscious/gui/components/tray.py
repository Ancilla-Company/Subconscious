import os
import asyncio
import pathlib
import pystray
import flet as ft
from PIL import Image


class Tray:
  """ Manages the tray icon """
  def __init__(self, page):
    self.page = page
    self.page.window.prevent_close = True # Tray icon persistance
    self.page.window.on_event = self.__on_window_event
    
    # Resolve relative to the current file (src/subconscious/gui/components/tray.py)
    base_dir = pathlib.Path(__file__).parent.parent.parent
    icon_path = base_dir / "assets" / "favicon.ico"

    self.__tray_icon = pystray.Icon(
      name="Subconscious",
      icon=Image.open(str(icon_path)),
      title="Subconscious",
      menu=pystray.Menu(
        pystray.MenuItem("Open Subconscious", self.__default_tray_option, default=True),
        pystray.MenuItem("Exit", self.__tray_exit),
      ),
      visible=True,
    )
    self.__tray_icon.run_detached()

  def __default_tray_option(self, icon, query):
    self.page.window.skip_task_bar = False
    self.page.window.minimized = False
    self.page.window.focused = True
    self.page.update()

  def __tray_exit(self, icon, query):
    self.__tray_icon.stop()
    asyncio.run(self.page.window.destroy())

  async def __on_window_event(self, e):
    if e.type == ft.WindowEventType.CLOSE:
      self.page.window.skip_task_bar = True
      self.page.window.minimized = True
      self.page.update()

  # def __safe_exit(self):
  #   if self.settings.General.tray.value:
  #     self.__tray_icon.stop()
  #   self.page.window.destroy()
