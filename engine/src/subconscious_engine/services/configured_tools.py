"""Runtime for user-configured tools: MCP servers (stdio / streamable HTTP) and CLI commands.

Registry rows of type ``mcp`` and ``cli`` with status ``active`` become model-callable tools
on every chat turn:

* ``cli``: one tool ``run_<slug>(arguments: str)``. The command is started with
  ``create_subprocess_exec`` (never a shell), with the configured fixed arguments first.
* ``mcp``: one tool ``<slug>__<mcp tool>`` per tool the server advertises. Servers keep
  state between turns (the Kiro MCP server holds runs in memory), so each registry row owns
  ONE long-lived connection, started lazily, health-checked before reuse, restarted if its
  process died, and closed when the row changes, is deleted, or the engine shuts down.

The MCP SDK uses anyio context managers that must be entered and exited in the same task, so
every connection runs in a dedicated background task that owns them for its whole life.
A server that cannot start never breaks a turn: it is skipped and logged as a warning.

Environment variables configured for a stdio server are stored in plain text and are NOT
secret; secrets belong in the encrypted api_key headers of an HTTP server.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import shlex
import shutil
import tempfile
from collections.abc import Callable, Collection
from contextlib import AsyncExitStack
from dataclasses import dataclass, field
from datetime import timedelta
from pathlib import Path
from typing import Any

import httpx
from mcp import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client
from mcp.client.streamable_http import streamablehttp_client
from mcp.shared.exceptions import McpError
from pydantic_ai import RunContext, Tool
from sqlalchemy import select

from subconscious_engine.approval import UPDATE, READ, ApprovalConfig, classify_operation
from subconscious_engine.connection_log import connection_event, connection_problem
from subconscious_engine.logging_setup import logged_suppress, spawn_logged
from subconscious_engine.services.oauth import (
    AuthorizationRequired,
    OAuthBroker,
    OAuthNotReady,
    build_provider,
)
from subconscious_engine.services.acp_client import AcpError, probe_acp_agent, run_acp_agent
from subconscious_engine.services.acp_session_tools import AcpSessionTools
from subconscious_engine.services.acp_sessions import AcpSessionManager
from subconscious_engine.services.subagent_progress import SubAgentProgress
from subconscious_engine.services.tool_registry import parse_tool_config
from subconscious_engine.storage.models import ToolRegistryRecord
from subconscious_engine.tool_events import progress_sink

_LOG = logging.getLogger(__name__)

MAX_FUNCTION_NAME = 64
NAME_SEPARATOR = "__"
CLI_TIMEOUT_SECONDS = 120.0
CLI_OUTPUT_LIMIT = 20000
MCP_START_TIMEOUT_SECONDS = 60.0
MCP_CALL_TIMEOUT_SECONDS = 300.0
MCP_PING_TIMEOUT_SECONDS = 5.0
CONFIGURED_TYPES = ("mcp", "cli", "acp")
ACP_TIMEOUT_SECONDS = 600.0
NOT_EXECUTED_ERROR = "This tool type is not executed by the engine."
SIGN_IN_REQUIRED = "Sign-in required."
AUTHORIZE_WAIT_SECONDS = 15.0


def log_tool_problem(event: str, **fields: Any) -> None:
    """Log a connection/tool failure at WARNING (call from an ``except`` block)."""
    connection_problem(event, exc_info=True, **fields)


def describe_error(error: BaseException) -> str:
    """A concise one-line message, unwrapping anyio/asyncio exception groups."""
    seen = 0
    while isinstance(error, BaseExceptionGroup) and error.exceptions and seen < 8:
        error = error.exceptions[0]
        seen += 1
    text = str(error).strip() or error.__class__.__name__
    return text if len(text) <= 500 else text[:499] + "…"


def slugify(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", value.casefold()).strip("_") or "tool"


def sanitize_name(value: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_-]", "_", value) or "tool"


def unique_name(name: str, used: set[str]) -> str:
    """Make ``name`` unique within ``used`` (and <= 64 chars), then reserve it."""
    name = name[:MAX_FUNCTION_NAME]
    candidate, counter = name, 1
    while candidate in used:
        counter += 1
        suffix = f"_{counter}"
        candidate = name[:MAX_FUNCTION_NAME - len(suffix)] + suffix
    used.add(candidate)
    return candidate


def resolve_command(command: str, cwd: str | None = None) -> str | None:
    """Absolute/relative path that exists, else whatever ``shutil.which`` finds."""
    expanded = Path(command).expanduser()
    if expanded.is_absolute() or os.sep in command or "/" in command:
        candidate = expanded if expanded.is_absolute() else Path(cwd or ".") / expanded
        return str(candidate) if candidate.exists() else None
    return shutil.which(command, path=None)


def split_arguments(arguments: str) -> list[str]:
    """Split a command-line string without a shell. On Windows (non-POSIX shlex) the quotes
    around a token are kept by shlex, so they are stripped here."""
    posix = os.name != "nt"
    tokens = shlex.split(arguments, posix=posix)
    if posix:
        return tokens
    return [t[1:-1] if len(t) >= 2 and t[0] == t[-1] and t[0] in "\"'" else t for t in tokens]


@dataclass(frozen=True, slots=True)
class ConfiguredRow:
    """Detached snapshot of a registry row (safe to use after its DB session closes)."""

    uuid: str
    name: str
    alias: str | None
    description: str | None
    tool_type: str
    endpoint_url: str | None
    status: str
    updated_at: str
    config: dict[str, Any]
    auth_type: str | None = None

    @property
    def is_oauth(self) -> bool:
        return self.tool_type == "mcp" and self.endpoint_url is not None and self.auth_type == "oauth"

    @property
    def label(self) -> str:
        return self.alias or self.name

    @property
    def slug(self) -> str:
        return slugify(self.label)

    @property
    def transport(self) -> str | None:
        if self.tool_type != "mcp":
            return None
        return "http" if self.endpoint_url else "stdio"

    @classmethod
    def from_record(cls, record: ToolRegistryRecord) -> "ConfiguredRow":
        return cls(record.uuid, record.name, record.alias, record.description, record.tool_type,
                   record.endpoint_url, record.status, str(record.updated_at),
                   parse_tool_config(record.config_json), record.auth_type)


@dataclass(slots=True)
class _Entry:
    """One model-visible tool before name de-duplication."""

    base_name: str
    description: str
    operation: str
    build: Callable[[str, ApprovalConfig], Tool[Any]]


@dataclass(slots=True)
class _Capture:
    data: bytearray = field(default_factory=bytearray)
    dropped: bool = False


async def _drain(stream: asyncio.StreamReader | None, capture: _Capture, limit: int) -> None:
    """Read to EOF, keeping at most ``limit`` bytes (so a chatty process never blocks)."""
    if stream is None:
        return
    while True:
        chunk = await stream.read(65536)
        if not chunk:
            return
        room = limit - len(capture.data)
        if room > 0:
            capture.data += chunk[:room]
        if len(chunk) > max(room, 0):
            capture.dropped = True


def _tool_text(result: Any) -> str:
    """Join an MCP result's text blocks; fall back to structuredContent."""
    parts: list[str] = []
    for block in result.content or []:
        text = getattr(block, "text", None)
        if isinstance(text, str):
            parts.append(text)
        elif getattr(block, "type", None) == "image":
            parts.append("[image content omitted]")
        elif getattr(block, "type", None) == "audio":
            parts.append("[audio content omitted]")
        elif getattr(block, "type", None) == "resource":
            resource = getattr(block, "resource", None)
            inner = getattr(resource, "text", None)
            parts.append(inner if isinstance(inner, str) else "[binary resource omitted]")
    text = "\n".join(parts)
    if not text.strip() and getattr(result, "structuredContent", None) is not None:
        return json.dumps(result.structuredContent, default=str)
    return text


class _McpConnection:
    """One live MCP server connection, owned by a dedicated task."""

    def __init__(self, row: ConfiguredRow, headers: dict[str, str] | None, *,
                 call_timeout: float, auth: httpx.Auth | None = None) -> None:
        self.row = row
        self.headers = headers
        self.auth = auth
        # Set when an OAuth tool needs a human to sign in (non-interactive start or token expiry).
        self.auth_required = False
        self.call_timeout = call_timeout
        self.session: ClientSession | None = None
        self.tools: list[Any] = []
        self.stderr_tail = ""
        self._ready: asyncio.Future[None] | None = None
        self._stop = asyncio.Event()
        self._task: asyncio.Future[Any] | None = None
        self._closing = False

    @property
    def alive(self) -> bool:
        return self.session is not None and self._task is not None and not self._task.done()

    async def start(self, timeout: float) -> None:
        self._ready = asyncio.get_running_loop().create_future()
        self._task = spawn_logged(self._run(), name=f"mcp:{self.row.label}")
        try:
            await asyncio.wait_for(self._ready, timeout)
        except BaseException:
            await self.close(log=False)
            raise

    def signal_auth_required(self) -> None:
        """A sign-in is needed: fail a pending start immediately instead of timing out."""
        self.auth_required = True
        if self._ready is not None and not self._ready.done():
            self._ready.set_exception(AuthorizationRequired(SIGN_IN_REQUIRED))

    async def healthy(self) -> bool:
        session = self.session
        if session is None or not self.alive:
            return False
        try:
            await asyncio.wait_for(session.send_ping(), MCP_PING_TIMEOUT_SECONDS)
        except Exception as error:
            log_tool_problem("mcp.server.dropped", uuid=self.row.uuid, alias=self.row.label,
                             transport=self.row.transport, error=describe_error(error))
            return False
        return True

    async def close(self, *, log: bool = True) -> None:
        self._closing = True
        self._stop.set()
        task = self._task
        if task is not None and not task.done():
            await asyncio.wait({task}, timeout=10)
            if not task.done():
                task.cancel()
                await asyncio.wait({task}, timeout=5)
        self.session = None
        if log:
            connection_event("mcp.server.stopped", uuid=self.row.uuid, alias=self.row.label,
                             transport=self.row.transport)

    async def call(self, name: str, arguments: dict[str, Any]) -> str:
        session = self.session
        if session is None or not self.alive:
            raise RuntimeError(f"MCP server '{self.row.label}' is not running; it restarts on the next turn.")
        try:
            result = await session.call_tool(
                name, arguments, read_timeout_seconds=timedelta(seconds=self.call_timeout))
        except McpError as error:
            raise RuntimeError(f"MCP server '{self.row.label}' failed: {describe_error(error)}") from error
        except Exception as error:
            log_tool_problem("mcp.server.dropped", uuid=self.row.uuid, alias=self.row.label,
                             transport=self.row.transport, error=describe_error(error))
            self.session = None  # forces a restart on the next turn
            raise RuntimeError(
                f"The connection to MCP server '{self.row.label}' was lost: {describe_error(error)}") from error
        text = _tool_text(result)
        if result.isError:
            raise RuntimeError(text or f"MCP tool '{name}' failed.")
        return text

    # --- the owning task ---------------------------------------------------------------------
    async def _run(self) -> None:
        row = self.row
        errlog = tempfile.TemporaryFile("w+", encoding="utf-8", errors="replace") \
            if row.transport == "stdio" else None
        connected = False
        try:
            async with AsyncExitStack() as stack:
                if row.transport == "http":
                    streams = await stack.enter_async_context(
                        streamablehttp_client(row.endpoint_url or "", headers=self.headers, auth=self.auth))
                else:
                    config = row.config
                    env = {**os.environ, **{str(k): str(v) for k, v in (config.get("env") or {}).items()}}
                    params = StdioServerParameters(
                        command=str(config.get("command") or ""),
                        args=[str(item) for item in (config.get("args") or [])],
                        env=env, cwd=config.get("cwd") or None)
                    streams = await stack.enter_async_context(stdio_client(params, errlog=errlog))
                session = await stack.enter_async_context(ClientSession(streams[0], streams[1]))
                await session.initialize()
                tools: list[Any] = []
                cursor: str | None = None
                while True:
                    page = await session.list_tools(cursor)
                    tools.extend(page.tools)
                    cursor = page.nextCursor
                    if not cursor or len(tools) > 1000:
                        break
                self.tools = tools
                self.session = session
                connected = True
                connection_event("mcp.server.connected", uuid=row.uuid, alias=row.label,
                                 transport=row.transport, tools=len(tools))
                if self._ready is not None and not self._ready.done():
                    self._ready.set_result(None)
                await self._stop.wait()
        except asyncio.CancelledError:
            _LOG.debug("services.configured_tools._McpConnection._run: cancelled", exc_info=True)
            raise
        except Exception as error:
            message = describe_error(error)
            if self.auth_required:
                connection_event("mcp.server.needs_sign_in", uuid=row.uuid, alias=row.label,
                                 transport=row.transport)
                if self._ready is not None and not self._ready.done():
                    self._ready.set_exception(AuthorizationRequired(SIGN_IN_REQUIRED))
                return
            if errlog is not None:
                self.stderr_tail = self._read_tail(errlog)
                if self.stderr_tail and not connected:
                    message = f"{message} (server output: {self.stderr_tail})"
            if connected and not self._closing:
                log_tool_problem("mcp.server.dropped", uuid=row.uuid, alias=row.label,
                                 transport=row.transport, error=message)
            else:
                log_tool_problem("mcp.server.failed", uuid=row.uuid, alias=row.label,
                                 transport=row.transport, error=message)
            if self._ready is not None and not self._ready.done():
                self._ready.set_exception(RuntimeError(message))
        finally:
            self.session = None
            if errlog is not None:
                with logged_suppress(Exception):
                    errlog.close()
            if self._ready is not None and not self._ready.done():
                self._ready.set_exception(RuntimeError("The MCP connection closed before it was ready."))

    @staticmethod
    def _read_tail(errlog: Any) -> str:
        try:
            errlog.flush()
            errlog.seek(0)
            return " ".join(errlog.read()[-400:].split())
        except (OSError, ValueError):
            _LOG.debug("services.configured_tools._McpConnection._read_tail: unreadable", exc_info=True)
            return ""


class ConfiguredToolRuntime:
    """Builds per-turn tools from the tool registry and owns the long-lived MCP connections."""

    def __init__(self, database: Any, credentials: Any, *, cli_timeout: float = CLI_TIMEOUT_SECONDS,
                 mcp_start_timeout: float = MCP_START_TIMEOUT_SECONDS,
                 mcp_call_timeout: float = MCP_CALL_TIMEOUT_SECONDS,
                 oauth_broker: OAuthBroker | None = None,
                 acp_timeout: float = ACP_TIMEOUT_SECONDS) -> None:
        self.acp_timeout = acp_timeout
        self.database = database
        self.credentials = credentials
        self.oauth_broker = oauth_broker
        # "needs_auth" | "error" per tool uuid, set by the last failed start attempt.
        self._states: dict[str, str] = {}
        # Interactive sign-in flows in flight, per tool uuid.
        self._flows: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self._signing_in: set[str] = set()
        self.cli_timeout = cli_timeout
        self.mcp_start_timeout = mcp_start_timeout
        self.mcp_call_timeout = mcp_call_timeout
        self._connections: dict[str, _McpConnection] = {}
        self._locks: dict[str, asyncio.Lock] = {}
        # Persistent sessions with ACP agents (start/send/end_agent_session).
        self.acp_sessions = AcpSessionManager(prompt_timeout=acp_timeout)
        self._session_tools = AcpSessionTools(self, self.acp_sessions)

    # --- public API --------------------------------------------------------------------------
    async def tools_for_turn(self, approval: ApprovalConfig, *,
                             reserved: Collection[str] = ()) -> list[Tool[Any]]:
        """Tools for every active mcp/cli registry row; unusable servers are skipped and logged."""
        rows = await self._rows(active_only=True)
        results = await asyncio.gather(*(self._entries_or_none(row) for row in rows))
        used = set(reserved)
        tools: list[Tool[Any]] = []
        for entries in results:
            for entry in entries or []:
                tools.append(entry.build(unique_name(entry.base_name, used), approval))
        tools.extend(await self._session_tools.tools(approval, reserved=frozenset(used)))
        return tools

    async def test(self, uuid: str, *, interactive: bool = False) -> dict[str, Any] | None:
        """Connect/resolve and report the tools a row exposes; None when the row is unknown.

        An OAuth tool that needs a human is reported (``needsAuth``) instead of waited for,
        unless ``interactive`` (then the sign-in flow runs and this call awaits it).
        """
        row = next((r for r in await self._rows(active_only=False) if r.uuid == uuid), None)
        if row is None:
            record = await self._record(uuid)
            if record is None:
                return None
            row = ConfiguredRow.from_record(record)
        if row.tool_type not in CONFIGURED_TYPES:
            return {"ok": False, "tools": [], "error": NOT_EXECUTED_ERROR, "needsAuth": False}
        if row.tool_type == "acp":
            return await self._test_acp(row)
        try:
            if interactive and row.is_oauth:
                outcome = await self.connect_interactive(uuid)
                if not outcome.get("ok"):
                    return {"ok": False, "tools": [], "error": outcome.get("error"),
                            "needsAuth": outcome.get("status") == "needs_auth"}
            entries = await self._entries(row)
        except AuthorizationRequired:
            _LOG.info("services.configured_tools.test: %s needs sign-in", row.label)
            connection_event("tool.test.needs_sign_in", uuid=row.uuid, alias=row.label)
            return {"ok": False, "tools": [], "error": SIGN_IN_REQUIRED, "needsAuth": True}
        except Exception as error:
            log_tool_problem("tool.test.failed", uuid=row.uuid, alias=row.label, transport=row.transport,
                             error=describe_error(error))
            return {"ok": False, "tools": [], "error": describe_error(error), "needsAuth": False}
        used: set[str] = set()
        return {"ok": True, "tools": [
            {"name": unique_name(entry.base_name, used), "description": entry.description,
             "operation": entry.operation} for entry in entries], "error": None, "needsAuth": False}

    async def invalidate(self, uuid: str) -> None:
        """Drop the live connection for a row that changed or was deleted."""
        self._states.pop(uuid, None)
        if self.oauth_broker is not None:
            # A sign-in in flight holds the row lock for minutes; cancelling it frees the lock.
            await self.oauth_broker.cancel_for_tool(uuid)
        await self.acp_sessions.end_for_row(uuid, "the agent's configuration changed")
        async with self._lock(uuid):
            connection = self._connections.pop(uuid, None)
            if connection is not None:
                await connection.close()

    # --- status / OAuth ------------------------------------------------------------------------
    async def get_row(self, uuid: str) -> ConfiguredRow | None:
        record = await self._record(uuid)
        return None if record is None else ConfiguredRow.from_record(record)

    async def status(self, uuid: str) -> str:
        """``connected | needs_auth | error | disabled | idle`` for a registry row."""
        record = await self._record(uuid)
        return "idle" if record is None else await self.status_of(ConfiguredRow.from_record(record))

    async def status_of(self, row: ConfiguredRow) -> str:
        if row.status.casefold() != "active":
            return "disabled"
        connection = self._connections.get(row.uuid)
        if connection is not None and connection.alive:
            return "connected"
        state = self._states.get(row.uuid)
        if state is not None:
            return state
        if row.is_oauth and not await self.credentials.has_tool_oauth_tokens(row.uuid):
            return "needs_auth"
        return "idle"

    def tool_names(self, row: ConfiguredRow) -> list[str] | None:
        """Model-visible names of a live MCP connection's tools (None when not connected)."""
        connection = self._connections.get(row.uuid)
        if connection is None or not connection.alive:
            return None
        return [sanitize_name(f"{row.slug}{NAME_SEPARATOR}{tool.name}")[:MAX_FUNCTION_NAME]
                for tool in connection.tools]

    def start_authorization(self, uuid: str) -> asyncio.Future[dict[str, Any]]:
        """Begin (or join) the interactive sign-in of an OAuth tool in the background."""
        flow = self._flows.get(uuid)
        if flow is not None and not flow.done():
            return flow
        flow = spawn_logged(self.connect_interactive(uuid), name=f"oauth:{uuid}")
        self._flows[uuid] = flow

        def forget(done: asyncio.Future[dict[str, Any]]) -> None:
            if self._flows.get(uuid) is done:
                del self._flows[uuid]

        flow.add_done_callback(forget)
        return flow

    async def connect_interactive(self, uuid: str) -> dict[str, Any]:
        """Connect an OAuth tool, letting the user sign in. Never raises for expected failures.

        Returns ``{"ok": bool, "status": ..., "error": str|None, "tools": [names]}``.
        """
        record = await self._record(uuid)
        if record is None:
            return {"ok": False, "status": "error", "error": "Tool not found.", "tools": []}
        row = ConfiguredRow.from_record(record)
        if not row.is_oauth:
            return {"ok": False, "status": "error", "tools": [],
                    "error": "This tool does not use OAuth sign-in."}
        if self.oauth_broker is None:
            return {"ok": False, "status": "error", "tools": [], "error": "OAuth sign-in is unavailable."}
        # Marked up front so a concurrent non-interactive start never queues behind the sign-in.
        self._signing_in.add(uuid)
        try:
            await self._connection(row, interactive=True)
        except OAuthNotReady as error:
            _LOG.warning("services.configured_tools.connect_interactive: %s", error)
            return {"ok": False, "status": "error", "error": str(error), "tools": []}
        except AuthorizationRequired:
            _LOG.info("services.configured_tools.connect_interactive: %s still needs sign-in", row.label)
            return {"ok": False, "status": "needs_auth", "error": SIGN_IN_REQUIRED, "tools": []}
        except Exception as error:
            _LOG.warning("services.configured_tools.connect_interactive: sign-in for %s failed: %s",
                         row.label, describe_error(error))
            self._states[uuid] = "error"
            return {"ok": False, "status": "error", "error": describe_error(error), "tools": []}
        finally:
            self._signing_in.discard(uuid)
        return {"ok": True, "status": "connected", "error": None, "tools": self.tool_names(row) or []}

    async def forget_oauth(self, uuid: str) -> None:
        """Forget tokens and the dynamic client registration; stops the live connection."""
        await self.invalidate(uuid)
        await self.credentials.clear_tool_oauth(uuid, keep_client_secret=True)

    async def close(self) -> None:
        await self.acp_sessions.close_all()
        for uuid in list(self._connections):
            await self.invalidate(uuid)

    # --- loading -----------------------------------------------------------------------------
    async def _rows(self, *, active_only: bool) -> list[ConfiguredRow]:
        query = select(ToolRegistryRecord).where(ToolRegistryRecord.tool_type.in_(CONFIGURED_TYPES)) \
            .order_by(ToolRegistryRecord.alias, ToolRegistryRecord.id)
        async with self.database.session() as session:
            records = (await session.scalars(query)).all()
            rows = [ConfiguredRow.from_record(record) for record in records]
        return [row for row in rows if not active_only or row.status.casefold() == "active"]

    async def _record(self, uuid: str) -> ToolRegistryRecord | None:
        async with self.database.session() as session:
            return await session.scalar(select(ToolRegistryRecord).where(ToolRegistryRecord.uuid == uuid))

    async def _entries_or_none(self, row: ConfiguredRow) -> list[_Entry] | None:
        try:
            return await self._entries(row)
        except AuthorizationRequired:
            # Expected for an OAuth tool nobody has signed in to yet: skip quietly, never wait.
            _LOG.info("services.configured_tools._entries_or_none: %s skipped, needs sign-in", row.label)
            connection_event("mcp.server.skipped", uuid=row.uuid, tool=row.label, alias=row.label,
                             transport=row.transport, reason="needs sign-in")
            return None
        except Exception as error:
            log_tool_problem(f"{'mcp.server' if row.tool_type == 'mcp' else row.tool_type + '.tool'}.skipped",
                             uuid=row.uuid, tool=row.label, alias=row.label, transport=row.transport,
                             error=describe_error(error))
            return None

    async def _entries(self, row: ConfiguredRow) -> list[_Entry]:
        if row.tool_type == "cli":
            return [self._cli_entry(row)]
        if row.tool_type == "acp":
            return [self._acp_entry(row)]
        return await self._mcp_entries(row)

    # --- ACP agents ----------------------------------------------------------------------------
    def _acp_command(self, row: ConfiguredRow) -> list[str]:
        command = str(row.config.get("command") or "")
        cwd = row.config.get("cwd") or None
        if not command:
            raise ValueError("The ACP agent has no command.")
        executable = resolve_command(command, cwd)
        if executable is None:
            raise ValueError(f"The command '{command}' was not found.")
        return [executable, *[str(item) for item in (row.config.get("args") or [])]]

    def _acp_entry(self, row: ConfiguredRow) -> _Entry:
        self._acp_command(row)  # fail early (and skip the tool) when the agent cannot be started
        permissions = str(row.config.get("permissions") or "read_only")
        description = (row.description or "").strip() or f"Delegate a task to the external agent '{row.label}'."
        description += (" Each call starts a fresh, independent agent session (it remembers nothing from earlier "
                        "calls), so put everything it needs in `prompt`. Returns the agent's reply and the tool "
                        "calls it made. Optional `cwd` is the folder it works in.")
        if permissions == "read_only":
            description += " The agent may only read; anything that changes files or runs commands is refused."

        def build(name: str, approval: ApprovalConfig) -> Tool[Any]:
            # takes_ctx gives the call id, so the sub-agent's steps attach to this exact call.
            # The model never sees `ctx`; a caller outside an agent run may pass None.
            async def ask(ctx: RunContext[Any], prompt: str, cwd: str = "") -> dict[str, Any]:
                return await self._run_acp(row, prompt, cwd, getattr(ctx, "tool_call_id", None))

            return Tool(ask, name=name, description=description, takes_ctx=True,
                        requires_approval=approval.requires_operation(UPDATE))

        return _Entry(f"ask_{row.slug}", description, UPDATE, build)

    async def acp_rows(self) -> list[ConfiguredRow]:
        """Active ACP agent rows whose command can be found."""
        usable: list[ConfiguredRow] = []
        for row in await self._rows(active_only=True):
            if row.tool_type == "acp":
                try:
                    self._acp_command(row)
                except ValueError:
                    _LOG.info("services.configured_tools.acp_rows: %s skipped, command not found", row.label)
                    continue
                usable.append(row)
        return usable

    def acp_launch(self, row: ConfiguredRow, cwd: str = "") -> tuple[list[str], str | None, dict[str, str] | None, str]:
        """``(command, folder, env, permissions)`` to launch an ACP agent row; ValueError when it cannot be."""
        folder = cwd.strip() or row.config.get("cwd") or None
        if folder is not None and not Path(folder).expanduser().is_dir():
            raise ValueError(f"The folder '{folder}' does not exist.")
        env = row.config.get("env")
        return (self._acp_command(row), folder, env if isinstance(env, dict) else None,
                str(row.config.get("permissions") or "read_only"))

    async def _run_acp(self, row: ConfiguredRow, prompt: str, cwd: str,
                       tool_call_id: str | None = None) -> dict[str, Any]:
        if not prompt.strip():
            raise ValueError("prompt is required.")
        command, folder, env, permissions = self.acp_launch(row, cwd)
        progress = SubAgentProgress(progress_sink.get(), tool_call_id)
        try:
            result = await run_acp_agent(
                command, prompt, cwd=folder, env=env, permissions=permissions, timeout=self.acp_timeout,
                on_update=progress.on_update if progress.active else None)
        except AcpError as error:
            log_tool_problem("acp.tool.failed", uuid=row.uuid, alias=row.label, error=describe_error(error))
            raise RuntimeError(f"The agent '{row.label}' failed: {describe_error(error)}") from error
        finally:
            await progress.finish()
        return result.as_dict()

    async def _test_acp(self, row: ConfiguredRow) -> dict[str, Any]:
        try:
            info = await probe_acp_agent(self._acp_command(row), cwd=row.config.get("cwd") or None,
                                         env=row.config.get("env"))
        except (AcpError, ValueError) as error:
            log_tool_problem("acp.tool.test_failed", uuid=row.uuid, alias=row.label, error=describe_error(error))
            return {"ok": False, "tools": [], "error": describe_error(error), "needsAuth": False}
        name = info.get("title") or info.get("name") or row.label
        version = info.get("version")
        description = f"{name} {version}".strip() if version else str(name)
        return {"ok": True, "tools": [{"name": f"ask_{row.slug}", "description": description,
                                       "operation": UPDATE}], "error": None, "needsAuth": False}

    # --- CLI ---------------------------------------------------------------------------------
    def _cli_entry(self, row: ConfiguredRow) -> _Entry:
        command = str(row.config.get("command") or "")
        cwd = row.config.get("cwd") or None
        if not command:
            raise ValueError("The CLI tool has no command.")
        if resolve_command(command, cwd) is None:
            raise ValueError(f"The command '{command}' was not found.")
        description = (row.description or "").strip() or f"Run the {command} command line tool."
        description += (" The `arguments` parameter is a string of command-line arguments passed to "
                        "the command (split like a shell would, but no shell is used).")

        def build(name: str, approval: ApprovalConfig) -> Tool[Any]:
            async def run(arguments: str = "") -> dict[str, Any]:
                return await self._run_cli(row, arguments)

            return Tool(run, name=name, description=description,
                        requires_approval=approval.requires_operation(UPDATE))

        return _Entry(f"run_{row.slug}", description, UPDATE, build)

    async def _run_cli(self, row: ConfiguredRow, arguments: str) -> dict[str, Any]:
        command = str(row.config.get("command") or "")
        cwd = row.config.get("cwd") or None
        fixed = [str(item) for item in (row.config.get("args") or [])]
        try:
            extra = split_arguments(arguments or "")
            executable = resolve_command(command, cwd)
            if executable is None:
                raise FileNotFoundError(f"The command '{command}' was not found.")
            process = await asyncio.create_subprocess_exec(
                executable, *fixed, *extra, cwd=cwd, stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        except (OSError, ValueError) as error:
            log_tool_problem("cli.tool.failed", uuid=row.uuid, alias=row.label, command=command,
                             error=describe_error(error))
            raise RuntimeError(f"Could not run '{command}': {describe_error(error)}") from error
        out, err = _Capture(), _Capture()
        timed_out = False
        try:
            await asyncio.wait_for(asyncio.gather(
                _drain(process.stdout, out, CLI_OUTPUT_LIMIT),
                _drain(process.stderr, err, CLI_OUTPUT_LIMIT), process.wait()), self.cli_timeout)
        except asyncio.TimeoutError:
            timed_out = True
            log_tool_problem("cli.tool.failed", uuid=row.uuid, alias=row.label, command=command,
                             error=f"timed out after {self.cli_timeout:g}s and was killed")
        finally:
            if process.returncode is None:
                with logged_suppress(ProcessLookupError):
                    process.kill()
                await asyncio.wait_for(process.wait(), 10)
        stderr = err.data.decode("utf-8", "replace")
        if timed_out:
            stderr = (stderr + f"\n[Timed out after {self.cli_timeout:g} seconds and was killed.]").lstrip("\n")
        return {"exitCode": -1 if timed_out else process.returncode,
                "stdout": out.data.decode("utf-8", "replace"), "stderr": stderr,
                "truncated": out.dropped or err.dropped}

    # --- MCP ---------------------------------------------------------------------------------
    async def _mcp_entries(self, row: ConfiguredRow) -> list[_Entry]:
        connection = await self._connection(row)
        entries: list[_Entry] = []
        def prefix_room(tool_name: str) -> int:
            return max(4, MAX_FUNCTION_NAME - len(NAME_SEPARATOR) - len(tool_name))

        for tool in connection.tools:
            original = str(tool.name)
            annotations = getattr(tool, "annotations", None)
            read_only = bool(annotations is not None and getattr(annotations, "readOnlyHint", None) is True)
            operation = READ if read_only else classify_operation(original)
            schema = dict(tool.inputSchema) if isinstance(tool.inputSchema, dict) else {}
            schema.setdefault("type", "object")
            schema.setdefault("properties", {})
            prefix = sanitize_name(row.slug)[:prefix_room(original)]
            base = sanitize_name(f"{prefix}{NAME_SEPARATOR}{original}")
            description = (tool.description or tool.title or "").strip() or f"{original} (MCP tool)"
            entries.append(_Entry(base, description, operation,
                                  self._mcp_builder(row, original, description, operation, schema)))
        return entries

    def _mcp_builder(self, row: ConfiguredRow, original: str, description: str, operation: str,
                     schema: dict[str, Any]) -> Callable[[str, ApprovalConfig], Tool[Any]]:
        def build(name: str, approval: ApprovalConfig) -> Tool[Any]:
            async def call(**arguments: Any) -> str:
                # Resolve the connection per call so a restart between turns is picked up.
                connection = self._connections.get(row.uuid)
                if connection is None or not connection.alive:
                    connection = await self._connection(row)
                return await connection.call(original, arguments)

            tool: Tool[Any] = Tool.from_schema(
                call, name=name, description=f"[MCP server '{row.label}'] {description}".strip(),
                json_schema=schema)
            tool.requires_approval = approval.requires_operation(operation)
            return tool

        return build

    def _lock(self, uuid: str) -> asyncio.Lock:
        return self._locks.setdefault(uuid, asyncio.Lock())

    async def _connection(self, row: ConfiguredRow, *, interactive: bool = False) -> _McpConnection:
        if row.is_oauth and not interactive and row.uuid in self._signing_in:
            self._states[row.uuid] = "needs_auth"
            raise AuthorizationRequired(SIGN_IN_REQUIRED)  # a person is signing in right now
        async with self._lock(row.uuid):
            connection = self._connections.get(row.uuid)
            if connection is not None:
                if connection.row.updated_at == row.updated_at and await connection.healthy():
                    return connection
                self._connections.pop(row.uuid, None)
                await connection.close()
            headers = await self._headers(row)
            auth = None
            started: list[_McpConnection] = []

            def on_auth_required() -> None:
                self._states[row.uuid] = "needs_auth"
                for pending in started:
                    pending.signal_auth_required()

            start_timeout = self.mcp_start_timeout
            if row.is_oauth:
                auth = await self._oauth_auth(row, interactive, on_auth_required)
                if interactive and self.oauth_broker is not None:
                    start_timeout += self.oauth_broker.timeout  # waiting for the person
            connection = _McpConnection(row, headers, call_timeout=self.mcp_call_timeout, auth=auth)
            started.append(connection)
            try:
                await connection.start(start_timeout)
            except AuthorizationRequired:
                self._states[row.uuid] = "needs_auth"
                raise
            except BaseException:
                if not connection.auth_required:
                    self._states[row.uuid] = "error"
                raise
            self._states.pop(row.uuid, None)
            self._connections[row.uuid] = connection
            return connection

    async def _oauth_auth(self, row: ConfiguredRow, interactive: bool,
                          on_auth_required: Callable[[], None]) -> httpx.Auth:
        """The OAuth ``auth=`` for a row. Without stored tokens a non-interactive start stops here."""
        if self.oauth_broker is None:
            raise RuntimeError("OAuth sign-in is unavailable.")
        if not interactive and not await self.credentials.has_tool_oauth_tokens(row.uuid):
            self._states[row.uuid] = "needs_auth"
            raise AuthorizationRequired(SIGN_IN_REQUIRED)
        return await build_provider(
            row.uuid, row.label, row.endpoint_url or "", row.config, self.credentials,
            self.oauth_broker, interactive=interactive, on_auth_required=on_auth_required)

    async def _headers(self, row: ConfiguredRow) -> dict[str, str] | None:
        if row.transport != "http":
            return None
        raw = await self.credentials.get_tool_auth_config(row.uuid)
        if not raw:
            return None
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            _LOG.warning("services.configured_tools._headers: stored headers for %s are not valid JSON",
                         row.uuid, exc_info=True)
            return None
        return {str(k): str(v) for k, v in value.items()} if isinstance(value, dict) else None
