import asyncio
from .config import Config, print_config


async def start_tui(config: Config):
  """ TUI startup logic with Textual will go here """
  print_config(config, "Engine + TUI")
  print("TUI started. Press Ctrl+C to stop.")
  try:
    while True:
      await asyncio.sleep(3600)
  except asyncio.CancelledError:
    print("TUI stopping...")
