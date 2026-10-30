"""Model-facing tools for persistent ACP agent sessions.

* ``start_agent_session`` / ``send_agent_session``: invoking an agent. Both follow the user's
  normal approval policy for changes, like ``ask_<agent>``.
* ``end_agent_session``: stops a session. It never asks: ending something can only reduce what is
  running. The idle timeout (see ``acp_sessions``) is the default way a session ends.
* ``list_agent_sessions``: a platform read.

They are offered only while at least one ACP agent is registered or a session is open.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any

from pydantic_ai import RunContext, Tool

from subconscious_engine.approval import UPDATE, ApprovalConfig
from subconscious_engine.services.acp_sessions import (
    AcpSession, AcpSessionError, AcpSessionManager, SessionSpec,
)
from subconscious_engine.services.subagent_progress import SubAgentProgress
from subconscious_engine.tool_events import progress_sink

if TYPE_CHECKING:
    from subconscious_engine.services.configured_tools import ConfiguredRow, ConfiguredToolRuntime

_LOG = logging.getLogger(__name__)

START, SEND, END, LIST = "start_agent_session", "send_agent_session", "end_agent_session", "list_agent_sessions"


def _error(message: str, **extra: Any) -> dict[str, Any]:
    return {"ok": False, "error": message, **extra}


def log_failure(tool: str, problem: Exception) -> dict[str, Any]:
    """Log a refusal and return it as the tool result, so the assistant can react to it."""
    _LOG.info("services.acp_session_tools.%s: %s", tool, problem)
    return _error(str(problem))


class AcpSessionTools:
    def __init__(self, runtime: "ConfiguredToolRuntime", manager: AcpSessionManager) -> None:
        self.runtime = runtime
        self.manager = manager

    async def tools(self, approval: ApprovalConfig, *, reserved: set[str] | frozenset[str] = frozenset()) -> list[Tool[Any]]:
        rows = await self.runtime.acp_rows()
        if not rows and not self.manager.live():
            return []
        names = ", ".join(f"'{row.label}'" for row in rows) or "none registered"
        idle = int(self.manager.idle_default)
        ask = approval.requires_operation(UPDATE)

        async def start_agent_session(agent: str, cwd: str = "", idle_timeout_seconds: int = 0) -> dict[str, Any]:
            row = self._find(rows, agent)
            if isinstance(row, str):
                return _error(row)
            try:
                command, folder, env, permissions = self.runtime.acp_launch(row, cwd)
                session = await self.manager.start(
                    SessionSpec(row.uuid, row.label, command, folder, env, permissions), idle_timeout_seconds)
            except (ValueError, AcpSessionError) as problem:
                return log_failure(START, problem)
            return {"ok": True, **session.info(),
                    "note": "Send messages with send_agent_session; end it with end_agent_session when done."}

        async def send_agent_session(ctx: RunContext[Any], session: str, prompt: str) -> dict[str, Any]:
            if not prompt.strip():
                return _error("prompt is required.")
            try:
                live = self.manager.get(session)
                progress = SubAgentProgress(progress_sink.get(), getattr(ctx, "tool_call_id", None))
                try:
                    result = await live.prompt(prompt, on_update=progress.on_update if progress.active else None)
                finally:
                    await progress.finish()
            except AcpSessionError as problem:
                return log_failure(SEND, problem)
            return {"ok": result.stop_reason != "failed", **result.as_dict(), **self._after(live)}

        async def end_agent_session(session: str) -> dict[str, Any]:
            try:
                return await self.manager.end(session, "the assistant ended it")
            except AcpSessionError as problem:
                return log_failure(END, problem)

        async def list_agent_sessions() -> list[dict[str, Any]]:
            return [live.info() for live in self.manager.live()]

        definitions: list[tuple[Any, str, str, bool, bool]] = [
            (start_agent_session, START, (
                "Start a persistent session with an external agent (ACP). Unlike ask_<agent>, the agent keeps "
                "running and remembers the conversation between messages, so use it for multi-step work. "
                f"`agent` is one of: {names}. Optional `cwd` is the folder it works in. The session ends "
                f"by itself after `idle_timeout_seconds` with nothing in progress (default {idle}); it is not "
                "counted while you wait for the agent to answer. Returns a `session` id. End it with "
                "end_agent_session when you are done."), ask, False),
            (send_agent_session, SEND, (
                "Send a message to an open agent session and wait for its reply. The agent remembers earlier "
                "messages in the session. Returns its reply and the tool calls it made."), ask, True),
            (end_agent_session, END, (
                "End an agent session and stop the agent and everything it started. Do this when the work is "
                "finished; an idle session also ends by itself after its timeout."), False, False),
            (list_agent_sessions, LIST, (
                "List the open agent sessions with their state and how long until each idle timeout."), False, False),
        ]
        built: list[Tool[Any]] = []
        for function, name, description, needs_approval, takes_ctx in definitions:
            if name in reserved:
                continue
            built.append(Tool(function, name=name, description=description, takes_ctx=takes_ctx,
                              requires_approval=needs_approval))
        return built

    @staticmethod
    def _find(rows: "list[ConfiguredRow]", agent: str) -> "ConfiguredRow | str":
        wanted = (agent or "").strip().casefold()
        matches = [row for row in rows if wanted in {row.label.casefold(), row.slug, row.name.casefold(),
                                                     row.uuid.casefold()}]
        if len(matches) == 1:
            return matches[0]
        known = ", ".join(f"'{row.label}'" for row in rows) or "none"
        if not matches:
            return f"No agent named '{agent}'. Available agents: {known}."
        return f"'{agent}' matches several agents; use one of: {known}."

    @staticmethod
    def _after(session: AcpSession) -> dict[str, Any]:
        """Where the session stands after a message, so the assistant knows whether to continue."""
        if session.state == "closed":
            return {"session": session.handle, "sessionState": "ended", "sessionEndedBecause": session.closed_reason}
        return {"session": session.handle, "sessionState": session.state,
                "idleTimeoutSeconds": int(session.idle_seconds)}
