"""
Web entry point - standalone for Flet Pack / PyInstaller packaging.
When run directly (unfrozen) it delegates to the CLI so VS Code
launch configs and the 'subconscious web' command still work.
"""
import os
import sys
import asyncio
import logging
import argparse
import traceback


def main():
  """ Web entry point for Subconscious """
  base_parser = argparse.ArgumentParser(add_help=False)
  base_parser.add_argument("--dev", action="store_true", help="Run in development mode")
  parser = argparse.ArgumentParser(
    prog="subconscious-web",
    description="Subconscious Web",
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
    log_path = os.path.join(os.path.dirname(sys.executable), "subconscious_web_crash.log")
    fh = logging.FileHandler(log_path, encoding="utf-8")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(logging.Formatter(
      '[%(levelname)s|%(asctime)s.%(msecs)04d|%(filename)s|%(lineno)d] %(message)s',
      datefmt='%Y-%m-%d %H:%M:%S'
    ))
    logger.addHandler(fh)
    logging.getLogger().addHandler(fh)

  try:
    from subconscious.web import start_web
    from subconscious.config import Config

    logger.info("Creating Config...")
    config = Config(dev=args.dev, gui=True, tui=False)
    logger.info("Config created. Starting Web GUI...")

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    loop.run_until_complete(start_web(config))
    logger.info("Web GUI exited cleanly.")
  except KeyboardInterrupt:
    pass
  except Exception:
    logger.error("Unhandled exception:\n" + traceback.format_exc())
  finally:
    sys.exit(0)


if __name__ == "__main__":
  main()
