import sys
import asyncio
import argparse

from ..config import Config
from ..tui import start_tui
from ..engine import start_engine


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
  
  args = parser.parse_args()
  
  config = Config(dev=args.dev, config_path=args.config)
  
  try:
    loop = asyncio.get_event_loop()
    if args.command == "engine":
      loop.run_until_complete(start_engine(config))
    else:
      loop.run_until_complete(start_tui(config))
  except KeyboardInterrupt:
    sys.exit(0)


if __name__ == "__main__":
  main()
