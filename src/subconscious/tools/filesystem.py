"""
Filesystem tools — read files, list directories, create files, move to trash,
read specific line ranges, and search for files on disk.

File reading uses a tiered strategy based on file size:
  < 2 MB   — Full load:   entire file content is returned in one shot.
  2–10 MB  — Skeleton:    top-level structure (classes/functions/headings) is
                           returned; use read_range() to fetch specific lines.
  > 10 MB  — RAG hint:    only metadata is returned; use search_in_file() to
                           search for relevant lines before reading a range.
"""
import re
import docx
import pypdf
import logging
import pathlib
import datetime
import openpyxl
import send2trash
from pydantic_ai import RunContext

from . import EngineContext


logger = logging.getLogger("subconscious")

# Tier thresholds
_FULL_LOAD_LIMIT  =   2_000_000   #  2 MB  — full content
_CHUNKED_LIMIT    =  10_000_000   # 10 MB  — skeleton + read_range
# > 10 MB → RAG hint only


def _resolve_path(raw: str) -> pathlib.Path:
  """Resolve the path without any sandboxing restrictions."""
  return pathlib.Path(raw).expanduser().resolve()


async def read_file(ctx: RunContext[EngineContext], path: str, encoding: str = "utf-8") -> str:
  """
  Read and return the content of a file using an adaptive tiered strategy:

  • < 2 MB   — Full load: entire file text is returned.
  • 2–10 MB  — Skeleton mode: top-level structure (classes/functions/headings) is
               returned with line numbers. Use read_range() to fetch specific lines.
  • > 10 MB  — RAG hint: only metadata is returned. Use search_in_file() to locate
               relevant lines, then use read_range() to read them.

  Supports plain text, .docx, .xlsx, and .pdf formats.

  Args:
    path: Absolute or ~ relative path to the file.
    encoding: Text encoding for plain text files (default utf-8).
  """
  try:
    p = _resolve_path(path)
    if not p.exists():
      return f"File not found: {p}"
    if not p.is_file():
      return f"'{p}' is not a file."

    size_bytes = p.stat().st_size
    ext = p.suffix.lower()

    # ── Structured formats: always extract text first, then tier on result size ──
    if ext in (".docx", ".xlsx", ".pdf"):
      if ext == ".docx":
        text = _read_docx(p)
      elif ext == ".xlsx":
        text = _read_xlsx(p)
      else:
        text = _read_pdf(p)
      char_count = len(text)
      if char_count <= _FULL_LOAD_LIMIT:
        return text
      elif char_count <= _CHUNKED_LIMIT:
        return (
          f"[SKELETON MODE — file is {_human_size(size_bytes)}. "
          f"Showing first 2 MB. Use read_range() for more.]\n\n"
          + text[:_FULL_LOAD_LIMIT]
        )
      else:
        return (
          f"[RAG MODE — file is {_human_size(size_bytes)} after extraction ({char_count:,} chars). "
          f"Use search_in_file() to locate relevant sections, then read_range() to fetch them.]\n"
          f"Path: {p}"
        )

    # ── Plain text: tier on raw byte size ──
    if size_bytes <= _FULL_LOAD_LIMIT:
      # Full load
      raw = p.read_bytes()
      try:
        return raw.decode(encoding)
      except UnicodeDecodeError:
        return (
          f"File appears to be binary or not {encoding}-encoded. "
          "Try .docx/.xlsx/.pdf for supported document formats."
        )

    elif size_bytes <= _CHUNKED_LIMIT:
      # Skeleton mode: extract top-level structure with line numbers
      return _build_skeleton(p, encoding)

    else:
      # RAG hint only
      return (
        f"[RAG MODE — '{p.name}' is {_human_size(size_bytes)} (>{_human_size(_CHUNKED_LIMIT)}). "
        f"This file is too large to load into context directly.\n"
        f"1. Use search_in_file(path='{p}', query='...') to find relevant line numbers.\n"
        f"2. Then use read_range(path='{p}', start_line=N, end_line=M) to read those lines.\n"
        f"Path: {p}]"
      )

  except Exception as exc:
    return f"Error reading file: {exc}"


def _build_skeleton(p: pathlib.Path, encoding: str = "utf-8") -> str:
  """
  Return a numbered-line skeleton of a text file showing only structural lines
  (class/def/async def for Python; headings for Markdown; all lines for others)
  plus the first and last 20 lines, so the AI can orient itself before calling
  read_range().
  """
  try:
    raw = p.read_bytes()
    try:
      text = raw.decode(encoding, errors="replace")
    except Exception:
      return f"[Cannot decode file as {encoding}]"

    lines = text.splitlines()
    total = len(lines)
    ext = p.suffix.lower()

    if ext == ".py":
      # Python: keep import blocks, class/def declarations, decorators
      pattern = re.compile(r"^\s*(class |def |async def |@|\bimport |\bfrom )")
    elif ext in (".md", ".markdown", ".rst", ".txt"):
      # Markup: keep heading lines
      pattern = re.compile(r"^(#{1,6} |={3,}|-{3,}|\*{3,}|\s*\d+\.\s|\s*[-*]\s)")
    else:
      # Generic: keep non-blank lines that look like declarations
      pattern = re.compile(r"^\s*(class |def |function |public |private |protected |export |import |from |#|//)")

    skeleton_lines = []
    for i, line in enumerate(lines, 1):
      if pattern.match(line):
        skeleton_lines.append(f"{i:>6}: {line}")

    # Always include first 20 and last 20 lines for context
    head = [f"{i+1:>6}: {lines[i]}" for i in range(min(20, total))]
    tail = [f"{i+1:>6}: {lines[i]}" for i in range(max(0, total - 20), total)]

    result_parts = [
      f"[SKELETON MODE — '{p.name}' is {_human_size(p.stat().st_size)} ({total:,} lines). "
      f"Showing structural lines + first/last 20. Use read_range() to fetch specific sections.]\n",
      "── First 20 lines ──",
      *head,
      "",
      f"── Structural lines ({len(skeleton_lines)} found) ──",
      *skeleton_lines,
      "",
      "── Last 20 lines ──",
      *tail,
    ]
    return "\n".join(result_parts)

  except Exception as exc:
    return f"[Error building skeleton: {exc}]"


def _read_docx(path: pathlib.Path) -> str:
  """Extract text from a .docx file using python-docx."""
  try:
    doc = docx.Document(path)
    return "\n".join([para.text for para in doc.paragraphs])
  except Exception as e:
    return f"Error reading Word document: {e}"


def _read_xlsx(path: pathlib.Path) -> str:
  """Extract text/data from an .xlsx file using openpyxl."""
  try:
    wb = openpyxl.load_workbook(path, data_only=True, read_only=True)
    output = []
    for sheet in wb.worksheets:
      output.append(f"--- Sheet: {sheet.title} ---")
      for row in sheet.iter_rows(values_only=True):
        # Filter out empty rows
        if any(cell is not None for cell in row):
          output.append("\t".join([str(cell) if cell is not None else "" for cell in row]))
    return "\n".join(output)
  except Exception as e:
    return f"Error reading Excel spreadsheet: {e}"


def _read_pdf(path: pathlib.Path) -> str:
  """Extract text from a .pdf file using pypdf."""
  try:
    reader = pypdf.PdfReader(path)
    output = []
    for i, page in enumerate(reader.pages):
      text = page.extract_text()
      if text:
        output.append(f"--- Page {i+1} ---\n{text}")
    return "\n".join(output)
  except Exception as e:
    return f"Error reading PDF: {e}"


async def read_range(
  ctx: RunContext[EngineContext],
  path: str,
  start_line: int,
  end_line: int,
  encoding: str = "utf-8",
) -> str:
  """
  Read a specific range of lines from a text file (1-based, inclusive).
  Use this after read_file() returns a skeleton to fetch the lines you need.

  Args:
    path: Absolute or ~ relative path to the file.
    start_line: First line to return (1-based).
    end_line: Last line to return (inclusive). Maximum span is 500 lines.
    encoding: Text encoding (default utf-8).
  """
  try:
    p = _resolve_path(path)
    if not p.exists() or not p.is_file():
      return f"File not found: {p}"

    # Cap range to avoid huge context dumps
    if end_line - start_line > 500:
      end_line = start_line + 499
      capped = True
    else:
      capped = False

    lines = p.read_text(encoding=encoding, errors="replace").splitlines()
    total = len(lines)
    s = max(0, start_line - 1)
    e = min(total, end_line)
    selected = lines[s:e]

    header = f"[Lines {s+1}–{e} of {total} from '{p.name}'"
    if capped:
      header += " (range capped at 500 lines)"
    header += "]\n"

    numbered = "\n".join(f"{s+i+1:>6}: {line}" for i, line in enumerate(selected))
    return header + numbered

  except Exception as exc:
    return f"Error reading range: {exc}"


async def search_in_file(
  ctx: RunContext[EngineContext],
  path: str,
  query: str,
  case_sensitive: bool = False,
  max_results: int = 50,
) -> str:
  """
  Search for a keyword or regex pattern inside a file and return matching lines
  with their line numbers. Ideal for large files (> 10 MB) before using read_range().

  Args:
    path: Absolute or ~ relative path to the file.
    query: Plain text substring or regular expression to search for.
    case_sensitive: Whether the search is case-sensitive (default False).
    max_results: Maximum number of matching lines to return (default 50).
  """
  try:
    p = _resolve_path(path)
    if not p.exists() or not p.is_file():
      return f"File not found: {p}"

    flags = 0 if case_sensitive else re.IGNORECASE
    try:
      pattern = re.compile(query, flags)
    except re.error as exc:
      return f"Invalid regex pattern: {exc}"

    matches = []
    with p.open("r", encoding="utf-8", errors="replace") as fh:
      for lineno, line in enumerate(fh, 1):
        if pattern.search(line):
          matches.append(f"{lineno:>6}: {line.rstrip()}")
          if len(matches) >= max_results:
            break

    if not matches:
      return f"No matches found for '{query}' in '{p.name}'."

    header = f"[{len(matches)} match(es) for '{query}' in '{p.name}' — use read_range() to read context around these lines]\n"
    return header + "\n".join(matches)

  except Exception as exc:
    return f"Error searching file: {exc}"


async def search_files(
  ctx: RunContext[EngineContext],
  directory: str = "~",
  name_pattern: str = "*",
  content_query: str = "",
  file_extensions: str = "",
  max_results: int = 100,
  recursive: bool = True,
) -> list[dict]:
  """
  Search the filesystem for files matching a name pattern and optionally
  containing a text query. Returns a list of matching file info dicts.

  Args:
    directory: Root directory to search from (default '~' for home folder).
    name_pattern: Glob-style filename pattern, e.g. '*.py', 'README*', 'config.*'
                  (default '*' matches everything).
    content_query: Optional text/regex to search inside files. Only plain text
                   files are searched; binary files are skipped.
    file_extensions: Comma-separated list of extensions to filter by, e.g. '.py,.txt'.
                     Leave empty to allow all extensions.
    max_results: Maximum number of results to return (default 100).
    recursive: Search subdirectories recursively (default True).
  """
  try:
    root = _resolve_path(directory)
    if not root.exists():
      return [{"error": f"Directory not found: {root}"}]
    if not root.is_dir():
      return [{"error": f"'{root}' is not a directory."}]

    # Parse extension filter
    ext_filter: set[str] = set()
    if file_extensions.strip():
      for e in file_extensions.split(","):
        e = e.strip().lower()
        if e and not e.startswith("."):
          e = "." + e
        if e:
          ext_filter.add(e)

    # Compile optional content pattern
    content_pattern = None
    if content_query.strip():
      try:
        content_pattern = re.compile(content_query, re.IGNORECASE)
      except re.error as exc:
        return [{"error": f"Invalid content_query regex: {exc}"}]

    glob_fn = root.rglob if recursive else root.glob
    results: list[dict] = []

    for p in glob_fn(name_pattern):
      if len(results) >= max_results:
        break
      if not p.is_file():
        continue

      # Extension filter
      if ext_filter and p.suffix.lower() not in ext_filter:
        continue

      # Content search
      if content_pattern is not None:
        try:
          text = p.read_text(encoding="utf-8", errors="replace")
          match = content_pattern.search(text)
          if not match:
            continue
          first_match_line = text[:match.start()].count("\n") + 1
        except Exception:
          continue
      else:
        first_match_line = None

      try:
        info = p.stat()
        entry: dict = {
          "path": str(p),
          "name": p.name,
          "size_bytes": info.st_size,
          "size_human": _human_size(info.st_size),
          "modified": datetime.datetime.fromtimestamp(info.st_mtime).isoformat(),
        }
        if first_match_line is not None:
          entry["first_match_line"] = first_match_line
        results.append(entry)
      except OSError:
        results.append({"path": str(p), "name": p.name})

    if not results:
      return [{"message": f"No files found matching pattern '{name_pattern}' in '{root}'."}]
    return results

  except Exception as exc:
    return [{"error": f"Error searching files: {exc}"}]


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
    p = _resolve_path(path)
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
    p = _resolve_path(path)
    if p.exists() and not overwrite:
      return f"File already exists: {p}. Set overwrite=True to replace it."
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding="utf-8")
    return f"File created: {p}"
  except Exception as exc:
    return f"Error creating file: {exc}"


async def get_file_info(ctx: RunContext[EngineContext], path: str) -> dict:
  """
  Return metadata about a file or directory: name, size, type, last modified.

  Args:
    path: Path to the file or directory.
  """
  try:
    p = _resolve_path(path)
    if not p.exists():
      return {"error": f"Path not found: {p}"}
    info = p.stat()
    return {
      "name": p.name,
      "path": str(p),
      "type": "directory" if p.is_dir() else "file",
      "size_bytes": info.st_size,
      "size_human": _human_size(info.st_size),
      "modified": datetime.datetime.fromtimestamp(info.st_mtime).isoformat(),
      "created":  datetime.datetime.fromtimestamp(info.st_ctime).isoformat(),
    }
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
    p = _resolve_path(path)
    if not p.exists():
      return f"Path not found: {p}"
    send2trash.send2trash(str(p))
    return f"Moved to trash: {p}"
  except Exception as exc:
    return f"Error moving to trash: {exc}"


def _human_size(n: float) -> str:
  for unit in ("B", "KB", "MB", "GB", "TB"):
    if n < 1024:
      return f"{n:.1f} {unit}"
    n /= 1024
  return f"{n:.1f} PB"


TOOLS = [
  read_file,
  read_range,
  search_in_file,
  search_files,
  list_directory,
  create_file,
  get_file_info,
  move_to_trash,
]
