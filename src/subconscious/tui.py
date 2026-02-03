import asyncio
import logging
from .config import Config, log_config

logger = logging.getLogger(__name__)


async def start_tui(config: Config):
  """ TUI startup logic with Textual will go here """
  log_config(config, "Engine + TUI")
  logger.info("TUI started. Press Ctrl+C to stop.")
  try:
    while True:
      await asyncio.sleep(3600)
  except asyncio.CancelledError:
    logger.info("TUI stopping...")
