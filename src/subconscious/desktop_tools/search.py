"""
Cross-platform filesystem search tool.

Provides a pure-Python fallback that works on Windows, macOS and Linux.
It supports filename glob patterns, optional content searching (skipping
binary files), extension filters, case sensitivity control and a result cap.

The function is asynchronous (runs the blocking walk in a thread) and
returns a list of dicts similar to other desktop tools.
"""
import os
import fnmatch
import pathlib
import re
import datetime
import logging
import asyncio
from typing import Optional
from pydantic_ai import RunContext

from . import EngineContext

logger = logging.getLogger("subconscious")


def _human_size(n: float) -> str:
  for unit in ("B", "KB", "MB", "GB", "TB"):
    if n < 1024:
      return f"{n:.1f} {unit}"
    n /= 1024
  return f"{n:.1f} PB"


def _is_text_file(path: pathlib.Path, sample_size: int = 8192) -> bool:
  try:
    with path.open("rb") as fh:
      chunk = fh.read(sample_size)
      if not chunk:
        return True
      if b"\x00" in chunk:
        return False
      # Lightweight heuristic: if many non-printables, treat as binary
      non_printable = sum(1 for b in chunk if b < 9 or (11 <= b <= 12) or (14 <= b <= 31))
      if non_printable / max(1, len(chunk)) > 0.30:
        return False
      return True
  except Exception:
    return False


def _match_name(name: str, pattern: str, case_sensitive: bool) -> bool:
  if case_sensitive:
    return fnmatch.fnmatchcase(name, pattern)
  # Case-insensitive: normalize both
  return fnmatch.fnmatchcase(name.lower(), pattern.lower())


def _search_worker(
  root: str,
  name_pattern: str,
  content_query: str,
  file_extensions: set,
  case_sensitive: bool,
  max_results: int,
  recursive: bool,
  follow_symlinks: bool,
) -> list[dict]:
  results: list[dict] = []
  root_p = pathlib.Path(root)

  try:
    for dirpath, dirnames, filenames in os.walk(root_p, followlinks=follow_symlinks):
      for fname in filenames:
        if not _match_name(fname, name_pattern, case_sensitive):
          continue

        p = pathlib.Path(dirpath) / fname
        try:
          if file_extensions and p.suffix.lower() not in file_extensions:
            continue

          first_match_line: Optional[int] = None
          snippet: Optional[str] = None

          if content_query:
            # Skip obvious binaries
            if not _is_text_file(p):
              continue

            # Search file for content_query
            try:
              with p.open("r", encoding="utf-8", errors="replace") as fh:
                for lineno, line in enumerate(fh, 1):
                  if (case_sensitive and content_query in line) or (
                    not case_sensitive and content_query.lower() in line.lower()
                  ):
                    first_match_line = lineno
                    snippet = line.strip()
                    break
            except Exception:
              # If file cannot be read as text, skip it
              continue

            if first_match_line is None:
              continue

          try:
            info = p.stat()
          except OSError:
            continue

          entry: dict = {
            "path": str(p),
            "name": p.name,
            "size_bytes": info.st_size,
            "size_human": _human_size(info.st_size),
            "modified": datetime.datetime.fromtimestamp(info.st_mtime).isoformat(),
          }
          if first_match_line is not None:
            entry["first_match_line"] = first_match_line
          if snippet is not None:
            entry["snippet"] = snippet

          results.append(entry)
          if len(results) >= max_results:
            return results

        except Exception:
          continue

      if not recursive:
        break

    if not results:
      return [{"message": f"No files found matching pattern '{name_pattern}' in '{root_p}'."}]
    return results

  except Exception as exc:
    return [{"error": f"Error searching files: {exc}"}]


async def search_fs(
  ctx: RunContext[EngineContext],
  directory: str = "~",
  name_pattern: str = "*",
  content_query: str = "",
  file_extensions: str = "",
  case_sensitive: bool = False,
  max_results: int = 100,
  recursive: bool = True,
  follow_symlinks: bool = False,
) -> list[dict]:
  """
  Search filesystem for files by name pattern and optionally by content.

  Args:
    directory: Root directory to search from (default home folder).
    name_pattern: Glob-style pattern for filename matching (default '*').
    content_query: Optional substring/regex to search inside files.
    file_extensions: Comma-separated extensions to filter by (e.g. '.py,.txt').
    case_sensitive: Whether searches are case-sensitive (default False).
    max_results: Maximum number of results to return.
    recursive: Search subdirectories recursively.
    follow_symlinks: Follow symbolic links when walking (default False).

  Returns:
    A list of dicts with file metadata and optional match line/snippet.
  """
  root_p = pathlib.Path(directory).expanduser()
  if not root_p.exists():
    return [{"error": f"Directory not found: {root_p}"}]
  if not root_p.is_dir():
    return [{"error": f"'{root_p}' is not a directory."}]

  # Parse extension filter
  ext_filter: set = set()
  if file_extensions.strip():
    for e in file_extensions.split(","):
      e = e.strip().lower()
      if e and not e.startswith("."):
        e = "." + e
      if e:
        ext_filter.add(e)

  # Run blocking walk in a thread
  return await asyncio.to_thread(
    _search_worker,
    str(root_p),
    name_pattern,
    content_query,
    ext_filter,
    case_sensitive,
    max_results,
    recursive,
    follow_symlinks,
  )


TOOLS = [
  search_fs,
]
