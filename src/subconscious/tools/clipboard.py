"""
Clipboard tools — read from and write to the system clipboard.
Requires: pyperclip  (pip install pyperclip)
"""

from pydantic_ai import RunContext
from . import EngineContext

_MAX_READ_CHARS = 4000


async def read_clipboard(ctx: RunContext[EngineContext]) -> str:
  """
  Read and return the current contents of the system clipboard.
  Returns up to 4000 characters. If the clipboard is empty returns an
  empty string.
  """
  try:
    import pyperclip
    text = pyperclip.paste()
    if len(text) > _MAX_READ_CHARS:
      text = text[:_MAX_READ_CHARS] + f"\n[... clipboard truncated at {_MAX_READ_CHARS} chars]"
    return text or ""
  except ImportError:
    return "Required package missing. Install: pyperclip"
  except Exception as exc:
    return f"Error reading clipboard: {exc}"


async def write_clipboard(ctx: RunContext[EngineContext], text: str) -> str:
  """
  Write text to the system clipboard, replacing whatever was there.

  Args:
    text: The text to place on the clipboard.
  """
  try:
    import pyperclip
    pyperclip.copy(text)
    preview = text[:80] + ("…" if len(text) > 80 else "")
    return f"Clipboard updated ({len(text)} chars): {preview}"
  except ImportError:
    return "Required package missing. Install: pyperclip"
  except Exception as exc:
    return f"Error writing clipboard: {exc}"


TOOLS = [read_clipboard, write_clipboard]
