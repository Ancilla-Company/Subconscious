import os
import sys
import asyncio
import logging
import argparse
import traceback

from ..web import start_web
from ..engine import Engine
from ..desktop import start_gui
# from ..tui.tui import start_tui
from ..config import Config, LOGO


def main():
  """ Entry point for the Subconscious """
  # Show dev options only if dev flag is provided
  print(LOGO)
  dev_present = "--dev" in sys.argv

  base_parser = argparse.ArgumentParser(add_help=False)
  base_parser.add_argument(
    "--dev",
    action="store_true",
    help=("Run in development mode" if dev_present else argparse.SUPPRESS)
  )
  base_parser.add_argument(
    "--no-api",
    action="store_true",
    help="Run the engine without the api"
  )

  parser = argparse.ArgumentParser(
    prog="subconscious",
    description="Subconscious: A Distributed Agentic Engine",
    parents=[base_parser]
  )
  
  subparsers = parser.add_subparsers(dest="command")
  
  # Subcommand: desktop
  gui_parser = subparsers.add_parser(
    "desktop",
    help="Starts the engine with the desktop interface (default)",
    parents=[base_parser]
  )

  # Subcommand: web
  web_parser = subparsers.add_parser(
    "web",
    help="Starts the engine with the web interface",
    parents=[base_parser]
  )

  # Subcommand: engine
  engine_parser = subparsers.add_parser(
    "engine", 
    help="Starts only the engine",
    parents=[base_parser]
  )

  # Only create these subparsers when the dev flag is present on the command line.
  if dev_present:
    # Subcommand: tui
    tui_parser = subparsers.add_parser(
      "code",
      help="Starts the engine with the Terminal TUI interface",
      parents=[base_parser]
    )

    # Logging formatting
    logging.basicConfig(format='[%(levelname)s|%(asctime)s.%(msecs)04d|%(filename)s|%(lineno)d] %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
  else:
    # Logging formatting
    logging.basicConfig(format='[%(asctime)s] %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
  
  # Initiate Config here to allow for accepting config arguments in the future
  args = parser.parse_args()

  # Logging setup
  logger = logging.getLogger('subconscious')
  if args.dev:
    logger.setLevel(logging.DEBUG)
  else:
    logger.setLevel(logging.INFO)

  # If running as a frozen exe, also write logs to a file next to the executable
  if getattr(sys, 'frozen', False):
    log_path = os.path.join(os.path.dirname(sys.executable), "subconscious_crash.log")
    fh = logging.FileHandler(log_path, encoding="utf-8")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(logging.Formatter('[%(levelname)s|%(asctime)s.%(msecs)04d|%(filename)s|%(lineno)d] %(message)s', datefmt='%Y-%m-%d %H:%M:%S'))
    logger.addHandler(fh)
    logging.getLogger().addHandler(fh)  # Also capture root logger (3rd party libs)
  
  # Init block
  try:
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    
    # Default to launching the GUI when no subcommand is provided.
    if args.command == "engine":
      loop.run_until_complete(Engine().start_engine(
        Config(dev=args.dev, gui=False, tui=False, api=args.no_api)
      ))
    elif args.command == "desktop" or args.command is None:
      loop.run_until_complete(start_gui(
        Config(dev=args.dev, gui=True, tui=False, api=args.no_api)
      ))
    elif args.command == "web":
      loop.run_until_complete(start_web(
        Config(dev=args.dev, gui=False, tui=False, api=args.no_api)
      ))
    elif args.command == "code":
      loop.run_until_complete(start_tui(
        Config(dev=args.dev, gui=False, tui=True, api=args.no_api)
      ))
    else:
      parser.print_help()
  except KeyboardInterrupt:
    pass
  except Exception:
    logger.error("Unhandled exception in main():\n" + traceback.format_exc())
  finally:
    try:
      # Cancel all tasks still pending on the loop
      pending = asyncio.all_tasks(loop)
      if pending:
        loop.run_until_complete(asyncio.gather(*pending, return_exceptions=True))
    finally:
      loop.close()
    sys.exit(0)


if __name__ == "__main__":
  main()
