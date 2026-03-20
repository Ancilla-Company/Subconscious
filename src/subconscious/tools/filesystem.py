"""
Filesystem tools — read files, list directories, create files, move to trash.
Operations are sandboxed: paths outside the user's home directory are blocked
unless the engine context data_dir is explicitly set wider.
"""
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

_MAX_READ_SIZE = 100_000  # 100 KB limit


def _safe_path(raw: str) -> pathlib.Path:
  """Resolve and return the path. Raises ValueError if obviously unsafe."""
  p = pathlib.Path(raw).expanduser().resolve()
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
  Read and return the content of a file. Supports text (.txt, .md, .py, etc.), 
  Word documents (.docx), Excel spreadsheets (.xlsx), and PDF files (.pdf).
  Limited to files inside the user's home directory for safety.
  Returns up to 100 KB of content; larger files/extractions are truncated.

  Args:
    path: Absolute or ~ relative path to the file.
    encoding: Text encoding (default utf-8, used for plain text files).
  """
  try:
    p = _safe_path(path)
    if not p.exists():
      return f"File not found: {p}"
    if not p.is_file():
      return f"'{p}' is not a file."

    ext = p.suffix.lower()
    text = ""
    
    if ext == ".docx":
      text = _read_docx(p)
    elif ext == ".xlsx":
      text = _read_xlsx(p)
    elif ext == ".pdf":
      text = _read_pdf(p)
    else:
      # Default to plain text reading
      raw = p.read_bytes()
      try:
        text = raw.decode(encoding)
      except UnicodeDecodeError:
        return f"File appears to be binary or not {encoding} encoded. Use a supported document extension (.docx, .xlsx, .pdf) or a text format."

    size = len(text)
    if size > _MAX_READ_SIZE:
      text = text[:_MAX_READ_SIZE] + f"\n\n[... content truncated — showed {_MAX_READ_SIZE} of {size} characters]"

    return text
  except ValueError as exc:
    return str(exc)
  except Exception as exc:
    return f"Error reading file: {exc}"


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
