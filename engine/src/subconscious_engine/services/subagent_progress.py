"""Turns an ACP agent's ``session/update`` notifications into ``tool.progress`` steps.

The agent's reply text arrives as many small chunks. They are gathered into one ``message``
step that is re-sent at most every ``MIN_INTERVAL`` seconds (and once more at the end), so the
chat sees the sub-agent working without a frame per chunk. Each ACP tool call becomes a
``tool`` step that is updated in place as its status changes.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from typing import Any

from subconscious_engine.tool_events import MAX_STEP_TEXT, MAX_STEPS, ProgressSink, tool_progress_event

MIN_INTERVAL = 0.4


class SubAgentProgress:
    def __init__(self, sink: ProgressSink | None, tool_call_id: str | None, *,
                 clock: Callable[[], float] = time.monotonic) -> None:
        self._sink = sink if tool_call_id else None
        self._call_id = tool_call_id or ""
        self._clock = clock
        self._message_index = 0
        self._chunks: list[str] = []
        self._sent_length = 0
        self._last_sent = float("-inf")
        self._steps = 0

    @property
    def active(self) -> bool:
        return self._sink is not None

    async def on_update(self, update: dict[str, Any]) -> None:
        if self._sink is None:
            return
        kind = update.get("sessionUpdate")
        if kind == "agent_message_chunk":
            content = update.get("content")
            text = content.get("text") if isinstance(content, dict) else None
            if isinstance(text, str) and text:
                if sum(map(len, self._chunks)) < MAX_STEP_TEXT:  # later text would be cut off anyway
                    self._chunks.append(text)
                await self._send_message(force=False)
        elif kind in ("tool_call", "tool_call_update"):
            call_id = update.get("toolCallId")
            if not isinstance(call_id, str):
                return
            await self._close_message()
            if self._steps >= MAX_STEPS:
                return
            self._steps += 1
            title = update.get("title") if isinstance(update.get("title"), str) else None
            tool_kind = update.get("kind") if isinstance(update.get("kind"), str) else None
            status = update.get("status") if isinstance(update.get("status"), str) else None
            await self._sink(tool_progress_event(self._call_id, {
                "id": f"tool-{call_id}", "kind": "tool", "title": title,
                "tool_kind": tool_kind, "status": status}))

    async def finish(self) -> None:
        await self._send_message(force=True)

    async def _close_message(self) -> None:
        """A tool call ends the current message step; the next reply text starts a new one."""
        if not self._chunks:
            return
        await self._send_message(force=True)
        self._chunks.clear()
        self._sent_length = 0
        self._message_index += 1

    async def _send_message(self, *, force: bool) -> None:
        if self._sink is None or not self._chunks:
            return
        text = "".join(self._chunks)
        now = self._clock()
        if len(text) == self._sent_length or (not force and now - self._last_sent < MIN_INTERVAL):
            return
        self._sent_length = len(text)
        self._last_sent = now
        await self._sink(tool_progress_event(self._call_id, {
            "id": f"message-{self._message_index}", "kind": "message", "text": text}))
