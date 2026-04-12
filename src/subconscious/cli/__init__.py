import os
import sys
import uvicorn
import asyncio
import logging
import argparse
import traceback

from ..gui import start_gui
from ..engine import Engine
from ..api import create_app
from ..tui.tui import start_tui
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

  # Subcommand: api
  api_parser = subparsers.add_parser(
    "api",
    help="Starts the API server for external integrations",
    parents=[base_parser]
  )
  api_parser.add_argument(
    "--host",
    default="localhost",
    help="Host to bind the API server to"
  )
  api_parser.add_argument(
    "--port",
    type=int,
    default=8000,
    help="Port to bind the API server to"
  )
  args = parser.parse_args()

  # Logging setup
  logging.basicConfig(format='[%(levelname)s|%(asctime)s.%(msecs)04d|%(filename)s|%(lineno)d] %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
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
  
  try:
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    
    print(LOGO)
    if args.command == "engine":
      loop.run_until_complete(Engine().start_engine(
        Config(dev=args.dev, gui=False, tui=False)
      ))
    elif args.command == "gui":
      loop.run_until_complete(start_gui(
        Config(dev=args.dev, gui=True, tui=False)
      ))
    elif args.command == "tui" or args.command is None:
      loop.run_until_complete(start_tui(
        Config(dev=args.dev, gui=False, tui=True)
      ))
    elif args.command == "api":
      uvicorn.run(
        create_app(
          Config(dev=args.dev, gui=False, tui=False)
        ),
        host=args.host,
        port=args.port
      )
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
