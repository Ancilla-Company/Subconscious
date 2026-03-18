import os
import asyncio
import pathlib
import pystray
import flet as ft
from PIL import Image


class Tray:
  """ Manages the tray icon """
  def __init__(self, engine, close):
    """ Sets up the tray icon to allow running in the backround without stopping the engine """
    self.main = None
    self.loop = None
    self.assets = None
    self.close = close
    self.engine = engine
    self._exiting = False
    self._reopen_event = None

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
  
  async def start_gui(self, main, assets):
    """ Starts the GUI and re-opens it whenever the tray icon is clicked. """
    if main and assets:
      self.main = main
      self.assets = assets
    self.loop = asyncio.get_running_loop()
    self._reopen_event = asyncio.Event()

    # Run once on startup, then wait for reopen requests from the tray thread.
    while True:
      await ft.run_async(self.main, assets_dir=self.assets)
      await self._reopen_event.wait()
      self._reopen_event.clear()
      if self._exiting:
        break
  
  def set_gui(self, gui):
    """ Stores the flet page object """
    self.gui = gui
  
  def __default_tray_option(self, icon, query):
    """ Defaults to reopening the program """
    if self.loop and self._reopen_event:
      self.loop.call_soon_threadsafe(self._reopen_event.set)

  def __tray_exit(self, icon, query):
    """ Completely exit the program """
    self._exiting = True
    self.__tray_icon.stop()
    if self.loop and self._reopen_event:
      # Unblock the wait loop so it can exit cleanly
      if self.gui.window.visible:
        asyncio.run_coroutine_threadsafe(self.gui.window.close(), self.loop)
      self.loop.call_soon_threadsafe(self.close.set)
      self.loop.call_soon_threadsafe(self._reopen_event.set)
    if self.gui:
      asyncio.run_coroutine_threadsafe(self.gui.window.destroy(), self.loop)
