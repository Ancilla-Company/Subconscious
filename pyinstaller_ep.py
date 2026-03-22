"""
Standalone entry point for PyInstaller / flet pack.
Uses absolute imports so the packager can resolve the package correctly.
"""
import sys
import os

# Create a debug log for the compiled executable since it doesn't have a console.
# This prevents crashes from libraries like `speedtest-cli` expecting a console,
# AND logs any immediate startup crashes!
if getattr(sys, 'frozen', False):
    log_path = os.path.join(os.path.dirname(sys.executable), "subconscious_crash.log")
    debug_log = open(log_path, "w", buffering=1, encoding="utf-8")
    sys.stdout = debug_log
    sys.stderr = debug_log
    
    if sys.stdin is None:
        sys.stdin = open(os.devnull, "r")
else:
    # Fallback for normal execution just in case
    if sys.stdout is None:
        sys.stdout = open(os.devnull, "w")
    if sys.stderr is None:
        sys.stderr = open(os.devnull, "w")
    if sys.stdin is None:
        sys.stdin = open(os.devnull, "r")

# Ensure the bundled 'subconscious' package is on the path when frozen
if getattr(sys, 'frozen', False):
  # _MEIPASS is the temp folder PyInstaller extracts files to
  bundle_dir = sys._MEIPASS
  sys.path.insert(0, bundle_dir)

from subconscious.cli import main


if __name__ == "__main__":
  if "gui" not in sys.argv:
    sys.argv.insert(1, "gui")
  main()
