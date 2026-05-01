"""
Mobile entry point - standalone, no desktop/TUI imports.
Used for Flet Pack / PyInstaller packaging of the mobile app.
"""
import os
import sys
import asyncio
import logging
import argparse
from subconscious.config import Config
from subconscious.mobile import start_mobile


def main():

  base_parser = argparse.ArgumentParser(add_help=False)
  base_parser.add_argument("--dev", action="store_true", help="Run in development mode")
  parser = argparse.ArgumentParser(
    prog="subconscious-mobile",
    description="Subconscious Mobile",
    parents=[base_parser]
  )
  args = parser.parse_args()

  logging.basicConfig(
    format='[%(levelname)s|%(asctime)s.%(msecs)04d|%(filename)s|%(lineno)d] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
  )
  logger = logging.getLogger('subconscious')
  logger.setLevel(logging.DEBUG if args.dev else logging.INFO)

  if getattr(sys, 'frozen', False):
    log_path = os.path.join(os.path.dirname(sys.executable), "subconscious_mobile_crash.log")
    fh = logging.FileHandler(log_path, encoding="utf-8")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(logging.Formatter(
      '[%(levelname)s|%(asctime)s.%(msecs)04d|%(filename)s|%(lineno)d] %(message)s',
      datefmt='%Y-%m-%d %H:%M:%S'
    ))
    logger.addHandler(fh)
    logging.getLogger().addHandler(fh)

  try:
    from subconscious.mobile import start_mobile
    from subconscious.config import Config

    logger.info("Creating Config...")
    config = Config(dev=args.dev, gui=True, tui=False)
    logger.info("Config created. Starting Mobile GUI...")

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    loop.run_until_complete(start_mobile(config))
    logger.info("Mobile GUI exited cleanly.")
  except KeyboardInterrupt:
    pass
  except Exception:
    import traceback
    logger.error("Unhandled exception:\n" + traceback.format_exc())
  finally:
    sys.exit(0)


if __name__ == "__main__":
  main()
