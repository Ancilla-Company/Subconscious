import os
import sys
import asyncio
import logging
import argparse

from ..tui import start_tui
from ..gui import start_gui
from ..engine import Engine
from ..config import Config, LOGO


def main():
  """ Entry point for the Subconscious CLI"""
  # Common arguments for parent parser to be used by subparsers
  base_parser = argparse.ArgumentParser(add_help=False)
  base_parser.add_argument(
    "--dev",
    action="store_true",
    help="Run in development mode"
  )

  parser = argparse.ArgumentParser(
    prog="subconscious",
    description="Subconscious: A Distributed Agentic Engine",
    parents=[base_parser]
  )
  
  subparsers = parser.add_subparsers(dest="command")
  
  # Subcommand: engine
  engine_parser = subparsers.add_parser(
    "engine", 
    help="Starts only the engine with no TUI",
    parents=[base_parser]
  )

  # Subcommand: gui
  gui_parser = subparsers.add_parser(
    "gui",
    help="Starts the engine with the GUI interface",
    parents=[base_parser]
  )

  # Subcommand: tui
  tui_parser = subparsers.add_parser(
    "tui",
    help="Starts the engine with the TUI interface (default)",
    parents=[base_parser]
  )
  
  # Initiate Config here to allow for accepting config arguments in the future
  args = parser.parse_args()

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
      print(LOGO)
      loop.run_until_complete(Engine().start_engine(
        Config(dev=args.dev, gui=False, tui=False)
      ))
    elif args.command == "gui":
      loop.run_until_complete(start_gui(
        Config(dev=args.dev, gui=True, tui=False)
      ))
    elif args.command == "tui" or args.command is None:
      print(LOGO)
      loop.run_until_complete(start_tui(
        Config(dev=args.dev, gui=False, tui=True)
      ))
    else:
      print(LOGO)
      parser.print_help()
  except KeyboardInterrupt:
    sys.exit(0)


if __name__ == "__main__":
  main()
