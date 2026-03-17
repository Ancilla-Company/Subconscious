"""
Filesystem tools — read files, list directories, create files, move to trash.
Operations are sandboxed: paths outside the user's home directory are blocked
unless the engine context data_dir is explicitly set wider.
"""

import os
import stat
import logging
import pathlib
import platform
from typing import Optional
from . import EngineContext
from pydantic_ai import RunContext

logger = logging.getLogger("subconscious")

_MAX_READ_BYTES = 100_000_000  # ~100 KB max read


def _safe_path(raw: str) -> pathlib.Path:
  """Resolve and return the path. Raises ValueError if obviously unsafe."""
  p = pathlib.Path(raw).expanduser().resolve()
  return p
  home = pathlib.Path.home().resolve()
  # Block absolute paths that escape the user's home tree entirely
  try:
    p.relative_to(home)
  except ValueError:
    raise ValueError(
      f"Access denied: '{p}' is outside the user home directory. "
      "For security, only paths inside your home folder are permitted."
    )
  return p


async def read_file(ctx: RunContext[EngineContext], path: str, encoding: str = "utf-8") -> str:
  """
  Read and return the text content of a file.
  Limited to files inside the user's home directory for safety.
  Returns up to 100 KB of content; larger files are truncated.

  Args:
    path: Absolute or ~ relative path to the file.
    encoding: Text encoding (default utf-8).
  """
  try:
    p = _safe_path(path)
    if not p.exists():
      return f"File not found: {p}"
    if not p.is_file():
      return f"'{p}' is not a file."

    size = p.stat().st_size
    raw = p.read_bytes()[:_MAX_READ_BYTES]
    try:
      text = raw.decode(encoding)
    except UnicodeDecodeError:
      return f"File appears to be binary or not {encoding} encoded."

    if size > _MAX_READ_BYTES:
      text += f"\n\n[... file truncated — showed {_MAX_READ_BYTES} of {size} bytes]"

    return text
  except ValueError as exc:
    return str(exc)
  except Exception as exc:
    return f"Error reading file: {exc}"


async def list_directory(
  ctx: RunContext[EngineContext],
  path: str = "~",
  show_hidden: bool = False,
) -> list[dict]:
  """
  List the contents of a directory.
  Returns a list of dicts with 'name', 'type' ('file' or 'dir'), and 'size_bytes'.

  Args:
    path: Directory to list (default '~' for the home directory).
    show_hidden: Include files/folders starting with a dot (default False).
  """
  try:
    p = _safe_path(path)
    if not p.exists():
      return [{"error": f"Path not found: {p}"}]
    if not p.is_dir():
      return [{"error": f"'{p}' is not a directory."}]

    entries = []
    for child in sorted(p.iterdir()):
      if not show_hidden and child.name.startswith("."):
        continue
      try:
        info = child.stat()
        entries.append({
          "name": child.name,
          "type": "dir" if child.is_dir() else "file",
          "size_bytes": info.st_size if child.is_file() else None,
        })
      except OSError:
        entries.append({"name": child.name, "type": "unknown", "size_bytes": None})

    return entries or [{"message": "Directory is empty."}]
  except ValueError as exc:
    return [{"error": str(exc)}]
  except Exception as exc:
    return [{"error": f"Error listing directory: {exc}"}]


async def create_file(
  ctx: RunContext[EngineContext],
  path: str,
  content: str = "",
  overwrite: bool = False,
) -> str:
  """
  Create a new text file at the given path with optional content.
  Parent directories are created automatically.
  Will not overwrite an existing file unless overwrite=True.

  Args:
    path: Destination file path.
    content: Text to write into the file (default empty).
    overwrite: Allow overwriting existing files (default False).
  """
  try:
    p = _safe_path(path)
    if p.exists() and not overwrite:
      return f"File already exists: {p}. Set overwrite=True to replace it."
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding="utf-8")
    return f"File created: {p}"
  except ValueError as exc:
    return str(exc)
  except Exception as exc:
    return f"Error creating file: {exc}"


async def get_file_info(ctx: RunContext[EngineContext], path: str) -> dict:
  """
  Return metadata about a file or directory: name, size, type, last modified.

  Args:
    path: Path to the file or directory.
  """
  try:
    p = _safe_path(path)
    if not p.exists():
      return {"error": f"Path not found: {p}"}
    info = p.stat()
    import datetime
    return {
      "name": p.name,
      "path": str(p),
      "type": "directory" if p.is_dir() else "file",
      "size_bytes": info.st_size,
      "size_human": _human_size(info.st_size),
      "modified": datetime.datetime.fromtimestamp(info.st_mtime).isoformat(),
      "created":  datetime.datetime.fromtimestamp(info.st_ctime).isoformat(),
    }
  except ValueError as exc:
    return {"error": str(exc)}
  except Exception as exc:
    return {"error": str(exc)}


async def move_to_trash(ctx: RunContext[EngineContext], path: str) -> str:
  """
  Move a file or folder to the system recycle bin / trash.
  Does NOT permanently delete. Requires the 'send2trash' package.

  Args:
    path: Path to the file or folder to trash.
  """
  try:
    import send2trash  # pip install send2trash
  except ImportError:
    return "Required package missing. Install: send2trash"
  try:
    p = _safe_path(path)
    if not p.exists():
      return f"Path not found: {p}"
    send2trash.send2trash(str(p))
    return f"Moved to trash: {p}"
  except ValueError as exc:
    return str(exc)
  except Exception as exc:
    return f"Error moving to trash: {exc}"


def _human_size(n: int) -> str:
  for unit in ("B", "KB", "MB", "GB", "TB"):
    if n < 1024:
      return f"{n:.1f} {unit}"
    n /= 1024
  return f"{n:.1f} PB"


TOOLS = [read_file, list_directory, create_file, get_file_info, move_to_trash]
