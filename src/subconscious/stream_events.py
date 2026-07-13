"""
Structured streaming events emitted by ``Engine.stream_chat_events``.

The desktop chat UI consumes these so a single agent turn can be rendered as
multiple message bubbles
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Union


@dataclass
class TextDelta:
  """A chunk of model-generated narration text for the current text block."""
  content: str


@dataclass
class ToolCallStarted:
  """The model has requested a tool call.

  ``args`` is whatever pydantic-ai reports for the call — either a decoded
  ``dict`` or a raw JSON string — captured before the tool executes.
  """
  tool_name: str
  args: Any
  tool_call_id: str


@dataclass
class ToolCallResult:
  """The result of a previously-started tool call.

  ``outcome`` mirrors pydantic-ai's ``ToolReturnPart.outcome`` and is one of
  ``"success"``, ``"failed"`` or ``"denied"``.
  """
  tool_name: str
  content: Any
  tool_call_id: str
  outcome: str = "success"


@dataclass
class ApprovalRequest:
  """The model wants to run a tool that the policy has gated for approval.

  The stream pauses on this event until the UI resolves the decision (via
  ``Engine.resolve_approval``). ``operation`` is ``"query"`` or ``"mutation"``
  so the UI can explain why approval is being asked.
  """
  tool_name: str
  args: Any
  tool_call_id: str
  operation: str = "mutation"


@dataclass
class ApprovalResolved:
  """Emitted after the user approves/denies an ``ApprovalRequest`` so the UI
  can update the corresponding tool bubble."""
  tool_call_id: str
  approved: bool


# Discriminated union of everything the event stream can yield.
StreamEvent = Union[
  TextDelta, ToolCallStarted, ToolCallResult, ApprovalRequest, ApprovalResolved
]


def _coerce_jsonable(value: Any) -> Any:
  """Best-effort convert an arbitrary tool arg/result into JSON-friendly data.

  Tool args arrive as a ``dict`` or a JSON string; results can be strings,
  dicts, lists, or richer objects. We normalize to something ``json.dumps``
  can render so the UI can pretty-print it, falling back to ``str`` for
  anything exotic.
  """
  if value is None or isinstance(value, (dict, list, int, float, bool)):
    return value
  if isinstance(value, str):
    # A JSON string (common for tool args) is decoded so it renders as a
    # structured block rather than an escaped one-liner.
    text = value.strip()
    if text and text[0] in "[{":
      try:
        return json.loads(text)
      except (ValueError, TypeError):
        return value
    return value
  # Dataclasses / pydantic models / other objects: try their dict form, else str.
  for attr in ("model_dump", "dict"):
    method = getattr(value, attr, None)
    if callable(method):
      try:
        return method()
      except Exception:
        break
  return str(value)


def tool_block_to_json(
  tool_name: str,
  args: Any,
  output: Any,
  tool_call_id: str = "",
  outcome: str = "success",
) -> str:
  """Serialize a tool call+result into the JSON stored on a ``role="tool"`` row.

  This is the persisted/display form consumed by ``ToolMessage`` in the UI.
  """
  document = {
    "tool_name": tool_name,
    "tool_call_id": tool_call_id,
    "outcome": outcome,
    "input": _coerce_jsonable(args),
    "output": _coerce_jsonable(output),
  }
  return json.dumps(document, default=str)
