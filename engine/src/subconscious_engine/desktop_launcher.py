"""Locate and start the Flutter desktop GUI from the tray 'Open Desktop' action."""

import logging
import os
from pathlib import Path
import subprocess
import sys

_LOG = logging.getLogger(__name__)

DESKTOP_EXE_ENVIRONMENT_VARIABLE = "SUBCONSCIOUS_DESKTOP_EXE"
_DEV_RELEASE_RELATIVE = Path("apps/unified_app/build/windows/x64/runner/Release/unified_app.exe")


def candidate_desktop_paths() -> list[Path]:
    """Ordered candidate GUI executables: env var, packaged layout, dev build."""
    candidates: list[Path] = []
    override = os.environ.get(DESKTOP_EXE_ENVIRONMENT_VARIABLE)
    if override:
        candidates.append(Path(override))
    if getattr(sys, "frozen", False):
        # <package root>\engine\subconscious-desktop.exe -> <package root>\gui\gui.exe
        candidates.append(Path(sys.executable).resolve().parent.parent / "gui" / "gui.exe")
    # engine/src/subconscious_engine/desktop_launcher.py -> repo root is parents[3]
    parents = Path(__file__).resolve().parents
    if len(parents) > 3:
        candidates.append(parents[3] / _DEV_RELEASE_RELATIVE)
    return candidates


def find_desktop_executable() -> tuple[Path | None, list[Path]]:
    tried = candidate_desktop_paths()
    for path in tried:
        if path.is_file():
            return path, tried
    return None, tried


def launch_desktop_app(_address: str, _token: str) -> None:
    """Start the desktop GUI detached. The token is deliberately not passed;
    the GUI reads runtime.json itself."""
    executable, tried = find_desktop_executable()
    if executable is None:
        _LOG.error(
            "Open Desktop failed: desktop executable not found. Tried: %s",
            [str(path) for path in tried],
        )
        return
    kwargs: dict = {
        "cwd": str(executable.parent),
        "stdin": subprocess.DEVNULL,
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "close_fds": True,
    }
    if sys.platform == "win32":
        kwargs["creationflags"] = (
            subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
        )
    else:
        kwargs["start_new_session"] = True
    try:
        subprocess.Popen([str(executable)], **kwargs)
    except Exception:
        _LOG.exception("Open Desktop failed: could not start %s", executable)
        return
    _LOG.info("Started desktop app: %s", executable)
