import asyncio
from .config import Config, print_config


async def start_engine(config: Config):
  """ Engine startup logic with Ray/NATS will go here """
  print_config(config, "Engine Only")
  print("Engine started. Press Ctrl+C to stop.")

  try:
    while True:
      await asyncio.sleep(3600)
  except asyncio.CancelledError:
    print("Engine stopping...")
