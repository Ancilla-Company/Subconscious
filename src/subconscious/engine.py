import asyncio
import logging
from .config import Config, log_config

logger = logging.getLogger(__name__)


async def start_engine(config: Config):
  """ Engine startup logic with Ray/NATS will go here """
  log_config(config, "Engine Only")
  logger.info("Engine started. Press Ctrl+C to stop.")

  try:
    while True:
      await asyncio.sleep(3600)
  except asyncio.CancelledError:
    logger.info("Engine stopping...")
