import os
import sys
import asyncio
import logging
import argparse

from ..tui import start_tui
from ..engine import Engine
from ..config import Config, LOGO


def main():
  """ Entry point for the Subconscious CLI"""
  parser = argparse.ArgumentParser(
    prog="subconscious",
    description="Subconscious: A Distributed Agentic Engine"
  )
  
  parser.add_argument(
    "--dev",
    action="store_true",
    help="Run in development mode"
  )
  parser.add_argument(
    "--config",
    type=str,
    help="Path to a specific configuration file"
  )
  
  subparsers = parser.add_subparsers(dest="command")
  
  # Subcommand: engine
  engine_parser = subparsers.add_parser(
    "engine", 
    help="Starts only the engine with no TUI"
  )
  
  print(LOGO)
  args = parser.parse_args()
  config = Config(dev=args.dev, config_path=args.config)
  config.validate()

  # Logging setup
  logging.basicConfig(format='[%(levelname)s|%(asctime)s.%(msecs)04d|%(filename)s|%(lineno)d] %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
  logger = logging.getLogger('subconscious')
  if args.dev:
    logger.setLevel(logging.DEBUG)
  else:
    logger.setLevel(logging.INFO)
  
  try:
    loop = asyncio.get_event_loop()
    if args.command == "engine":
      loop.run_until_complete(Engine().start_engine(config))
    else:
      loop.run_until_complete(start_tui(config))
  except KeyboardInterrupt:
    sys.exit(0)


if __name__ == "__main__":
  main()
