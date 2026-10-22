"""Tools that let the assistant configure its own tools and skills from chat.

Built per chat turn (when tools are enabled) by :class:`ToolManagement`. Security model:

* Every tool that creates, changes, deletes, tests (spawns processes) or connects requires human
  approval REGARDLESS of the user's ``ApprovalConfig``: adding a stdio MCP server or a CLI tool is
  arbitrary code execution, and text inside tool output (prompt injection) must never be able to
  add one silently. Read-only listing tools follow the normal approval policy.
* Secrets never pass through the model. ``api_key_header`` authentication is refused here (the user
  adds keys in Settings > Tools); OAuth tokens, client registrations and client secrets live in the
  encrypted store and are never returned; listings show environment variable NAMES only.
* Validation is the REST layer's (``ToolRegistryService`` / ``SkillService``); nothing is duplicated.

Failures are returned as ``{"ok": False, "error": ...}`` so the model can react, not raised.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable, Collection
from typing import Any

from pydantic_ai import Tool
from sqlalchemy import select

from subconscious_engine.api.extra_schemas import ToolRegistryDto, UpsertSkillRequest, UpsertToolRegistryRequest
from subconscious_engine.approval import ApprovalConfig
from subconscious_engine.configuration import ModelConfigurationStoreError
from subconscious_engine.services.builtin_skills import BUILTIN_UUID_PREFIX
from subconscious_engine.services.configured_tools import ConfiguredRow, ConfiguredToolRuntime
from subconscious_engine.services.skills import MAX_INSTRUCTIONS, SkillInfo, SkillService
from subconscious_engine.services.tool_registry import ToolRegistryService
from subconscious_engine.storage.models import ToolRegistryRecord

_LOG = logging.getLogger(__name__)

MANAGED_TYPES = ("mcp", "cli")
MAX_DESCRIPTION = 300
MAX_LISTED_TOOLS = 40
NEXT_MESSAGE_NOTE = "These tools become available on the user's next message."
API_KEY_REFUSAL = ("API keys must not be sent through the chat. Ask the user to add the key in "
                   "Settings > Tools (authentication: API key), or use auth='oauth' if the server supports it.")

# Tools that change state or run code: approval is forced on for these.
FORCED_APPROVAL = frozenset({
    "add_mcp_server", "add_cli_tool", "update_configured_tool", "remove_configured_tool",
    "test_configured_tool", "connect_tool", "disconnect_tool", "create_skill", "update_skill", "remove_skill"})
READ_ONLY = frozenset({"list_configured_tools", "get_configured_tool", "list_skills", "get_skill_info"})


def _error(message: str, **extra: Any) -> dict[str, Any]:
    return {"ok": False, "error": message, **extra}


def _short(text: str | None, limit: int = MAX_DESCRIPTION) -> str | None:
    if not text:
        return None
    text = " ".join(text.split())
    return text if len(text) <= limit else text[:limit - 1] + "…"


class ToolManagement:
    """Per-engine collaborators for the management tools; :meth:`tools` builds one turn's set."""

    def __init__(self, database: Any, credentials: Any, runtime: ConfiguredToolRuntime, broker: Any) -> None:
        self.database = database
        self.credentials = credentials
        self.runtime = runtime
        self.broker = broker

    def tools(self, approval: ApprovalConfig, *, reserved: Collection[str] = ()) -> list[Tool[Any]]:
        handlers: dict[str, tuple[Callable[..., Awaitable[Any]], str]] = {
            "list_configured_tools": (self.list_configured_tools, (
                "List the user's configured MCP servers and CLI tools with their status "
                "(connected, needs_auth, error, disabled, idle), authentication type, and tool names when known.")),
            "get_configured_tool": (self.get_configured_tool, (
                "Show one configured tool's settings. `name` is its name, alias or id. Environment variables "
                "are shown by NAME only; secrets, tokens and values are never returned.")),
            "add_mcp_server": (self.add_mcp_server, (
                "Register an MCP server. Give exactly one of `command` (+ `args`, a local stdio server that runs "
                "code on the user's computer) or `url` (a remote HTTPS server). Use auth='oauth' for hosted "
                "services that need a sign-in, then call connect_tool. `env` values are stored UNENCRYPTED: "
                "never put secrets in env or args; API keys cannot be added from chat (Settings > Tools). "
                "Confirm the exact command/url with the user first. Requires user approval.")),
            "add_cli_tool": (self.add_cli_tool, (
                "Register a command line program as a tool (run later as run_<name> with an `arguments` string). "
                "It runs on the user's computer with their permissions. Confirm the exact command with the "
                "user first; never put secrets in args. Requires user approval.")),
            "update_configured_tool": (self.update_configured_tool, (
                "Change a configured tool. Only the fields you pass change. `enabled=False` disables it. "
                "Changing the url of an OAuth tool signs it out. Requires user approval.")),
            "remove_configured_tool": (self.remove_configured_tool, (
                "Delete a configured tool and any stored sign-in for it. Requires user approval.")),
            "test_configured_tool": (self.test_configured_tool, (
                "Start the tool (or resolve the command) and report whether it works and which tools it "
                "exposes. Never waits for a sign-in: returns needsAuth=true instead. Requires user approval "
                "because it starts a process or connection.")),
            "connect_tool": (self.connect_tool, (
                "Sign in to an OAuth MCP server. The chat shows a 'Sign in' card and this call waits (up to ten "
                "minutes) until the user finishes in their browser. The new tools become available on the user's "
                "next message. Requires user approval.")),
            "disconnect_tool": (self.disconnect_tool, (
                "Forget the OAuth sign-in (tokens and client registration) of a tool and stop its connection. "
                "Requires user approval.")),
            "list_skills": (self.list_skills, "List all skills (name, description, enabled, type)."),
            "get_skill_info": (self.get_skill_info, (
                "Show a skill's details; text skills include their instructions.")),
            "create_skill": (self.create_skill, (
                "Create a text skill: reusable instructions the assistant can read later with read_skill. "
                "`description` says WHEN to use it. Instructions are limited to 20000 characters. "
                "Requires user approval.")),
            "update_skill": (self.update_skill, (
                "Change a text skill's description, instructions or enabled flag. Requires user approval.")),
            "remove_skill": (self.remove_skill, "Delete a skill. Requires user approval."),
        }
        built: list[Tool[Any]] = []
        for name, (function, description) in handlers.items():
            if name in reserved:
                _LOG.warning("services.tool_management.ToolManagement.tools: %s skipped, name already in use", name)
                continue
            forced = name in FORCED_APPROVAL
            built.append(Tool(function, name=name, description=description,
                              requires_approval=True if forced else approval.requires(name)))
        return built

    # --- helpers -----------------------------------------------------------------------------
    def _service(self, session: Any) -> ToolRegistryService:
        return ToolRegistryService(session, self.credentials, self.runtime)

    @staticmethod
    async def _find(session: Any, name: str) -> tuple[ToolRegistryRecord | None, str | None]:
        """Resolve alias / name / uuid (case-insensitive); ambiguity is an error naming the matches."""
        wanted = (name or "").strip().casefold()
        if not wanted:
            return None, "A tool name is required."
        records = list((await session.scalars(select(ToolRegistryRecord).where(
            ToolRegistryRecord.tool_type.in_(MANAGED_TYPES)).order_by(ToolRegistryRecord.id))).all())
        exact = [r for r in records if r.uuid.casefold() == wanted]
        matches = exact or [r for r in records if wanted in {(r.alias or "").casefold(), r.name.casefold()}]
        if len(matches) == 1:
            return matches[0], None
        if not matches:
            known = ", ".join(sorted({r.alias or r.name for r in records})) or "none"
            return None, f"No configured tool named '{name}'. Known tools: {known}."
        listing = "; ".join(f"{r.alias or r.name} ({r.tool_type}, id {r.uuid})" for r in matches)
        return None, f"'{name}' is ambiguous: {listing}. Use the id."

    async def _entry(self, record: ToolRegistryRecord, *, detail: bool = False) -> dict[str, Any]:
        row = ConfiguredRow.from_record(record)
        entry: dict[str, Any] = {
            "name": record.name, "alias": record.alias, "id": record.uuid, "type": record.tool_type,
            "transport": row.transport, "enabled": record.status.casefold() == "active",
            "status": await self.runtime.status_of(row), "authType": record.auth_type,
            "oauthConnected": (await self.credentials.has_tool_oauth_tokens(record.uuid)) if row.is_oauth else None}
        names = self.runtime.tool_names(row)
        if names is not None:
            entry["tools"] = names[:MAX_LISTED_TOOLS]
        if detail:
            config = row.config
            entry.update({
                "description": _short(record.description), "url": record.endpoint_url,
                "command": config.get("command"), "args": config.get("args"), "cwd": config.get("cwd"),
                "envKeys": sorted((config.get("env") or {}).keys()),
                "oauthClientId": config.get("oauthClientId"), "oauthScopes": config.get("oauthScopes")})
        return entry

    # --- tools: tool registry ----------------------------------------------------------------
    async def list_configured_tools(self) -> list[dict[str, Any]] | dict[str, Any]:
        try:
            async with self.database.session() as session:
                records = (await session.scalars(select(ToolRegistryRecord).where(
                    ToolRegistryRecord.tool_type.in_(MANAGED_TYPES)).order_by(ToolRegistryRecord.id))).all()
                return [await self._entry(record) for record in records]
        except ModelConfigurationStoreError as problem:
            _LOG.warning("services.tool_management.list_configured_tools: credential store unavailable", exc_info=True)
            return _error(str(problem))

    async def get_configured_tool(self, name: str) -> dict[str, Any]:
        async with self.database.session() as session:
            record, problem = await self._find(session, name)
            return _error(problem) if record is None else await self._entry(record, detail=True)

    async def add_mcp_server(
        self, name: str, command: str | None = None, args: list[str] | None = None,
        env: dict[str, str] | None = None, cwd: str | None = None, url: str | None = None,
        description: str | None = None, auth: str = "none", oauth_client_id: str | None = None,
        oauth_scopes: str | None = None,
    ) -> dict[str, Any]:
        """Register an MCP server (stdio command OR remote url).

        Args:
            name: Short unique name, e.g. "github" or "mailbox".
            command: Executable of a local stdio server (runs on the user's computer).
            args: Command arguments. Never put secrets here.
            env: Environment variables as plain text. NOT secret storage: never put keys or tokens here.
            cwd: Working directory for the command.
            url: HTTPS endpoint of a remote streamable-HTTP MCP server.
            description: One honest sentence about what the server does and can access.
            auth: "none" or "oauth" (browser sign-in via connect_tool). "api_key_header" is refused.
            oauth_client_id: Pre-registered OAuth client id, only if the service requires one.
            oauth_scopes: Space separated OAuth scopes, only if the service requires specific ones.
        """
        auth_mode = (auth or "none").strip().casefold()
        if auth_mode == "api_key_header":
            return _error(API_KEY_REFUSAL)
        if auth_mode not in {"none", "oauth"}:
            return _error("auth must be 'none' or 'oauth'.")
        if (command is None) == (url is None):
            return _error("Provide exactly one of command (local stdio server) or url (remote server).")
        if auth_mode == "oauth" and url is None:
            return _error("auth='oauth' needs a remote url.")
        request = UpsertToolRegistryRequest(
            name=name, alias=name, description=description, tool_type="mcp", endpoint_url=url,
            command=command, args=args, env=env, cwd=cwd, auth_type="oauth" if auth_mode == "oauth" else None,
            oauth_client_id=oauth_client_id, oauth_scopes=oauth_scopes, status="active")
        return await self._create(name, request)

    async def add_cli_tool(self, name: str, command: str, args: list[str] | None = None,
                           cwd: str | None = None, description: str | None = None) -> dict[str, Any]:
        """Register a CLI program as a tool.

        Args:
            name: Short unique name, e.g. "git".
            command: Executable name or path. Runs without a shell.
            args: Fixed leading arguments. Never put secrets here.
            cwd: Working directory.
            description: One honest sentence about what it does.
        """
        request = UpsertToolRegistryRequest(
            name=name, alias=name, description=description, tool_type="cli", command=command, args=args,
            cwd=cwd, status="active")
        return await self._create(name, request)

    async def _create(self, name: str, request: UpsertToolRegistryRequest) -> dict[str, Any]:
        if not (name or "").strip():
            return _error("A tool name is required.")
        try:
            async with self.database.session() as session:
                existing, _ = await self._find(session, name)
                if existing is not None:
                    return _error(f"A tool named '{name}' already exists; use update_configured_tool.")
                dto = await self._service(session).create(request)
                record = await session.scalar(select(ToolRegistryRecord).where(ToolRegistryRecord.uuid == dto.uuid))
                entry = await self._entry(record) if record is not None else {"id": dto.uuid}
        except ValueError as problem:
            _LOG.info("services.tool_management: request rejected: %s", problem)
            return _error(str(problem))
        except ModelConfigurationStoreError as problem:
            _LOG.warning("services.tool_management._create: credential store unavailable", exc_info=True)
            return _error(str(problem))
        entry["ok"] = True
        if dto.auth_type == "oauth":
            entry["next"] = "Call connect_tool so the user can sign in."
        else:
            entry["next"] = "Call test_configured_tool to check it works; its tools become available on the user's next message."
        return entry

    async def update_configured_tool(
        self, name: str, new_name: str | None = None, command: str | None = None,
        args: list[str] | None = None, env: dict[str, str] | None = None, cwd: str | None = None,
        url: str | None = None, description: str | None = None, auth: str | None = None,
        oauth_client_id: str | None = None, oauth_scopes: str | None = None, enabled: bool | None = None,
    ) -> dict[str, Any]:
        """Change a configured tool; only the fields you pass change.

        Args:
            name: Current name, alias or id of the tool.
            new_name: Rename the tool.
            command: New executable (stdio MCP server / CLI tool).
            args: New argument list (replaces the old one).
            env: New plain-text environment (replaces the old one). Never put secrets here.
            cwd: New working directory.
            url: New endpoint of a remote MCP server (signs an OAuth tool out).
            description: New description.
            auth: "none" or "oauth". "api_key_header" is refused.
            oauth_client_id: Pre-registered OAuth client id.
            oauth_scopes: Space separated OAuth scopes.
            enabled: False disables the tool, True enables it.
        """
        auth_mode = auth.strip().casefold() if auth is not None else None
        if auth_mode == "api_key_header":
            return _error(API_KEY_REFUSAL)
        if auth_mode not in {None, "none", "oauth"}:
            return _error("auth must be 'none' or 'oauth'.")
        try:
            async with self.database.session() as session:
                record, problem = await self._find(session, name)
                if record is None:
                    return _error(problem or "Tool not found.")
                service = self._service(session)
                current = await service.get(record.uuid)
                if current is None:
                    return _error("Tool not found.")
                request = self._merge(current, record, new_name, command, args, env, cwd, url, description,
                                      auth_mode, oauth_client_id, oauth_scopes, enabled)
                if isinstance(request, str):
                    return _error(request)
                if new_name and new_name.strip().casefold() != (record.alias or record.name).casefold():
                    other, _ = await self._find(session, new_name)
                    if other is not None and other.uuid != record.uuid:
                        return _error(f"A tool named '{new_name}' already exists.")
                updated = await service.update(record.uuid, request)
                if updated is None:
                    return _error("Tool not found.")
                await session.refresh(record)
                entry = await self._entry(record)
        except ValueError as problem:
            _LOG.info("services.tool_management: request rejected: %s", problem)
            return _error(str(problem))
        except ModelConfigurationStoreError as problem:
            _LOG.warning("services.tool_management.update_configured_tool: credential store unavailable", exc_info=True)
            return _error(str(problem))
        entry["ok"] = True
        return entry

    @staticmethod
    def _merge(current: ToolRegistryDto, record: ToolRegistryRecord, new_name: str | None, command: str | None,
               args: list[str] | None, env: dict[str, str] | None, cwd: str | None, url: str | None,
               description: str | None, auth_mode: str | None, oauth_client_id: str | None,
               oauth_scopes: str | None, enabled: bool | None) -> UpsertToolRegistryRequest | str:
        values: dict[str, Any] = {
            "name": new_name.strip() if new_name and new_name.strip() else current.name,
            "alias": new_name.strip() if new_name and new_name.strip() else current.alias,
            "description": description if description is not None else current.description,
            "tool_type": current.tool_type, "endpoint_url": current.endpoint_url, "auth_type": current.auth_type,
            "command": current.command, "args": current.args, "env": current.env, "cwd": current.cwd,
            "oauth_client_id": current.oauth_client_id, "oauth_scopes": current.oauth_scopes,
            "status": ("active" if enabled else "disabled") if enabled is not None else current.status}
        if current.tool_type == "cli" and (url is not None or auth_mode not in {None, "none"}
                                           or oauth_client_id or oauth_scopes or env):
            return "A CLI tool only has command, args, cwd and description."
        if url is not None:
            if current.tool_type != "mcp":
                return "Only MCP servers have a url."
            values.update(endpoint_url=url, command=None, args=None, env=None, cwd=None)
        if command is not None:
            values["command"] = command
            if current.tool_type == "mcp":
                values.update(endpoint_url=None, auth_type=None, oauth_client_id=None, oauth_scopes=None)
        if url is not None and command is not None:
            return "Provide either url or command, not both."
        if args is not None:
            values["args"] = args
        if env is not None:
            values["env"] = env
        if cwd is not None:
            values["cwd"] = cwd
        if auth_mode == "none":
            values.update(auth_type=None, oauth_client_id=None, oauth_scopes=None)
        elif auth_mode == "oauth":
            values["auth_type"] = "oauth"
        if oauth_client_id is not None:
            values["oauth_client_id"] = oauth_client_id
        if oauth_scopes is not None:
            values["oauth_scopes"] = oauth_scopes
        if values["auth_type"] != "oauth":
            values.update(oauth_client_id=None, oauth_scopes=None)
        return UpsertToolRegistryRequest(**values)

    async def remove_configured_tool(self, name: str) -> dict[str, Any]:
        try:
            async with self.database.session() as session:
                record, problem = await self._find(session, name)
                if record is None:
                    return _error(problem or "Tool not found.")
                label = record.alias or record.name
                await self._service(session).delete(record.uuid)
        except ModelConfigurationStoreError as problem:
            _LOG.warning("services.tool_management.remove_configured_tool: credential store unavailable", exc_info=True)
            return _error(str(problem))
        return {"ok": True, "removed": label}

    async def test_configured_tool(self, name: str) -> dict[str, Any]:
        async with self.database.session() as session:
            record, problem = await self._find(session, name)
        if record is None:
            return _error(problem or "Tool not found.")
        result = await self.runtime.test(record.uuid)
        if result is None:
            return _error("Tool not found.")
        tools = [str(item.get("name")) for item in result.get("tools", [])][:MAX_LISTED_TOOLS]
        return {"ok": bool(result.get("ok")), "tools": tools, "error": result.get("error"),
                "needsAuth": bool(result.get("needsAuth"))}

    async def connect_tool(self, name: str) -> dict[str, Any]:
        """Run the OAuth sign-in for an MCP server and wait until the user finishes it."""
        async with self.database.session() as session:
            record, problem = await self._find(session, name)
        if record is None:
            return _error(problem or "Tool not found.")
        row = ConfiguredRow.from_record(record)
        if not row.is_oauth:
            return _error(f"'{record.alias or record.name}' does not use OAuth sign-in.")
        flow = self.runtime.start_authorization(record.uuid)
        try:
            outcome = await asyncio.shield(flow)
        except asyncio.CancelledError:
            # The turn was cancelled: do not leave a sign-in card (and a waiting connection) behind.
            await self.broker.cancel_for_tool(record.uuid)
            raise
        if outcome.get("ok"):
            return {"connected": True, "tools": (outcome.get("tools") or [])[:MAX_LISTED_TOOLS],
                    "note": NEXT_MESSAGE_NOTE}
        return {"connected": False, "error": outcome.get("error") or "Sign-in failed."}

    async def disconnect_tool(self, name: str) -> dict[str, Any]:
        async with self.database.session() as session:
            record, problem = await self._find(session, name)
        if record is None:
            return _error(problem or "Tool not found.")
        if not ConfiguredRow.from_record(record).is_oauth:
            return _error(f"'{record.alias or record.name}' does not use OAuth sign-in.")
        await self.runtime.forget_oauth(record.uuid)
        return {"ok": True, "disconnected": record.alias or record.name}

    # --- tools: skills -----------------------------------------------------------------------
    @staticmethod
    def _skill_summary(skill: SkillInfo) -> dict[str, Any]:
        return {"name": skill.name, "description": _short(skill.description), "enabled": skill.enabled,
                "type": "builtin" if skill.uuid.startswith(BUILTIN_UUID_PREFIX) else skill.source_type,
                "valid": skill.valid}

    @staticmethod
    def _skill_by_name(skills: list[SkillInfo], name: str) -> SkillInfo | None:
        wanted = (name or "").strip().casefold()
        return next((s for s in skills if wanted in {s.name.casefold(), (s.alias or "").casefold(),
                                                      s.uuid.casefold()}), None)

    async def list_skills(self) -> list[dict[str, Any]]:
        async with self.database.session() as session:
            return [self._skill_summary(skill) for skill in await SkillService(session).snapshots()]

    async def get_skill_info(self, name: str) -> dict[str, Any]:
        async with self.database.session() as session:
            skill = self._skill_by_name(await SkillService(session).snapshots(), name)
        if skill is None:
            return _error(f"No skill named '{name}'.")
        info = self._skill_summary(skill)
        if skill.source_type == "text":
            info["instructions"] = skill.instructions
        else:
            info["folder"] = skill.source
            info["error"] = skill.error
        return info

    async def create_skill(self, name: str, description: str, instructions: str) -> dict[str, Any]:
        if len(instructions or "") > MAX_INSTRUCTIONS:
            return _error(f"Instructions are limited to {MAX_INSTRUCTIONS} characters.")
        try:
            async with self.database.session() as session:
                service = SkillService(session)
                if self._skill_by_name([s for s in await service.snapshots()
                                        if s.uuid.startswith(BUILTIN_UUID_PREFIX)], name) is not None:
                    return _error(f"'{name}' is a built-in skill name and cannot be replaced.")
                created = await service.create(UpsertSkillRequest(
                    name=name, description=description, source_type="text", instructions=instructions,
                    enabled=True))
        except ValueError as problem:
            _LOG.info("services.tool_management: request rejected: %s", problem)
            return _error(str(problem))
        return {"ok": True, "name": created.name}

    async def update_skill(self, name: str, description: str | None = None, instructions: str | None = None,
                           enabled: bool | None = None) -> dict[str, Any]:
        if instructions is not None and len(instructions) > MAX_INSTRUCTIONS:
            return _error(f"Instructions are limited to {MAX_INSTRUCTIONS} characters.")
        try:
            async with self.database.session() as session:
                service = SkillService(session)
                wanted = (name or "").strip().casefold()
                if any(s.uuid.startswith(BUILTIN_UUID_PREFIX) and s.name.casefold() == wanted
                       for s in await service.snapshots()) and not any(
                        dto.name.casefold() == wanted for dto in await service.list()):
                    return _error("Built-in skills are read-only.")
                dto = next((d for d in await service.list() if wanted in {
                    d.name.casefold(), (d.alias or "").casefold(), d.uuid.casefold()}), None)
                if dto is None:
                    return _error(f"No skill named '{name}'.")
                if instructions is not None and dto.source_type != "text":
                    return _error("Only text skills have instructions; this skill is a folder.")
                await service.update(dto.uuid, UpsertSkillRequest(
                    name=dto.name, alias=dto.alias,
                    description=description if description is not None else dto.description,
                    source_type=dto.source_type, source=dto.source,
                    instructions=instructions if instructions is not None else dto.instructions,
                    enabled=dto.enabled if enabled is None else enabled))
        except ValueError as problem:
            _LOG.info("services.tool_management: request rejected: %s", problem)
            return _error(str(problem))
        return {"ok": True, "name": dto.name}

    async def remove_skill(self, name: str) -> dict[str, Any]:
        async with self.database.session() as session:
            service = SkillService(session)
            wanted = (name or "").strip().casefold()
            dto = next((d for d in await service.list() if wanted in {
                d.name.casefold(), (d.alias or "").casefold(), d.uuid.casefold()}), None)
            if dto is None:
                builtin = any(s.uuid.startswith(BUILTIN_UUID_PREFIX) and s.name.casefold() == wanted
                              for s in await service.snapshots())
                return _error("Built-in skills are read-only." if builtin else f"No skill named '{name}'.")
            await service.delete(dto.uuid)
        return {"ok": True, "removed": dto.name}
