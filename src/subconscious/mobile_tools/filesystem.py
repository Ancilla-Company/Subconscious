"""
Mobile filesystem tool — sandboxed variant of the desktop filesystem tool.

All paths are resolved relative to the app's data directory (EngineContext.data_dir).
Absolute paths and path traversal attempts (../../) are rejected, keeping the
agent confined to the app sandbox — required for iOS and Android distribution.

Only pure-Python operations are used (pathlib, os) so no additional wheels are
needed beyond what Flet already bundles for mobile.
"""

from __future__ import annotations

import os
import pathlib
from pydantic_ai import RunContext

from ..tools import EngineContext


def _safe_path(data_dir: str, user_path: str) -> pathlib.Path:
  """Resolve *user_path* inside *data_dir* and raise if it escapes the sandbox."""
  base = pathlib.Path(data_dir).resolve()
  target = (base / user_path).resolve()
  if not str(target).startswith(str(base)):
    raise PermissionError(f"Path '{user_path}' escapes the app sandbox.")
  return target


async def list_directory(ctx: RunContext[EngineContext], path: str = ".") -> dict:
  """
  List files and folders inside the app's sandboxed data directory.

  Args:
    path: Relative path within the app data directory. Defaults to root.
  Returns:
    dict with 'entries' list of {name, type, size} dicts, or 'error' key.
  """
  try:
    target = _safe_path(ctx.deps.data_dir, path)
    if not target.exists():
      return {"error": f"Path not found: {path}"}
    if not target.is_dir():
      return {"error": f"Not a directory: {path}"}
    entries = []
    for item in sorted(target.iterdir()):
      entries.append({
        "name": item.name,
        "type": "dir" if item.is_dir() else "file",
        "size": item.stat().st_size if item.is_file() else None,
      })
    return {"path": str(path), "entries": entries}
  except PermissionError as e:
    return {"error": str(e)}
  except Exception as e:
    return {"error": f"Failed to list directory: {e}"}


async def read_file(ctx: RunContext[EngineContext], path: str) -> dict:
  """
  Read a text file from within the app's sandboxed data directory.

  Args:
    path: Relative path within the app data directory.
  Returns:
    dict with 'content' string, or 'error' key.
  """
  try:
    target = _safe_path(ctx.deps.data_dir, path)
    if not target.exists():
      return {"error": f"File not found: {path}"}
    if not target.is_file():
      return {"error": f"Not a file: {path}"}
    # Limit reads to 512 KB on mobile to protect memory
    max_bytes = 512 * 1024
    content = target.read_bytes()
    if len(content) > max_bytes:
      return {"error": f"File too large for mobile read ({len(content)} bytes). Max: {max_bytes}."}
    return {"path": str(path), "content": content.decode("utf-8", errors="replace")}
  except PermissionError as e:
    return {"error": str(e)}
  except Exception as e:
    return {"error": f"Failed to read file: {e}"}


async def write_file(ctx: RunContext[EngineContext], path: str, content: str) -> dict:
  """
  Write text content to a file within the app's sandboxed data directory.

  Args:
    path:    Relative path within the app data directory.
    content: Text content to write (UTF-8).
  Returns:
    dict with 'status' 'ok' and 'path', or 'error' key.
  """
  try:
    target = _safe_path(ctx.deps.data_dir, path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
    return {"status": "ok", "path": str(path)}
  except PermissionError as e:
    return {"error": str(e)}
  except Exception as e:
    return {"error": f"Failed to write file: {e}"}


async def delete_file(ctx: RunContext[EngineContext], path: str) -> dict:
  """
  Delete a file within the app's sandboxed data directory.

  Args:
    path: Relative path within the app data directory.
  Returns:
    dict with 'status' 'ok', or 'error' key.
  """
  try:
    target = _safe_path(ctx.deps.data_dir, path)
    if not target.exists():
      return {"error": f"File not found: {path}"}
    if target.is_dir():
      return {"error": f"Path is a directory. Use delete_directory to remove folders."}
    target.unlink()
    return {"status": "ok", "path": str(path)}
  except PermissionError as e:
    return {"error": str(e)}
  except Exception as e:
    return {"error": f"Failed to delete file: {e}"}


TOOLS = [list_directory, read_file, write_file, delete_file]
