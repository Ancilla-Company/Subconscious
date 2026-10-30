"""The ordered record of one chat turn.

A turn is more than its final answer: the model talks, calls tools, waits for the user to
approve some of them, and may hand work to a sub-agent. ``TurnLog`` listens to the agent's
events and writes each part to the thread as it finishes, in the order it happened:

* a run of model text becomes one ``assistant`` message, closed when the next tool call starts
  (so text said before a tool is kept, not replaced by the final answer);
* each tool call becomes one ``tool`` message when it ends, holding its input, output or
  error, the user's approval decision, how long it took and, for a sub-agent, the steps it
  reported;
* the final answer is one more ``assistant`` message.

Only finished things are stored, so stored messages never change. A turn that is cancelled or
fails still keeps what was said and done (calls still open are stored as ``interrupted``).

The ``tool`` message content is JSON::

    {"v": 2, "toolCallId", "toolName", "title", "kind", "status", "input"?, "output"?, "error"?,
     "approval": "approved" | "denied" | "not_required", "approvalAt"?, "durationMs"?,
     "steps"?: [{"id", "kind", "text"?, "title"?, "tool_kind"?, "status"?}],
     "inputTruncated"?, "outputTruncated"?}

Older turns stored ``{"toolName", "output" | "input", "outcome" | "approval"}`` (no ``v``).
"""

from __future__ import annotations

import json
import logging
import time
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from subconscious_engine.tool_events import (
    EVENT_TYPE, FAILED, MAX_STEPS, PROGRESS_EVENT_TYPE, TERMINAL_STATUSES,
)

_LOG = logging.getLogger(__name__)

RECORD_VERSION = 2
INTERRUPTED = "interrupted"
INTERRUPTED_ERROR = "The turn ended before this tool finished."

Persist = Callable[[str, str], Awaitable[None]]  # (role, content)


@dataclass(slots=True)
class _Call:
    call_id: str
    name: str
    started: float
    title: str | None = None
    kind: str | None = None
    status: str = "pending"
    arguments: Any = None
    arguments_truncated: bool = False
    output: Any = None
    output_truncated: bool = False
    error: str | None = None
    steps: dict[str, dict[str, Any]] = field(default_factory=dict)
    stored: bool = False


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class TurnLog:
    def __init__(self, persist: Persist, *, clock: Callable[[], float] = time.monotonic) -> None:
        self._persist = persist
        self._clock = clock
        self._text: list[str] = []
        self._calls: dict[str, _Call] = {}
        self._approvals: dict[str, tuple[str, str]] = {}
        self._stored_texts: set[str] = set()

    # --- input ---------------------------------------------------------------------------------
    async def record(self, event: dict[str, Any]) -> None:
        """Feed one agent event (``model.delta``, ``tool.call`` or ``tool.progress``)."""
        kind = event.get("type")
        if kind == "model.delta":
            delta = event.get("delta")
            if isinstance(delta, str) and delta:
                self._text.append(delta)
        elif kind == EVENT_TYPE:
            await self._on_tool_call(event)
        elif kind == PROGRESS_EVENT_TYPE:
            self._on_progress(event)

    def note_approval(self, call_id: str, approved: bool) -> None:
        """Remember the user's decision; it is written with the tool call."""
        self._approvals[call_id] = ("approved" if approved else "denied", _now())

    async def finish(self, final_text: str, legacy_records: Sequence[dict[str, Any]] = ()) -> None:
        """Close the turn: store any open calls, then the final answer.

        ``legacy_records`` are the agent's own summary of its tool calls. They are stored only
        when no ``tool.call`` event was seen (a graph node that does not stream), so such a turn
        still leaves a trace.
        """
        if not self._calls:
            for record in legacy_records:
                await self._persist("tool", json.dumps(record, default=str, separators=(",", ":")))
        await self._store_open_calls()
        tail = "".join(self._text)
        self._text.clear()
        # The final answer is authoritative; the streamed tail is the fallback.
        answer = final_text if final_text.strip() else tail
        await self._store_text(answer, skip_repeat=True)

    async def interrupt(self) -> None:
        """The turn was cancelled or failed: keep what was said and done so far."""
        await self._store_open_calls()  # they started before any text that followed them
        await self._flush_text()

    # --- events --------------------------------------------------------------------------------
    async def _on_tool_call(self, event: dict[str, Any]) -> None:
        call_id = event.get("tool_call_id")
        if not isinstance(call_id, str):
            return
        call = self._calls.get(call_id)
        if call is None:
            await self._flush_text()  # text said before a tool call is its own message
            call = _Call(call_id, str(event.get("tool_name") or "tool"), self._clock())
            self._calls[call_id] = call
        for source, target in (("title", "title"), ("kind", "kind"), ("status", "status"),
                               ("error", "error")):
            value = event.get(source)
            if isinstance(value, str) and value:
                setattr(call, target, value)
        if "arguments" in event:
            call.arguments = event["arguments"]
            call.arguments_truncated = bool(event.get("arguments_truncated"))
        if "output" in event:
            call.output = event["output"]
            call.output_truncated = bool(event.get("output_truncated"))
        if call.status in TERMINAL_STATUSES:
            await self._store_call(call)

    def _on_progress(self, event: dict[str, Any]) -> None:
        call = self._calls.get(event.get("tool_call_id"))  # type: ignore[arg-type]
        step = event.get("step")
        if call is None or call.stored or not isinstance(step, dict) or not isinstance(step.get("id"), str):
            return
        if step["id"] in call.steps or len(call.steps) < MAX_STEPS:
            call.steps[step["id"]] = {**call.steps.get(step["id"], {}), **step}

    # --- writing -------------------------------------------------------------------------------
    async def _flush_text(self) -> None:
        text = "".join(self._text)
        self._text.clear()
        await self._store_text(text)

    async def _store_text(self, text: str, *, skip_repeat: bool = False) -> None:
        # ``skip_repeat`` guards the final answer against repeating text already stored this turn
        # (a model that ended with empty output falls back to its earlier text).
        if not text.strip() or (skip_repeat and text.strip() in self._stored_texts):
            return
        self._stored_texts.add(text.strip())
        await self._persist("assistant", text)

    async def _store_open_calls(self) -> None:
        for call in self._calls.values():
            if not call.stored:
                if call.status not in TERMINAL_STATUSES:
                    call.status = INTERRUPTED
                    call.error = call.error or INTERRUPTED_ERROR
                await self._store_call(call)

    async def _store_call(self, call: _Call) -> None:
        if call.stored:
            return
        call.stored = True
        decision = self._approvals.get(call.call_id)
        record: dict[str, Any] = {
            "v": RECORD_VERSION, "toolCallId": call.call_id, "toolName": call.name,
            "title": call.title, "kind": call.kind, "status": call.status,
            "approval": decision[0] if decision else "not_required",
            "durationMs": int((self._clock() - call.started) * 1000),
        }
        if decision:
            record["approvalAt"] = decision[1]
        if call.arguments is not None:
            record["input"] = call.arguments
            if call.arguments_truncated:
                record["inputTruncated"] = True
        if call.output is not None:
            record["output"] = call.output
            if call.output_truncated:
                record["outputTruncated"] = True
        if call.error:
            record["error"] = call.error
        elif call.status == FAILED:
            record["error"] = "The tool call failed."
        if call.steps:
            record["steps"] = list(call.steps.values())
        await self._persist("tool", json.dumps(record, default=str, separators=(",", ":")))
