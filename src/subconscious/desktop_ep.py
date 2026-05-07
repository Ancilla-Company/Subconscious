"""
Standalone entry point for Flet Pack /PyInstaller packaging.
Uses absolute imports so the packager can resolve the package correctly.
"""
import os
import sys
import time
import traceback


# --- Logging setup FIRST, before any other imports ---
# Determines a log path next to the executable for frozen builds.
_log_path = os.path.join(
  os.path.dirname(sys.executable if getattr(sys, 'frozen', False) else __file__),
    "subconscious_crash.log"
)
_debug_log = open(_log_path, "w", buffering=1, encoding="utf-8")

def _log(msg):
  """Write to both the console (if available) and the crash log."""
  try:
    print(msg, flush=True)
  except Exception:
    pass
  try:
    _debug_log.write(msg + "\n")
    _debug_log.flush()
  except Exception:
    pass

# Redirect stdout/stderr to the log file if no real console is attached
if getattr(sys, 'frozen', False):
  if sys.stdout is None or not hasattr(sys.stdout, 'isatty') or not sys.stdout.isatty():
    sys.stdout = _debug_log
    sys.stderr = _debug_log

if sys.stdin is None:
  sys.stdin = open(os.devnull, "r")

# --- Now attempt all imports, catching errors early ---
try:
  _log("Importing subconscious.cli...")
  from subconscious.cli import main
  _log("Import successful.")
except Exception:
  _log("FATAL: Failed to import subconscious.cli:")
  _log(traceback.format_exc())
  _log("Waiting 60s before exit so you can read this...")
  time.sleep(60)
  sys.exit(1)


if __name__ == "__main__":
  try:
    if "desktop" not in sys.argv:
      sys.argv.insert(1, "desktop")
    _log("Starting Subconscious...")
    main()
  except Exception:
    _log("FATAL: Unhandled exception in main():")
    _log(traceback.format_exc())
    _log("Waiting 60s before exit so you can read this...")
    time.sleep(60)
    sys.exit(1)
       