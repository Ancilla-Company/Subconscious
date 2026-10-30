"""Long-lived sessions with external ACP agents.

A one-shot ``ask_<agent>`` call starts a fresh agent, sends one prompt and stops it. Some work
needs a conversation: an agent that keeps its context between messages, or a task that takes
several instructions. A session keeps the agent process running between prompts.

Lifetime:

* Starting a session launches the agent process. That process is infrastructure and needs no
  separate approval; the assistant's *invocation* of the agent (``start_agent_session`` and each
  ``send_agent_session``) is what the user approves, under the normal approval policy.
* While a prompt is in flight the engine is waiting for the agent and no timer runs.
* Whenever the session is idle, a timer runs. When it expires the session ends. Every
  prompt restarts the timer.
* The assistant can end a session at any time (``end_agent_session``).
* A session also ends when the agent exits, when a prompt times out (an agent that stopped
  answering is not reused), when its registry row changes or is deleted, and when the engine
  shuts down.

Ending a session stops the agent and every process it started (see ``process_tree``).
"""

from __future__ import annotations

import asyncio
import logging
import secrets
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

from subconscious_engine.logging_setup import spawn_logged
from subconscious_engine.services.acp_client import (
    AcpConnection, AcpError, AcpRunResult, UpdateCallback, absolute_path, open_session, prompt_session,
)

_LOG = logging.getLogger(__name__)

DEFAULT_IDLE_SECONDS = 600.0
MIN_IDLE_SECONDS = 30.0
MAX_IDLE_SECONDS = 3600.0
MAX_SESSIONS = 4
PROMPT_TIMEOUT_SECONDS = 600.0


class AcpSessionError(Exception):
    """A session problem worded for the assistant (it is returned as a tool result)."""


@dataclass(frozen=True, slots=True)
class SessionSpec:
    """What it takes to launch one agent, resolved from its registry row."""

    row_uuid: str
    label: str
    command: Sequence[str]
    cwd: str | None
    env: Mapping[str, str] | None
    permissions: str


class AcpSession:
    def __init__(self, handle: str, spec: SessionSpec, connection: AcpConnection, acp_session_id: str,
                 idle_seconds: float, manager: "AcpSessionManager", prompt_timeout: float) -> None:
        self.handle = handle
        self.spec = spec
        self.idle_seconds = idle_seconds
        self.prompts = 0
        self.state = "idle"  # idle | busy | closed
        self.closed_reason: str | None = None
        self.started_at = datetime.now(timezone.utc)
        self._started = time.monotonic()
        self._connection = connection
        self._acp_session_id = acp_session_id
        self._manager = manager
        self._prompt_timeout = prompt_timeout
        self._lock = asyncio.Lock()
        self._ending = False
        self._done = asyncio.Event()
        self._idle_handle: asyncio.TimerHandle | None = None
        self._idle_deadline: float | None = None
        self._watcher = spawn_logged(self._watch())
        self._arm_idle()

    # --- status ----------------------------------------------------------------------------
    def info(self) -> dict[str, Any]:
        info: dict[str, Any] = {
            "session": self.handle, "agent": self.spec.label, "state": self.state,
            "prompts": self.prompts, "permissions": self.spec.permissions,
            "idleTimeoutSeconds": int(self.idle_seconds),
            "cwd": absolute_path(self.spec.cwd), "startedAt": self.started_at.isoformat(timespec="seconds")}
        if self._idle_deadline is not None and self.state == "idle":
            info["idleExpiresInSeconds"] = max(0, int(self._idle_deadline - asyncio.get_running_loop().time()))
        if self.closed_reason:
            info["endedBecause"] = self.closed_reason
        return info

    # --- idle timer ------------------------------------------------------------------------
    def _arm_idle(self) -> None:
        self._disarm_idle()
        if self.state == "closed":
            return
        loop = asyncio.get_running_loop()
        self._idle_deadline = loop.time() + self.idle_seconds
        self._idle_handle = loop.call_later(self.idle_seconds, self._idle_expired)

    def _disarm_idle(self) -> None:
        if self._idle_handle is not None:
            self._idle_handle.cancel()
        self._idle_handle = None
        self._idle_deadline = None

    def _idle_expired(self) -> None:
        if self.state == "idle":  # a prompt that just started has already disarmed the timer
            spawn_logged(self.end(f"it was idle for {int(self.idle_seconds)} seconds"))

    async def _watch(self) -> None:
        await self._connection.exited.wait()
        if not self._ending:
            await self.end("the agent exited")

    # --- use -------------------------------------------------------------------------------
    async def prompt(self, text: str, *, on_update: UpdateCallback | None = None) -> AcpRunResult:
        """Send one prompt and wait for the agent. The idle timer is paused while it runs."""
        if self.state == "closed":
            raise AcpSessionError(f"Session {self.handle} has ended ({self.closed_reason}). Start a new one.")
        if self._lock.locked():
            raise AcpSessionError(f"Session {self.handle} is still working on an earlier prompt.")
        async with self._lock:
            if self.state == "closed":
                raise AcpSessionError(f"Session {self.handle} has ended ({self.closed_reason}). Start a new one.")
            self._disarm_idle()
            self.state = "busy"
            self.prompts += 1
            try:
                result = await prompt_session(self._connection, self._acp_session_id, text,
                                              timeout=self._prompt_timeout, on_update=on_update)
            except BaseException:
                # Cancelled or crashed mid-prompt: the agent was asked to stop; keep the session
                # only if the agent is still there.
                if self._connection.alive and not self._ending:
                    self.state = "idle"
                    self._arm_idle()
                raise
            if result.stop_reason == "failed" and (
                    not self._connection.alive or "timed out" in (result.error or "")):
                reason = "the agent stopped answering" if self._connection.alive else "the agent exited"
                await self.end(reason)
            elif not self._ending:
                self.state = "idle"
                self._arm_idle()
            return result

    async def end(self, reason: str) -> dict[str, Any]:
        """Stop the agent and everything it started. Safe to call more than once."""
        if self._ending:
            await self._done.wait()
            return self._summary()
        self._ending = True
        self._disarm_idle()
        self.state = "closed"
        self.closed_reason = reason
        self._manager.forget(self)  # no longer usable, and no longer counted against the limit
        try:
            await self._connection.close(self._acp_session_id)
        except Exception:
            _LOG.warning("services.acp_sessions.end: closing '%s' failed", self.spec.label, exc_info=True)
        finally:
            self._manager.forget(self)
            self._done.set()
            if self._watcher is not asyncio.current_task():
                self._watcher.cancel()
        _LOG.info("services.acp_sessions: session %s with '%s' ended: %s", self.handle, self.spec.label, reason)
        return self._summary()

    def _summary(self) -> dict[str, Any]:
        return {"ok": True, "session": self.handle, "agent": self.spec.label, "prompts": self.prompts,
                "endedBecause": self.closed_reason,
                "lifetimeSeconds": int(time.monotonic() - self._started)}


class AcpSessionManager:
    def __init__(self, *, idle_default: float = DEFAULT_IDLE_SECONDS, idle_min: float = MIN_IDLE_SECONDS,
                 idle_max: float = MAX_IDLE_SECONDS, max_sessions: int = MAX_SESSIONS,
                 prompt_timeout: float = PROMPT_TIMEOUT_SECONDS) -> None:
        self.idle_default, self.idle_min, self.idle_max = idle_default, idle_min, idle_max
        self.max_sessions = max_sessions
        self.prompt_timeout = prompt_timeout
        self._sessions: dict[str, AcpSession] = {}

    def clamp_idle(self, seconds: float | None) -> float:
        if seconds is None or seconds <= 0:
            return self.idle_default
        return min(max(float(seconds), self.idle_min), self.idle_max)

    async def start(self, spec: SessionSpec, idle_seconds: float | None = None) -> AcpSession:
        if len(self._sessions) >= self.max_sessions:
            open_now = ", ".join(f"{s.handle} ({s.spec.label})" for s in self._sessions.values())
            raise AcpSessionError(f"At most {self.max_sessions} agent sessions can be open at once. "
                                  f"End one first: {open_now}.")
        directory = absolute_path(spec.cwd)
        connection = AcpConnection(spec.command, directory, spec.env, spec.permissions, None)
        session_id: str | None = None
        try:
            session_id, _ = await open_session(connection, directory)
        except AcpError as error:
            await connection.close(session_id)
            raise AcpSessionError(f"Could not start '{spec.label}': {error}") from error
        except BaseException:
            await connection.close(session_id)
            raise
        handle = f"acp_{secrets.token_hex(4)}"
        session = AcpSession(handle, spec, connection, session_id, self.clamp_idle(idle_seconds), self,
                             self.prompt_timeout)
        self._sessions[handle] = session
        _LOG.info("services.acp_sessions: session %s started with '%s' (idle timeout %ds)",
                  handle, spec.label, int(session.idle_seconds))
        return session

    def get(self, handle: str) -> AcpSession:
        session = self._sessions.get((handle or "").strip().casefold())
        if session is None:
            known = ", ".join(self._sessions) or "none open"
            raise AcpSessionError(f"No open agent session '{handle}'. It may have ended; open sessions: {known}.")
        return session

    def forget(self, session: AcpSession) -> None:
        self._sessions.pop(session.handle, None)

    def live(self) -> list[AcpSession]:
        return list(self._sessions.values())

    async def end(self, handle: str, reason: str) -> dict[str, Any]:
        return await self.get(handle).end(reason)

    async def end_for_row(self, row_uuid: str, reason: str) -> None:
        for session in self.live():
            if session.spec.row_uuid == row_uuid:
                await session.end(reason)

    async def close_all(self) -> None:
        await asyncio.gather(*(s.end("the engine is shutting down") for s in self.live()),
                             return_exceptions=True)
