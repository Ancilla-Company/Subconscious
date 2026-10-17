"""Frozen-build entry point for the Subconscious engine (PyInstaller)."""

import multiprocessing
import os
import sys


def _has_console() -> bool:
    if sys.platform != "win32":
        return True
    import ctypes

    return bool(ctypes.windll.kernel32.GetConsoleWindow())


def run() -> int:
    multiprocessing.freeze_support()

    # Pydantic plugins (e.g. logfire's) inspect source code, which does not
    # exist in a frozen build. Must be set before pydantic is imported.
    os.environ.setdefault("PYDANTIC_DISABLE_PLUGINS", "1")
    # The MSIX install directory is read-only; never try to write .pyc files.
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")

    # Windowed builds have no stdio; make print() and logging safe.
    if sys.stdout is None:
        sys.stdout = open(os.devnull, "w", encoding="utf-8")
    if sys.stderr is None:
        sys.stderr = open(os.devnull, "w", encoding="utf-8")

    # First thing: route logs to engine.log (never raises; works without stdio).
    from subconscious_engine.logging_setup import configure_engine_logging

    configure_engine_logging(component="entry")
    arguments = sys.argv[1:]
    # Launched from a shortcut / Start menu (no console, no arguments):
    # run the engine with its tray icon instead of printing help.
    if not arguments and not _has_console():
        arguments = ["start"]

    from subconscious_engine.__main__ import main

    return main(arguments)


if __name__ == "__main__":
    raise SystemExit(run())
