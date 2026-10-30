"""Structured tool-call events.

The agent loop reports each tool call as it moves through its life (``pending`` while it
waits for approval, ``in_progress`` while it runs, then ``completed`` or ``failed``). The
vocabulary (kinds and statuses) is the one the Agent Client Protocol uses for ``tool_call``
updates, so the same events can drive the engine's own UIs and an ACP ``session/update``
stream without a second translation layer.

Events are plain dicts with snake_case keys, like every other engine frame:

``{"type": "tool.call", "tool_call_id", "tool_name", "title", "kind", "status",
   "arguments"?, "output"?, "error"?}``
"""

from __future__ import annotations

import json
import logging
from collections.abc import Awaitable, Callable
from contextvars import ContextVar
from typing import Any

from subconscious_engine.approval import CREATE, DELETE, READ, UPDATE, classify_operation

_LOG = logging.getLogger(__name__)

EVENT_TYPE = "tool.call"

PENDING = "pending"
IN_PROGRESS = "in_progress"
COMPLETED = "completed"
FAILED = "failed"
TERMINAL_STATUSES = frozenset({COMPLETED, FAILED})

# ACP ToolKind values this engine can produce.
KIND_READ = "read"
KIND_EDIT = "edit"
KIND_DELETE = "delete"
KIND_MOVE = "move"
KIND_SEARCH = "search"
KIND_EXECUTE = "execute"
KIND_FETCH = "fetch"
KIND_OTHER = "other"

# Payloads can be large (file contents, command output). Clients get a bounded preview;
# the complete result is still stored in the thread as a ``tool`` message.
MAX_PAYLOAD_CHARS = 8000

_SEARCH_PREFIXES = ("search_", "find_", "grep_", "lookup_")
_FETCH_PREFIXES = ("fetch_", "download_")
_EXECUTE_PREFIXES = ("run_", "exec_", "execute_")
_EXECUTE_NAMES = frozenset({"run_command", "run_terminal", "terminal", "shell", "bash"})
_MOVE_PREFIXES = ("move_", "rename_")


def base_tool_name(tool_name: str) -> str:
    """The tool's own name; MCP and remote tools are prefixed ``<server>__<tool>``."""
    return tool_name.rpartition("__")[2] or tool_name


def tool_kind(tool_name: str, operation: str | None = None) -> str:
    """Map a tool to an ACP ``ToolKind``.

    The name is checked first (search, fetch, execute and move have no CRUD equivalent),
    then the approval operation decides between read, edit and delete.
    """
    name = base_tool_name(tool_name)
    if name.startswith(_SEARCH_PREFIXES):
        return KIND_SEARCH
    if name.startswith(_FETCH_PREFIXES):
        return KIND_FETCH
    if name in _EXECUTE_NAMES or name.startswith(_EXECUTE_PREFIXES):
        return KIND_EXECUTE
    if name.startswith(_MOVE_PREFIXES):
        return KIND_MOVE
    resolved = operation or classify_operation(tool_name)
    if resolved == READ:
        return KIND_READ
    if resolved == DELETE:
        return KIND_DELETE
    if resolved in (CREATE, UPDATE):
        return KIND_EDIT
    return KIND_OTHER


def tool_title(tool_name: str, arguments: dict[str, Any] | None = None) -> str:
    """A short human readable title, e.g. ``read filesystem file: C:\\notes.txt``."""
    label = base_tool_name(tool_name).replace("_", " ").strip() or tool_name
    for key in ("path", "file", "filename", "source", "url", "query", "command"):
        value = (arguments or {}).get(key)
        if isinstance(value, str) and value.strip():
            detail = " ".join(value.split())
            return f"{label}: {detail if len(detail) <= 80 else detail[:79] + '…'}"
    return label


def bounded(value: Any, limit: int = MAX_PAYLOAD_CHARS) -> tuple[Any, bool]:
    """``value`` if its JSON form fits in ``limit`` characters, else a truncated string.

    Returns ``(value, truncated)``.
    """
    try:
        text = value if isinstance(value, str) else json.dumps(value, default=str, ensure_ascii=False)
    except (TypeError, ValueError):
        _LOG.debug("tool_events.bounded: value is not JSON serialisable; using str()", exc_info=True)
        text = str(value)
    if len(text) <= limit:
        return value, False
    return text[:limit], True


PROGRESS_EVENT_TYPE = "tool.progress"

# Set by the transport for the running turn. A tool that does long work on its own (an ACP
# sub-agent) calls it to report what it is doing; the turn forwards those events to the chat
# and records them with the tool call.
ProgressSink = Callable[[dict[str, Any]], Awaitable[None]]
progress_sink: ContextVar[ProgressSink | None] = ContextVar("tool_progress_sink", default=None)

# Bounds so a chatty sub-agent cannot grow a stored message without limit.
MAX_STEP_TEXT = 4000
MAX_STEPS = 200


def tool_progress_event(tool_call_id: str, step: dict[str, Any]) -> dict[str, Any]:
    """One ``tool.progress`` event: a step a running tool reports about itself.

    ``step`` has ``id`` (a repeat of an id replaces the earlier step), ``kind`` (``message``
    or ``tool``), and optionally ``text``, ``title``, ``tool_kind`` and ``status``.
    """
    clean = {key: value for key, value in step.items() if value is not None}
    text = clean.get("text")
    if isinstance(text, str) and len(text) > MAX_STEP_TEXT:
        clean["text"] = text[:MAX_STEP_TEXT]
        clean["truncated"] = True
    return {"type": PROGRESS_EVENT_TYPE, "tool_call_id": tool_call_id, "step": clean}


def tool_call_event(
    *,
    tool_call_id: str,
    tool_name: str,
    status: str,
    arguments: dict[str, Any] | None = None,
    output: Any = None,
    error: str | None = None,
    title: str | None = None,
    operation: str | None = None,
) -> dict[str, Any]:
    """Build one ``tool.call`` event. Optional fields are left out when not known."""
    event: dict[str, Any] = {
        "type": EVENT_TYPE,
        "tool_call_id": tool_call_id,
        "tool_name": tool_name,
        "title": title or tool_title(tool_name, arguments),
        "kind": tool_kind(tool_name, operation),
        "status": status,
    }
    if arguments is not None:
        shown, truncated = bounded(arguments)
        event["arguments"] = shown
        if truncated:
            event["arguments_truncated"] = True
    if output is not None:
        shown, truncated = bounded(output)
        event["output"] = shown
        if truncated:
            event["output_truncated"] = True
    if error:
        event["error"] = error
    return event
