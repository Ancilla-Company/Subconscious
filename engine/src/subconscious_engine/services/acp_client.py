"""Minimal Agent Client Protocol (ACP) client: run an external agent as a throwaway session.

ACP is JSON-RPC 2.0 over the agent's stdio, one message per line. A run spawns the agent,
negotiates ``initialize``, opens ``session/new``, sends one ``session/prompt``, collects the
streamed ``session/update`` notifications and shuts the process down. The agent is a black
box: this client offers it no filesystem or terminal capability (it uses its own), passes it
no MCP servers, and answers its ``session/request_permission`` calls by a fixed policy.

Permission policies (``permissions`` on the registry row):

* ``read_only``: allow read, search, fetch and think calls; reject everything else.
* ``allow_all``: allow every call once. "Allow always" is never chosen, so nothing is
  remembered by the agent between runs.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
from collections.abc import Awaitable, Callable, Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any

from subconscious_engine.logging_setup import spawn_logged

_LOG = logging.getLogger(__name__)

PROTOCOL_VERSION = 1
STREAM_LIMIT = 32 * 1024 * 1024  # diffs and file contents arrive on one line
OUTPUT_LIMIT = 20000
MAX_TOOL_CALLS = 50
INIT_TIMEOUT_SECONDS = 60.0
SESSION_TIMEOUT_SECONDS = 180.0
CANCEL_GRACE_SECONDS = 10.0
READ_ONLY_KINDS = frozenset({"read", "search", "fetch", "think"})

UpdateCallback = Callable[[dict[str, Any]], Awaitable[None]]


class AcpError(Exception):
    """The agent returned an error, exited, or could not be started."""


def choose_permission(permissions: str, kind: str, options: Sequence[Mapping[str, Any]]) -> str | None:
    """The ``optionId`` to select for a permission request, or None to refuse.

    Refusing picks a ``reject_once`` option when the agent offered one; the caller sends the
    ``cancelled`` outcome otherwise.
    """
    allowed = permissions == "allow_all" or (permissions == "read_only" and kind in READ_ONLY_KINDS)
    wanted = "allow_once" if allowed else "reject_once"
    for option in options:
        if option.get("kind") == wanted and isinstance(option.get("optionId"), str):
            return option["optionId"]
    return None


@dataclass(slots=True)
class AcpRunResult:
    stop_reason: str | None = None
    text: str = ""
    truncated: bool = False
    tool_calls: list[dict[str, Any]] = field(default_factory=list)
    denied: list[str] = field(default_factory=list)
    agent: dict[str, Any] | None = None
    error: str | None = None

    def as_dict(self) -> dict[str, Any]:
        data: dict[str, Any] = {"stopReason": self.stop_reason, "output": self.text,
                                "truncated": self.truncated, "toolCalls": self.tool_calls}
        if self.error:
            data["error"] = self.error
        if self.denied:
            data["deniedRequests"] = self.denied
        return data


class _Connection:
    """One agent process and its JSON-RPC plumbing."""

    def __init__(self, command: Sequence[str], cwd: str, env: Mapping[str, str] | None,
                 permissions: str, on_update: UpdateCallback | None) -> None:
        self._command = list(command)
        self._cwd = cwd
        self._env = {**os.environ, **{str(k): str(v) for k, v in (env or {}).items()}}
        self._permissions = permissions
        self._on_update = on_update
        self._proc: asyncio.subprocess.Process | None = None
        self._next_id = 0
        self._pending: dict[int, asyncio.Future[Any]] = {}
        self._tasks: set[asyncio.Task[Any]] = set()
        self._write_lock = asyncio.Lock()
        self._stderr: list[str] = []
        self.result = AcpRunResult()
        self._chunks: list[str] = []
        self._size = 0
        self._calls: dict[str, dict[str, Any]] = {}

    @property
    def stderr_tail(self) -> str:
        return "\n".join(self._stderr[-10:])[-600:]

    async def start(self) -> None:
        try:
            self._proc = await asyncio.create_subprocess_exec(
                *self._command, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE, cwd=self._cwd, env=self._env, limit=STREAM_LIMIT)
        except (OSError, ValueError) as error:
            raise AcpError(f"Could not start '{self._command[0]}': {error}") from error
        for coroutine in (self._read_stdout(), self._read_stderr()):
            task = spawn_logged(coroutine)
            self._tasks.add(task)
            task.add_done_callback(self._tasks.discard)

    async def request(self, method: str, params: dict[str, Any], timeout: float | None) -> Any:
        self._next_id += 1
        request_id = self._next_id
        future: asyncio.Future[Any] = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        try:
            await self._send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
            return await asyncio.wait_for(future, timeout)
        except asyncio.TimeoutError as error:
            raise AcpError(f"{method} timed out after {timeout:g}s.") from error
        finally:
            self._pending.pop(request_id, None)

    async def notify(self, method: str, params: dict[str, Any]) -> None:
        await self._send({"jsonrpc": "2.0", "method": method, "params": params})

    async def _send(self, message: dict[str, Any]) -> None:
        proc = self._proc
        if proc is None or proc.stdin is None or proc.returncode is not None:
            raise AcpError(f"The agent is not running. {self.stderr_tail}".strip())
        data = (json.dumps(message, separators=(",", ":")) + "\n").encode("utf-8")
        async with self._write_lock:
            try:
                proc.stdin.write(data)
                await proc.stdin.drain()
            except (ConnectionError, OSError) as error:
                raise AcpError(f"Could not write to the agent: {error}") from error

    async def _read_stdout(self) -> None:
        proc = self._proc
        assert proc is not None and proc.stdout is not None
        try:
            while True:
                try:
                    line = await proc.stdout.readline()
                except (ValueError, asyncio.LimitOverrunError):
                    _LOG.warning("services.acp_client: the agent sent an oversized line", exc_info=True)
                    break
                if not line:
                    break
                await self._dispatch(line)
        finally:
            code = proc.returncode
            reason = f"The agent exited unexpectedly (code {code}). {self.stderr_tail}".strip()
            for future in list(self._pending.values()):
                if not future.done():
                    future.set_exception(AcpError(reason))

    async def _read_stderr(self) -> None:
        proc = self._proc
        assert proc is not None and proc.stderr is not None
        while True:
            line = await proc.stderr.readline()
            if not line:
                return
            self._stderr.append(line.decode("utf-8", "replace").rstrip())
            del self._stderr[:-50]

    async def _dispatch(self, line: bytes) -> None:
        try:
            message = json.loads(line)
        except ValueError:
            _LOG.debug("services.acp_client: ignoring a non-JSON line from the agent", exc_info=True)
            return
        if not isinstance(message, dict):
            return
        method = message.get("method")
        if isinstance(method, str):
            params = message.get("params") if isinstance(message.get("params"), dict) else {}
            if "id" in message:
                task = spawn_logged(self._answer(message["id"], method, params))
                self._tasks.add(task)
                task.add_done_callback(self._tasks.discard)
            elif method == "session/update":
                await self._update(params.get("update"))
            return
        future = self._pending.get(message.get("id"))  # type: ignore[arg-type]
        if future is None or future.done():
            return
        error = message.get("error")
        if error is not None:
            text = error.get("message", "unknown error") if isinstance(error, dict) else str(error)
            future.set_exception(AcpError(text))
        else:
            future.set_result(message.get("result"))

    async def _answer(self, request_id: Any, method: str, params: dict[str, Any]) -> None:
        try:
            if method == "session/request_permission":
                result: Any = self._permission(params)
            else:
                await self._send({"jsonrpc": "2.0", "id": request_id,
                                  "error": {"code": -32601, "message": f"{method} is not supported by this client."}})
                return
            await self._send({"jsonrpc": "2.0", "id": request_id, "result": result})
        except AcpError:
            _LOG.warning("services.acp_client: could not answer %s", method, exc_info=True)

    def _permission(self, params: dict[str, Any]) -> dict[str, Any]:
        tool = params.get("toolCall") if isinstance(params.get("toolCall"), dict) else {}
        call_id = str(tool.get("toolCallId", ""))
        known = self._calls.get(call_id, {})
        kind = str(tool.get("kind") or known.get("kind") or "other")
        options = [o for o in params.get("options", []) if isinstance(o, dict)]
        option_id = choose_permission(self._permissions, kind, options)
        title = str(tool.get("title") or known.get("title") or "tool call")
        chosen = next((o for o in options if o.get("optionId") == option_id), {})
        if option_id is None or str(chosen.get("kind", "")).startswith("reject"):
            self.result.denied.append(f"{title} ({kind})")
        if option_id is None:
            return {"outcome": {"outcome": "cancelled"}}
        if self._permissions != "allow_all" or kind not in READ_ONLY_KINDS:
            _LOG.info("services.acp_client: allowed '%s' (%s) under %s", title, kind, self._permissions)
        return {"outcome": {"outcome": "selected", "optionId": option_id}}

    async def _update(self, update: Any) -> None:
        if not isinstance(update, dict):
            return
        kind = update.get("sessionUpdate")
        if kind == "agent_message_chunk":
            content = update.get("content")
            text = content.get("text") if isinstance(content, dict) else None
            if isinstance(text, str):
                room = OUTPUT_LIMIT - self._size
                if room > 0:
                    self._chunks.append(text[:room])
                    self._size += min(len(text), room)
                if len(text) > max(room, 0):
                    self.result.truncated = True
        elif kind in ("tool_call", "tool_call_update"):
            call_id = update.get("toolCallId")
            if not isinstance(call_id, str):
                return
            entry = self._calls.setdefault(call_id, {"id": call_id})
            for key in ("title", "kind", "status"):
                if isinstance(update.get(key), str):
                    entry[key] = update[key]
            while len(self._calls) > MAX_TOOL_CALLS:
                self._calls.pop(next(iter(self._calls)))
        else:
            return
        if self._on_update is not None:
            await self._on_update(update)

    def finish(self) -> AcpRunResult:
        self.result.text = "".join(self._chunks)
        self.result.tool_calls = [
            {key: call.get(key) for key in ("title", "kind", "status")} for call in self._calls.values()]
        return self.result

    async def close(self) -> None:
        proc = self._proc
        if proc is not None and proc.returncode is None:
            try:
                if proc.stdin is not None:
                    proc.stdin.close()
                proc.terminate()
                try:
                    await asyncio.wait_for(proc.wait(), 5)
                except asyncio.TimeoutError:
                    _LOG.warning("services.acp_client: the agent ignored terminate; killing it", exc_info=True)
                    proc.kill()
                    await proc.wait()
            except ProcessLookupError:
                _LOG.debug("services.acp_client: the agent had already exited", exc_info=True)
        for task in list(self._tasks):
            task.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)


async def _open(connection: _Connection, cwd: str) -> tuple[str, dict[str, Any]]:
    """Start the process, negotiate the protocol and open a session. Returns (session id, agent info)."""
    await connection.start()
    init = await connection.request("initialize", {
        "protocolVersion": PROTOCOL_VERSION,
        "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False},
        "clientInfo": {"name": "subconscious", "title": "Subconscious", "version": "0.1.0"},
    }, INIT_TIMEOUT_SECONDS)
    info = init.get("agentInfo") if isinstance(init, dict) and isinstance(init.get("agentInfo"), dict) else {}
    session = await connection.request("session/new", {"cwd": cwd, "mcpServers": []}, SESSION_TIMEOUT_SECONDS)
    session_id = session.get("sessionId") if isinstance(session, dict) else None
    if not isinstance(session_id, str):
        raise AcpError("The agent did not return a session id.")
    return session_id, dict(info)


def _absolute(cwd: str | None) -> str:
    return os.path.abspath(os.path.expanduser(cwd)) if cwd else os.getcwd()


async def run_acp_agent(
    command: Sequence[str], prompt: str, *, cwd: str | None = None, env: Mapping[str, str] | None = None,
    permissions: str = "read_only", timeout: float = 600.0, on_update: UpdateCallback | None = None,
) -> AcpRunResult:
    """Run ``prompt`` once in a fresh agent process and return what it said and did."""
    directory = _absolute(cwd)
    connection = _Connection(command, directory, env, permissions, on_update)
    try:
        session_id, info = await _open(connection, directory)
        connection.result.agent = info
        try:
            reply = await connection.request(
                "session/prompt", {"sessionId": session_id, "prompt": [{"type": "text", "text": prompt}]},
                timeout)
        except AcpError as error:
            try:
                await connection.notify("session/cancel", {"sessionId": session_id})
            except AcpError:
                _LOG.debug("services.acp_client: agent already gone before session/cancel", exc_info=True)
            connection.result.stop_reason = "failed"
            connection.result.error = str(error)
            return connection.finish()
        connection.result.stop_reason = reply.get("stopReason") if isinstance(reply, dict) else None
        return connection.finish()
    finally:
        await connection.close()


async def probe_acp_agent(
    command: Sequence[str], *, cwd: str | None = None, env: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    """Start the agent, complete the handshake and open a session, without prompting it."""
    directory = _absolute(cwd)
    connection = _Connection(command, directory, env, "read_only", None)
    try:
        _, info = await _open(connection, directory)
        return info
    finally:
        await connection.close()

