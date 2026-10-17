"""Remote tool calls between hive peers (webrtc.md section 8).

Two halves live here:

* ``RemoteToolService`` is the *owner* side: a node that exports some of its
  built-in tools. Every tool is ``off`` unless the owner sets it to ``ask`` (a
  human on the owning node decides per call) or ``allow``. Calls run with an
  explicit ``ToolContext`` built by the owner, never with the caller's state.
* ``RemoteToolset`` is the *executor* side: it turns the tools a peer advertises
  into pydantic-ai tools named ``<alias>.<tool>`` for a turn that opted in through
  ``tools_config {"remote": {"nodes": [...]}}``.

Frames travel over the existing ``control`` channel and only between ``hive_peer``
links: ``tool.list`` -> ``tool.list.result``, ``tool.call`` -> ``tool.result`` and
``tool.cancel``. Arguments and results are never logged; the audit table keeps only
a SHA-256 of the arguments.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import re
import time
from collections import Counter
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from uuid import uuid4

from pydantic import ValidationError
from pydantic_ai import Tool
from pydantic_core import to_jsonable_python
from sqlalchemy import select

from subconscious_engine.approval import ApprovalConfig, classify_operation
from subconscious_engine.config import RemoteToolsConfig, remote_tools_from_mapping
from subconscious_engine.storage.models import RemoteToolAudit, Workspace
from subconscious_engine.tools.filesystem_tools import (
    OutsideRootsError,
    filesystem_tool_entries,
    scoped_resolver,
)
from subconscious_engine.tools.registry import ToolContext, ToolSpec

from .authz import HIVE_PEER
from .channels import Envelope
from ..logging_setup import logged_suppress, spawn_logged
_LOG = logging.getLogger(__name__)

_LOGGER = logging.getLogger("uvicorn.error")

# Tool names must satisfy provider function-name rules ([A-Za-z0-9_-], at most 64 chars),
# so a dot is not an option.
NAME_SEPARATOR = "__"
MODE_OFF, MODE_ASK, MODE_ALLOW = "off", "ask", "allow"
# Tools whose behaviour depends on the caller's turn (files tagged in the chat, attachments)
# cannot run with an explicit context, so they are never exportable.
NON_EXPORTABLE = frozenset(
    {"list_context_files", "read_context_file", "read_attachment", "replace_active_file"}
)
# Built-in tool groups that work on a workspace and so need an explicit, existing one.
WORKSPACE_SLUGS = frozenset({"todo", "memory", "notes", "contacts", "knowledge"})
FILESYSTEM_SLUG = "filesystem"

MAX_ID_LENGTH = 64
MAX_TOOL_NAME = 100
MAX_ADVERTISED_TOOLS = 64
MAX_SCHEMA_BYTES = 32 * 1024
MAX_DESCRIPTION = 2000
MAX_ERROR_CHARS = 1000
MAX_MODEL_RESULT_CHARS = 1_000_000
MAX_REMOTE_NODES = 16
ALIAS_LENGTH = 24
MAX_FUNCTION_NAME = 64
LIST_TIMEOUT_SECONDS = 10.0
CACHE_SECONDS = 60.0
_TOOL_NAME = re.compile(r"^[A-Za-z0-9_]{1,64}$")
_EMPTY_SCHEMA: dict[str, Any] = {"type": "object", "properties": {}, "additionalProperties": True}


def args_sha256(args: Any) -> str:
    """Stable hash of the arguments (canonical JSON, sorted keys)."""
    canonical = json.dumps(args, sort_keys=True, separators=(",", ":"), ensure_ascii=False, default=str)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _clip(text: str, limit: int = MAX_ERROR_CHARS) -> str:
    return text if len(text) <= limit else text[: limit - 1] + "…"


async def record_audit(
    database: Any,
    *,
    direction: str,
    peer_node_id: str,
    task_id: str | None,
    tool: str,
    arguments_hash: str,
    outcome: str,
    started: float,
) -> None:
    """Append one audit row. Failures are logged without any call details."""
    try:
        async with database.session() as session:
            session.add(
                RemoteToolAudit(
                    direction=direction,
                    peer_node_id=peer_node_id,
                    task_id=task_id,
                    tool=tool[:MAX_TOOL_NAME],
                    args_sha256=arguments_hash,
                    outcome=outcome,
                    duration_ms=max(0, int((time.monotonic() - started) * 1000)),
                )
            )
            await session.commit()
    except Exception:
        _LOGGER.warning("A remote tool audit record could not be written.")


async def _send(link: Any, frame_type: str, data: Any, identifier: str | None = None) -> None:
    with logged_suppress(Exception):
        await link.send("control", Envelope(frame_type, data, identifier))


# --- owner side ---------------------------------------------------------------------------


@dataclass(slots=True)
class _PendingApproval:
    future: asyncio.Future[bool]
    peer_node_id: str


class RemoteToolService:
    """Exports this node's tools to trusted hive peers, per tool and default off."""

    def __init__(
        self, app: Any, config: RemoteToolsConfig | None = None, store_path: Path | None = None
    ) -> None:
        self.app = app
        self._defaults = config or RemoteToolsConfig()
        self._store_path = store_path
        self.config = self._load()
        self._calls: dict[tuple[str, str], asyncio.Future[tuple[str, Any]]] = {}
        self._approvals: dict[str, _PendingApproval] = {}
        self._active = 0

    # --- policy ---------------------------------------------------------------------------
    def _load(self) -> RemoteToolsConfig:
        path = self._store_path
        if path is None or not path.exists():
            return self._defaults
        try:
            return remote_tools_from_mapping(json.loads(path.read_text(encoding="utf-8")))
        except (OSError, ValueError):
            _LOGGER.warning("The remote tool policy file could not be read; using the configured defaults.")
            return self._defaults

    def catalog(self) -> dict[str, ToolSpec]:
        """Exportable tools by name. Filesystem tools use the root-scoped variant."""
        scoped = {
            entry[1]: ToolSpec(
                entry[0], entry[1], f"{entry[2]} Limited to the folders this node shares.", entry[3]
            )
            for entry in filesystem_tool_entries(scoped_resolver(lambda: self.config.filesystem_roots))
        }
        result: dict[str, ToolSpec] = {}
        for spec in self.app.state.tool_registry.specs:
            if spec.name in NON_EXPORTABLE:
                continue
            result[spec.name] = scoped.get(spec.name, spec)
        return result

    def mode_of(self, name: str, catalog: dict[str, ToolSpec] | None = None) -> str:
        spec = (catalog if catalog is not None else self.catalog()).get(name)
        if spec is None:
            return MODE_OFF
        if spec.slug == FILESYSTEM_SLUG and not self.config.filesystem_roots:
            return MODE_OFF  # never exportable without folders to confine it to
        return self.config.modes().get(name, MODE_OFF)

    def snapshot(self) -> dict[str, Any]:
        catalog = self.catalog()
        exportable = [
            {
                "name": name,
                "description": spec.description,
                "operation": classify_operation(name),
                "group": spec.slug,
                "available": not (spec.slug == FILESYSTEM_SLUG and not self.config.filesystem_roots),
                "mode": self.mode_of(name, catalog),
            }
            for name, spec in catalog.items()
        ]
        return {**self.config.to_mapping(), "exportable": exportable}

    def update(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Validate, apply and persist a policy change. Raises ``ValueError``."""
        body = {key: value for key, value in payload.items() if key != "exportable"}
        updated = remote_tools_from_mapping(body, base=self.config)
        catalog = self.catalog()
        for name in updated.modes():
            if name not in catalog:
                raise ValueError(f"'{name}' is not a tool that can be shared with other nodes.")
        for root in updated.filesystem_roots:
            path = Path(root)
            if not path.is_absolute():
                raise ValueError("Shared folders must be absolute paths.")
            if path.resolve() == Path(path.resolve().anchor):
                raise ValueError("A whole drive or the filesystem root cannot be shared.")
        self._persist(updated)
        self.config = updated
        return self.snapshot()

    def _persist(self, config: RemoteToolsConfig) -> None:
        path = self._store_path
        if path is None:
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".tmp")
        temporary.write_text(json.dumps(config.to_mapping(), indent=2), encoding="utf-8")
        os.replace(temporary, path)

    # --- advertised tools -------------------------------------------------------------------
    def _context(self, workspace_uuid: str = "") -> ToolContext:
        state = self.app.state
        return ToolContext(state.rag_service, state.database, workspace_uuid)

    def describe(self) -> list[dict[str, Any]]:
        """What ``tool.list`` returns: only tools whose mode is not ``off``."""
        catalog = self.catalog()
        tools: list[dict[str, Any]] = []
        for name, spec in catalog.items():
            mode = self.mode_of(name, catalog)
            if mode == MODE_OFF:
                continue
            tool = Tool(spec.factory(self._context()), name=name, description=spec.description)
            tools.append(
                {
                    "name": name,
                    "description": spec.description,
                    "parameters_schema": tool.function_schema.json_schema,
                    "operation": classify_operation(name),
                    "mode": mode,
                }
            )
        return tools

    # --- frames ---------------------------------------------------------------------------------
    async def handle(self, link: Any, envelope: Envelope, trusted: bool = True) -> None:
        """Entry point for ``tool.list``, ``tool.call`` and ``tool.cancel`` from a peer link."""
        data = envelope.data if isinstance(envelope.data, dict) else {}
        if envelope.type == "tool.list":
            tools = self.describe() if trusted else []
            await _send(link, "tool.list.result", {"tools": tools}, envelope.id)
        elif envelope.type == "tool.call":
            await self._handle_call(link, data, trusted)
        elif envelope.type == "tool.cancel":
            call_id = data.get("call_id")
            if isinstance(call_id, str):
                runner = self._calls.get((link.node_id, call_id))
                if runner is not None:
                    runner.cancel()

    async def _handle_call(self, link: Any, data: dict[str, Any], trusted: bool) -> None:
        call_id = data.get("call_id")
        if not isinstance(call_id, str) or not 0 < len(call_id) <= MAX_ID_LENGTH:
            return  # nothing to answer
        tool, args = data.get("tool"), data.get("args", {})
        task_id, workspace_uuid = data.get("task_id"), data.get("workspace_uuid")
        started = time.monotonic()
        name = tool if isinstance(tool, str) and 0 < len(tool) <= MAX_TOOL_NAME else ""
        task_id = task_id if isinstance(task_id, str) and len(task_id) <= MAX_ID_LENGTH else None
        workspace_uuid = (
            workspace_uuid if isinstance(workspace_uuid, str) and len(workspace_uuid) <= MAX_ID_LENGTH else None
        )
        key = (link.node_id, call_id)

        async def finish(outcome: str, payload: Any) -> None:
            ok = outcome == "ok"
            await record_audit(
                self.app.state.database, direction="in", peer_node_id=link.node_id, task_id=task_id,
                tool=name or "?", arguments_hash=args_sha256(args), outcome=outcome, started=started)
            frame = {"call_id": call_id, "ok": ok, ("result" if ok else "error"): payload}
            await _send(link, "tool.result", frame)

        if not trusted:
            await finish("denied", "This node may not call tools here.")
            return
        if not name or not isinstance(args, dict):
            await finish("error", "A tool name and an arguments object are required.")
            return
        if key in self._calls:
            await finish("error", "That call id is already in use.")
            return
        if self._active >= self.config.max_concurrent_calls:
            await finish("busy", "Too many remote tool calls are running on that node.")
            return
        self._active += 1
        runner: asyncio.Future[tuple[str, Any]] = spawn_logged(
            self._run(link, name, args, task_id, workspace_uuid)
        )
        self._calls[key] = runner
        try:
            await asyncio.wait({runner})
        finally:
            if not runner.done():
                runner.cancel()
            self._calls.pop(key, None)
            self._active -= 1
        if runner.cancelled():
            await finish("cancelled", "The call was cancelled.")
        else:
            outcome, payload = runner.result()
            await finish(outcome, payload)

    async def _run(
        self, link: Any, name: str, args: dict[str, Any], task_id: str | None, workspace_uuid: str | None
    ) -> tuple[str, Any]:
        """Policy, validation, approval and execution. Returns ``(outcome, result_or_error)``."""
        try:
            catalog = self.catalog()
            mode = self.mode_of(name, catalog)
            if mode == MODE_OFF:
                return "denied", "That tool is not shared by this node."
            spec = catalog[name]
            context_workspace = ""
            if spec.slug in WORKSPACE_SLUGS:
                if not workspace_uuid or not await self._workspace_exists(workspace_uuid):
                    return "error", "That workspace does not exist on this node."
                context_workspace = workspace_uuid
            tool = Tool(spec.factory(self._context(context_workspace)), name=name, description=spec.description)
            try:
                validated = tool.function_schema.validator.validate_python(args)
            except ValidationError as error:  # never echo the supplied values
                _LOG.warning("hive.remote_tools.RemoteToolService._run: handled ValidationError; continuing with fallback", exc_info=True)
                problems = "; ".join(
                    f"{'.'.join(str(part) for part in item['loc']) or 'arguments'}: {item['msg']}"
                    for item in error.errors(include_input=False, include_url=False)
                )
                return "error", _clip(f"Invalid arguments ({problems}).")
            if mode == MODE_ASK:
                decision = await self._ask(link, name, args, task_id)
                if decision == "none":
                    return "denied", "No one was available on that node to approve the call."
                if decision == "timeout":
                    return "denied", "The approval request timed out."
                if decision == "deny":
                    return "denied", "The owner denied this call."
            try:
                value = await asyncio.wait_for(
                    tool.function_schema.call(validated, None),  # type: ignore[arg-type]
                    self.config.call_timeout_seconds,
                )
            except asyncio.TimeoutError:
                _LOG.warning("hive.remote_tools.RemoteToolService._run: handled asyncio.TimeoutError; continuing with fallback", exc_info=True)
                return "timeout", "The tool call timed out."
            except OutsideRootsError as error:
                _LOG.warning("hive.remote_tools.RemoteToolService._run: handled OutsideRootsError; continuing with fallback", exc_info=True)
                return "denied", str(error)
            except Exception as error:
                _LOG.exception("hive.remote_tools.RemoteToolService._run: handled Exception; continuing with fallback")
                return "error", _clip(str(error) or error.__class__.__name__)
            result = to_jsonable_python(value, fallback=str)
            encoded = json.dumps(result, ensure_ascii=False, separators=(",", ":"))
            if len(encoded.encode("utf-8")) > self.config.max_result_bytes:
                return "too_large", f"The result is larger than the {self.config.max_result_bytes} byte limit."
            return "ok", result
        except asyncio.CancelledError:
            raise
        except Exception:
            _LOGGER.warning("A remote tool call failed unexpectedly.")
            return "error", "The tool call failed."

    async def _workspace_exists(self, workspace_uuid: str) -> bool:
        async with self.app.state.database.session() as session:
            found = await session.scalar(
                select(Workspace.id).where(Workspace.uuid == workspace_uuid, Workspace.deleted_at.is_(None))
            )
        return found is not None

    # --- approvals -----------------------------------------------------------------------------
    async def _ask(self, link: Any, name: str, args: dict[str, Any], task_id: str | None) -> str:
        """Ask a human on this node. Returns ``approve``, ``deny``, ``timeout`` or ``none``."""
        approval_id = uuid4().hex
        pending = _PendingApproval(asyncio.get_running_loop().create_future(), link.node_id)
        self._approvals[approval_id] = pending
        registry = self.app.state.client_registry
        context = getattr(self.app.state.task_manager, "context", None)
        peer_name = (context.node_name(link.node_id) if context is not None else None) or ""
        decision, reached = "none", 0
        try:
            reached = await registry.broadcast_local(
                "tool.approval.request",
                {
                    "approval_id": approval_id, "remote": True, "peer_node_id": link.node_id,
                    "peer_name": peer_name, "tool_name": name, "arguments": args, "task_id": task_id,
                    "operation": classify_operation(name),
                },
            )
            if reached == 0:
                return "none"
            try:
                approved = await asyncio.wait_for(pending.future, self.config.approval_timeout_seconds)
                decision = "approve" if approved else "deny"
            except asyncio.TimeoutError:
                _LOG.warning("hive.remote_tools.RemoteToolService._ask: handled asyncio.TimeoutError; continuing with fallback", exc_info=True)
                decision = "timeout"
            return decision
        finally:
            self._approvals.pop(approval_id, None)
            if reached:  # let the prompts on other local clients go away
                await registry.broadcast_local(
                    "tool.approval.resolved",
                    {
                        "approval_id": approval_id, "remote": True, "task_id": task_id,
                        "decision": decision if decision != "none" else "cancelled",
                    },
                )

    def handle_approval(self, approval_id: str, decision: str) -> bool:
        """Local clients answer here. First answer wins; returns ``False`` when unknown."""
        pending = self._approvals.get(approval_id)
        if pending is None:
            return False
        if not pending.future.done():
            pending.future.set_result(decision.casefold() == "approve")
        return True

    def on_link_closed(self, node_id: str) -> None:
        """A dropped peer cannot receive results: stop its calls and pending prompts."""
        for (peer, _call_id), runner in list(self._calls.items()):
            if peer == node_id:
                runner.cancel()
        for pending in list(self._approvals.values()):
            if pending.peer_node_id == node_id and not pending.future.done():
                pending.future.set_result(False)


# --- executor side ----------------------------------------------------------------------------


def remote_nodes_from_config(raw: str | None) -> list[str]:
    """Node ids named by ``tools_config {"remote": {"nodes": [...]}}`` (empty when unset)."""
    if not raw:
        return []
    try:
        config = json.loads(raw)
    except ValueError:
        _LOG.warning("hive.remote_tools.remote_nodes_from_config: handled ValueError; continuing with fallback", exc_info=True)
        return []
    remote = config.get("remote") if isinstance(config, dict) else None
    nodes = remote.get("nodes") if isinstance(remote, dict) else None
    if not isinstance(nodes, list):
        return []
    clean = [n for n in nodes if isinstance(n, str) and 0 < len(n) <= MAX_ID_LENGTH]
    return list(dict.fromkeys(clean))[:MAX_REMOTE_NODES]


def sanitize_alias(name: str) -> str:
    # Collapse underscore runs so an alias can never contain the "__" separator itself.
    cleaned = re.sub(r"[^a-z0-9_-]+", "_", name.casefold())
    return re.sub(r"_{2,}", "_", cleaned).strip("_-")[:ALIAS_LENGTH]


def assign_aliases(nodes: Sequence[tuple[str, str]]) -> dict[str, str]:
    """Unique tool-name prefix per ``(node_id, directory_name)``.

    A name that is empty after sanitising, or shared by several nodes, is replaced
    by the node id prefix for *all* of the clashing nodes so the result never
    depends on ordering.
    """
    base = {node_id: sanitize_alias(name) for node_id, name in nodes}
    counts = Counter(alias for alias in base.values() if alias)
    result: dict[str, str] = {}
    used: set[str] = set()
    for node_id, alias in base.items():
        if not alias or counts[alias] > 1:
            alias = re.sub(r"[^a-z0-9_-]", "", node_id.casefold())[:10]
        while alias in used:
            alias = f"{alias}_{len(used)}"
        used.add(alias)
        result[node_id] = alias
    return result


def _clean_advertised(value: Any) -> list[dict[str, Any]]:
    """Keep only well formed entries from a peer; its schemas are untrusted input."""
    if not isinstance(value, list):
        return []
    tools: list[dict[str, Any]] = []
    for item in value[:MAX_ADVERTISED_TOOLS]:
        if not isinstance(item, dict):
            continue
        name = item.get("name")
        if not isinstance(name, str) or not _TOOL_NAME.match(name):
            continue
        schema = item.get("parameters_schema")
        try:
            small = isinstance(schema, dict) and len(json.dumps(schema)) <= MAX_SCHEMA_BYTES
        except (TypeError, ValueError):
            _LOG.warning("hive.remote_tools._clean_advertised: handled (TypeError, ValueError); continuing with fallback", exc_info=True)
            small = False
        if not small or schema.get("type") != "object":
            schema = dict(_EMPTY_SCHEMA)
        description = item.get("description")
        tools.append(
            {
                "name": name,
                "description": _clip(description, MAX_DESCRIPTION) if isinstance(description, str) else "",
                "parameters_schema": schema,
            }
        )
    return tools


class RemoteToolset:
    """Builds and runs proxies for the tools hive peers export."""

    def __init__(
        self,
        app: Any,
        *,
        cache_seconds: float = CACHE_SECONDS,
        list_timeout: float = LIST_TIMEOUT_SECONDS,
        wait_seconds: float | None = None,
        clock: Any = time.monotonic,
    ) -> None:
        self.app = app
        self.cache_seconds = cache_seconds
        self.list_timeout = list_timeout
        self.wait_seconds = wait_seconds
        self._clock = clock
        self._cache: dict[str, tuple[float, list[dict[str, Any]]]] = {}
        self._lists: dict[str, tuple[str, asyncio.Future[dict[str, Any]]]] = {}
        self._calls: dict[str, tuple[str, asyncio.Future[dict[str, Any]]]] = {}

    @property
    def _context(self) -> Any:
        manager = getattr(self.app.state, "task_manager", None)
        return getattr(manager, "context", None)

    # --- frames in ---------------------------------------------------------------------------
    def on_frame(self, link: Any, envelope: Envelope) -> None:
        data = envelope.data if isinstance(envelope.data, dict) else {}
        if envelope.type == "tool.list.result" and envelope.id in self._lists:
            node_id, future = self._lists[envelope.id]
            if node_id == link.node_id and not future.done():
                future.set_result(data)
        elif envelope.type == "tool.result":
            call_id = data.get("call_id")
            entry = self._calls.get(call_id) if isinstance(call_id, str) else None
            # Only the node the call went to may answer it.
            if entry is not None and entry[0] == link.node_id and not entry[1].done():
                entry[1].set_result(data)

    def on_link_closed(self, node_id: str) -> None:
        self._cache.pop(node_id, None)
        for owner, future in [*self._lists.values(), *self._calls.values()]:
            if owner == node_id and not future.done():
                future.set_result({"ok": False, "error": "The peer disconnected."})

    # --- building tools --------------------------------------------------------------------------
    async def tools_for_turn(
        self, raw_config: str | None, *, task_id: str, workspace_uuid: str, approval: ApprovalConfig
    ) -> list[Tool[Any]]:
        nodes = remote_nodes_from_config(raw_config)
        context = self._context
        if not nodes or context is None:
            return []
        try:
            usable = [
                node_id for node_id in nodes
                if node_id != context.local_node_id
                and context.node_role(node_id) == HIVE_PEER
                and context.link(node_id) is not None
            ]
            listings = await asyncio.gather(*(self._advertised(node_id) for node_id in usable))
            present = [(node_id, tools) for node_id, tools in zip(usable, listings) if tools]
            aliases = assign_aliases([(node_id, context.node_name(node_id) or "") for node_id, _ in present])
            proxies: list[Tool[Any]] = []
            for node_id, tools in present:
                for advertised in tools:
                    proxies.append(
                        self._proxy(aliases[node_id], node_id, advertised, task_id, workspace_uuid, approval)
                    )
            return proxies
        except Exception:
            _LOGGER.warning("Remote tools could not be prepared for this turn.")
            return []

    def _proxy(
        self, alias: str, node_id: str, advertised: dict[str, Any], task_id: str, workspace_uuid: str,
        approval: ApprovalConfig,
    ) -> Tool[Any]:
        tool_name = advertised["name"]

        async def call(**arguments: Any) -> str:
            return await self.invoke(node_id, alias, tool_name, arguments, task_id, workspace_uuid)

        # Providers cap function names at 64 characters; shorten the alias, never the tool.
        prefix = alias[: max(4, MAX_FUNCTION_NAME - len(NAME_SEPARATOR) - len(tool_name))]
        proxy: Tool[Any] = Tool.from_schema(
            call,
            name=f"{prefix}{NAME_SEPARATOR}{tool_name}",
            description=f"[Runs on node '{alias}'] {advertised['description']}".strip(),
            json_schema=advertised["parameters_schema"],
        )
        # Our own approval settings still apply on top of whatever the owner requires.
        proxy.requires_approval = approval.requires(tool_name)
        return proxy

    async def _advertised(self, node_id: str) -> list[dict[str, Any]]:
        cached = self._cache.get(node_id)
        if cached is not None and cached[0] > self._clock():
            return cached[1]
        link = self._context.link(node_id)
        if link is None:
            return []
        request_id = uuid4().hex
        future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self._lists[request_id] = (node_id, future)
        try:
            await link.send("control", Envelope("tool.list", {}, request_id))
            reply = await asyncio.wait_for(future, self.list_timeout)
        except Exception:
            _LOG.exception("hive.remote_tools.RemoteToolset._advertised: handled Exception; continuing with fallback")
            return []
        finally:
            self._lists.pop(request_id, None)
        tools = _clean_advertised(reply.get("tools"))
        if "tools" in reply:  # a failed or aborted listing is not cached
            self._cache[node_id] = (self._clock() + self.cache_seconds, tools)
        return tools

    # --- calling -----------------------------------------------------------------------------------
    def _wait_seconds(self) -> float:
        if self.wait_seconds is not None:
            return self.wait_seconds
        owner = getattr(self.app.state, "remote_tools", None)
        config = owner.config if owner is not None else RemoteToolsConfig()
        return config.call_timeout_seconds + config.approval_timeout_seconds + 5.0

    async def invoke(
        self, node_id: str, alias: str, tool: str, arguments: dict[str, Any], task_id: str,
        workspace_uuid: str,
    ) -> str:
        """Run one remote call. Problems come back as text for the model, never as exceptions."""
        started = time.monotonic()
        link = self._context.link(node_id) if self._context is not None else None
        outcome, text = "offline", f"[remote tool error from {alias}: that node is offline]"
        call_id = uuid4().hex
        future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        try:
            if link is not None:
                self._calls[call_id] = (node_id, future)
                await link.send("control", Envelope("tool.call", {
                    "call_id": call_id, "task_id": task_id, "tool": tool, "args": arguments,
                    "workspace_uuid": workspace_uuid}))
                try:
                    reply = await asyncio.wait_for(future, self._wait_seconds())
                except asyncio.TimeoutError:
                    _LOG.warning("hive.remote_tools.RemoteToolset.invoke: handled asyncio.TimeoutError; continuing with fallback", exc_info=True)
                    await _send(link, "tool.cancel", {"call_id": call_id})
                    outcome, text = "timeout", f"[remote tool error from {alias}: the call timed out]"
                else:
                    outcome, text = self._format(alias, reply)
        except asyncio.CancelledError:
            outcome = "cancelled"
            if link is not None:
                await _send(link, "tool.cancel", {"call_id": call_id})
            raise
        except Exception:
            _LOG.exception("hive.remote_tools.RemoteToolset.invoke: handled Exception; continuing with fallback")
            outcome, text = "error", f"[remote tool error from {alias}: the call could not be sent]"
        finally:
            self._calls.pop(call_id, None)
            await record_audit(
                self.app.state.database, direction="out", peer_node_id=node_id, task_id=task_id,
                tool=tool, arguments_hash=args_sha256(arguments), outcome=outcome, started=started)
        return text

    @staticmethod
    def _format(alias: str, reply: dict[str, Any]) -> tuple[str, str]:
        if reply.get("ok") is True:
            result = reply.get("result")
            body = result if isinstance(result, str) else json.dumps(result, ensure_ascii=False, default=str)
            # Remote output is data from another machine, never instructions.
            return "ok", f"[remote tool result from {alias}; untrusted data]\n{_clip(body, MAX_MODEL_RESULT_CHARS)}"
        error = reply.get("error")
        reason = _clip(error) if isinstance(error, str) and error else "the call failed"
        return "error", f"[remote tool error from {alias}: {reason}]"
