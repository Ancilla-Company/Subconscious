"""Tools that let the assistant create and manage agents from chat.

Built per chat turn by :class:`AgentTools`. Security model: every tool that creates, changes or
deletes an agent requires human approval REGARDLESS of the user's ``ApprovalConfig`` (an agent
carries instructions and tool/approval settings, and text inside tool output must never be able
to add or loosen one silently). Listing and reading follow the normal read policy. Validation is
the REST layer's (``AgentDefinitionService``); failures are returned as ``{"ok": False, "error":
...}`` so the model can react, not raised.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Awaitable, Callable, Collection
from typing import Any

from pydantic_ai import Tool

from subconscious_engine.api.agent_routes import agent_event
from subconscious_engine.api.extra_schemas import AgentDto, UpsertAgentRequest
from subconscious_engine.approval import ApprovalConfig
from subconscious_engine.services.agent_definitions import AgentDefinitionService

_LOG = logging.getLogger(__name__)

FORCED_APPROVAL = frozenset({"create_agent", "update_agent", "delete_agent"})
READ_ONLY = frozenset({"list_agents", "get_agent"})
_SCOPES = ("workspace", "account")
_APPROVAL_KEYS = ("create", "read", "update", "delete")
_TOOLS_FORMAT = ('{"builtin_enabled": true, "builtin": {"<group>": {"enabled": true, '
                 '"tools": {"<tool name>": false}}}}')


def _error(message: str, **extra: Any) -> dict[str, Any]:
    return {"ok": False, "error": message, **extra}


def _parse(raw: str | None) -> dict[str, Any] | None:
    if not raw:
        return None
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        _LOG.warning("services.agent_tools._parse: stored configuration is not JSON", exc_info=True)
        return None
    return value if isinstance(value, dict) else None


def _summary(agent: AgentDto) -> dict[str, Any]:
    return {"id": agent.uuid, "name": agent.name, "description": agent.description,
            "scope": "account" if agent.workspace_uuid is None else "workspace",
            "enabled": agent.enabled, "model": agent.default_model_id,
            "customTools": agent.tools_config is not None,
            "customApprovals": agent.approval_config is not None}


class AgentTools:
    """Per-engine collaborators for the agent tools; :meth:`tools` builds one turn's set."""

    def __init__(self, database: Any,
                 publish: Callable[[str, dict[str, Any]], Awaitable[None]] | None = None) -> None:
        self.database = database
        self.publish = publish

    def tools(self, approval: ApprovalConfig, *, workspace_uuid: str | None,
              reserved: Collection[str] = ()) -> list[Tool[Any]]:
        """The agent tools for a chat in ``workspace_uuid`` (the default home of a new agent)."""

        async def list_agents() -> list[dict[str, Any]]:
            async with self.database.session() as session:
                return [_summary(agent) for agent in
                        await AgentDefinitionService(session).list_all(workspace_uuid)]

        async def get_agent(name: str) -> dict[str, Any]:
            async with self.database.session() as session:
                agent, problem = await self._find(session, name, workspace_uuid)
            if agent is None:
                return _error(problem or f"No agent named '{name}'.")
            return {**_summary(agent), "instructions": agent.instructions,
                    "toolsConfig": _parse(agent.tools_config), "approvalConfig": _parse(agent.approval_config)}

        async def create_agent(name: str, description: str | None = None, instructions: str | None = None,
                               scope: str = "workspace", model_id: str | None = None,
                               tools_config: dict[str, Any] | None = None,
                               approval_config: dict[str, bool] | None = None) -> dict[str, Any]:
            owner, problem = self._owner(scope, workspace_uuid)
            if problem is not None:
                return _error(problem)
            problem = self._check_approval_config(approval_config)
            if problem is not None:
                return _error(problem)
            try:
                async with self.database.session() as session:
                    created = await AgentDefinitionService(session).create(UpsertAgentRequest(
                        name=name, description=description, instructions=instructions,
                        default_model_id=model_id, workspace_uuid=owner,
                        tools_config=None if tools_config is None else json.dumps(tools_config),
                        approval_config=None if approval_config is None else json.dumps(approval_config)))
            except ValueError as rejected:
                _LOG.info("services.agent_tools.create_agent: rejected: %s", rejected)
                return _error(str(rejected))
            await self._announce("agent.created", created)
            return {"ok": True, "id": created.uuid, "name": created.name, "scope": _summary(created)["scope"]}

        async def update_agent(name: str, new_name: str | None = None, description: str | None = None,
                               instructions: str | None = None, model_id: str | None = None,
                               enabled: bool | None = None, scope: str | None = None,
                               tools_config: dict[str, Any] | None = None,
                               approval_config: dict[str, bool] | None = None,
                               inherit_tools: bool = False,
                               inherit_approvals: bool = False) -> dict[str, Any]:
            problem = self._check_approval_config(approval_config)
            if problem is not None:
                return _error(problem)
            fields: dict[str, Any] = {}
            for key, value in (("name", new_name), ("description", description),
                               ("instructions", instructions), ("default_model_id", model_id),
                               ("enabled", enabled)):
                if value is not None:
                    fields[key] = value
            if scope is not None:
                owner, problem = self._owner(scope, workspace_uuid)
                if problem is not None:
                    return _error(problem)
                fields["workspace_uuid"] = owner
            if tools_config is not None:
                fields["tools_config"] = json.dumps(tools_config)
            elif inherit_tools:
                fields["tools_config"] = None
            if approval_config is not None:
                fields["approval_config"] = json.dumps(approval_config)
            elif inherit_approvals:
                fields["approval_config"] = None
            if not fields:
                return _error("Nothing to change: pass at least one field to update.")
            try:
                async with self.database.session() as session:
                    found, problem = await self._find(session, name, workspace_uuid)
                    if found is None:
                        return _error(problem or f"No agent named '{name}'.")
                    updated = await AgentDefinitionService(session).update(
                        found.uuid, UpsertAgentRequest(**fields))
            except ValueError as rejected:
                _LOG.info("services.agent_tools.update_agent: rejected: %s", rejected)
                return _error(str(rejected))
            if updated is None:
                return _error(f"No agent named '{name}'.")
            await self._announce("agent.updated", updated)
            return {"ok": True, "id": updated.uuid, "name": updated.name}

        async def delete_agent(name: str) -> dict[str, Any]:
            async with self.database.session() as session:
                found, problem = await self._find(session, name, workspace_uuid)
                if found is None:
                    return _error(problem or f"No agent named '{name}'.")
                await AgentDefinitionService(session).delete(found.uuid)
            await self._announce("agent.deleted", found)
            return {"ok": True, "removed": found.name}

        handlers: dict[str, tuple[Callable[..., Awaitable[Any]], str]] = {
            "list_agents": (list_agents, (
                "List the agents available here: the account-wide ones and those of this workspace "
                "(name, description, scope, enabled, model).")),
            "get_agent": (get_agent, (
                "Show one agent's details, including its instructions and tool/approval settings. "
                "`name` is its name or id.")),
            "create_agent": (create_agent, (
                "Create an agent: a reusable assistant profile. `description` says what it is for; "
                "`instructions` is its system prompt (up to 20000 characters). `scope` is 'workspace' "
                "(this workspace, the default) or 'account' (available in every workspace). "
                "`tools_config` limits its tools, in the format " + _TOOLS_FORMAT + " (omit it to "
                "inherit the workspace's tools). `approval_config` is {\"create\":bool,\"read\":bool,"
                "\"update\":bool,\"delete\":bool}: true asks the user before that kind of tool runs, "
                "false lets it run without asking; omit it to inherit the workspace's, and never "
                "loosen it unless the user asked. Requires user approval.")),
            "update_agent": (update_agent, (
                "Change an agent. Only the fields you pass change. `new_name` renames it; `scope` "
                "moves it between this workspace and the account. `inherit_tools` / `inherit_approvals` "
                "reset those settings to the workspace's. Same formats as create_agent. "
                "Requires user approval.")),
            "delete_agent": (delete_agent, "Delete an agent. Requires user approval."),
        }
        built: list[Tool[Any]] = []
        for name, (function, description) in handlers.items():
            if name in reserved:
                _LOG.warning("services.agent_tools.AgentTools.tools: %s skipped, name already in use", name)
                continue
            built.append(Tool(function, name=name, description=description,
                              requires_approval=True if name in FORCED_APPROVAL else approval.requires(name)))
        return built

    @staticmethod
    def _owner(scope: str, workspace_uuid: str | None) -> tuple[str | None, str | None]:
        wanted = (scope or "").strip().casefold()
        if wanted not in _SCOPES:
            return None, "scope must be 'workspace' or 'account'."
        if wanted == "account":
            return None, None
        if workspace_uuid is None:
            return None, "There is no current workspace; use scope='account'."
        return workspace_uuid, None

    @staticmethod
    def _check_approval_config(value: dict[str, bool] | None) -> str | None:
        if value is None:
            return None
        if any(key not in _APPROVAL_KEYS or not isinstance(flag, bool) for key, flag in value.items()):
            return "approval_config may only contain create, read, update and delete, each true or false."
        return None

    async def _find(self, session: Any, name: str,
                    workspace_uuid: str | None) -> tuple[AgentDto | None, str | None]:
        """Resolve an id or name among the agents visible here; ambiguity is an error naming them."""
        wanted = (name or "").strip().casefold()
        if not wanted:
            return None, "An agent name is required."
        visible = await AgentDefinitionService(session).list_all(workspace_uuid)
        matches = [a for a in visible if a.uuid.casefold() == wanted] \
            or [a for a in visible if a.name.casefold() == wanted]
        if len(matches) == 1:
            return matches[0], None
        if not matches:
            known = ", ".join(sorted(a.name for a in visible)) or "none"
            return None, f"No agent named '{name}'. Known agents: {known}."
        listing = "; ".join(f"{a.name} ({_summary(a)['scope']}, id {a.uuid})" for a in matches)
        return None, f"'{name}' is ambiguous: {listing}. Use the id."

    async def _announce(self, event: str, agent: AgentDto) -> None:
        if self.publish is not None:
            await self.publish(event, agent_event(agent))
