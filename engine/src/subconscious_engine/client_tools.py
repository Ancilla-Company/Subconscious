"""Client-defined tools: validation of ``tool.register`` payloads and the engine-wide catalog.

A client (browser extension, VS Code extension, ...) registers groups of tools on its
``/api/v1/events`` WebSocket. This module only holds the pure parts: parsing/validation and the
remembered catalog. The WebSocket session wires them into chat turns.
"""

from __future__ import annotations

import json
import re
from collections.abc import Collection, Hashable
from dataclasses import dataclass, field
from typing import Any

from subconscious_engine.approval import CREATE, DELETE, READ, UPDATE

EXECUTE = "execute"
OPERATIONS = frozenset({CREATE, READ, UPDATE, DELETE, EXECUTE})

GROUP_PATTERN = re.compile(r"^[a-z][a-z0-9_]{0,31}$")
TOOL_ID_PATTERN = re.compile(r"^[A-Za-z][A-Za-z0-9_.\-]{0,63}$")
MAX_DESCRIPTION = 2000
MAX_SCHEMA_BYTES = 32 * 1024
MAX_TOOLS_PER_GROUP = 64
MAX_GROUPS_PER_CONNECTION = 8
MAX_TIMEOUT_SECONDS = 300
MAX_TITLE = 100


class ClientToolError(ValueError):
    """A ``tool.register`` payload that cannot be accepted (message is sent to the client)."""


@dataclass(frozen=True, slots=True)
class ClientToolDefinition:
    id: str
    description: str
    input_schema: dict[str, Any]
    operation: str  # as declared (read, create, update, delete, execute); shown to the user
    read_only: bool = False
    timeout_seconds: float | None = None

    @property
    def approval_operation(self) -> str:
        """The operation the approval settings apply to (``execute`` counts as ``update``)."""
        return UPDATE if self.operation == EXECUTE else self.operation


@dataclass(frozen=True, slots=True)
class ClientToolGroup:
    group: str
    title: str
    tools: tuple[ClientToolDefinition, ...] = field(default_factory=tuple)

    def tool(self, tool_id: str) -> ClientToolDefinition | None:
        return next((tool for tool in self.tools if tool.id == tool_id), None)


def is_schema_registration(data: dict[str, Any]) -> bool:
    """True when the payload uses the schema-bearing protocol rather than the legacy UI ids."""
    if "group" in data:
        return True
    tools = data.get("tools")
    return isinstance(tools, list) and any(
        isinstance(tool, dict) and "input_schema" in tool for tool in tools)


def parse_group(data: dict[str, Any], *, reserved: Collection[str] = ()) -> ClientToolGroup:
    """Validate a schema-bearing ``tool.register`` payload; raise ``ClientToolError`` otherwise."""
    group = data.get("group")
    if not isinstance(group, str) or not GROUP_PATTERN.match(group):
        raise ClientToolError("group must match ^[a-z][a-z0-9_]{0,31}$.")
    if group in reserved:
        raise ClientToolError(f"group '{group}' is the name of a built-in tool group.")
    title = data.get("title", group)
    if not isinstance(title, str):
        raise ClientToolError("title must be a string.")
    title = title.strip()[:MAX_TITLE] or group
    tools = data.get("tools", [])
    if not isinstance(tools, list):
        raise ClientToolError("tools must be a list.")
    if len(tools) > MAX_TOOLS_PER_GROUP:
        raise ClientToolError(f"a group can have at most {MAX_TOOLS_PER_GROUP} tools.")
    definitions: dict[str, ClientToolDefinition] = {}
    for raw in tools:
        definition = _parse_tool(raw)
        if definition.id in definitions:
            raise ClientToolError(f"duplicate tool id '{definition.id}'.")
        definitions[definition.id] = definition
    return ClientToolGroup(group, title, tuple(definitions.values()))


def _parse_tool(raw: Any) -> ClientToolDefinition:
    if not isinstance(raw, dict):
        raise ClientToolError("each tool must be an object.")
    tool_id = raw.get("id")
    if not isinstance(tool_id, str) or not TOOL_ID_PATTERN.match(tool_id):
        raise ClientToolError("tool id must match ^[A-Za-z][A-Za-z0-9_.\\-]{0,63}$.")
    description = raw.get("description", "")
    if not isinstance(description, str) or len(description) > MAX_DESCRIPTION:
        raise ClientToolError(f"tool '{tool_id}': description must be a string of at most "
                              f"{MAX_DESCRIPTION} characters.")
    schema = raw.get("input_schema")
    if not isinstance(schema, dict) or schema.get("type") != "object":
        raise ClientToolError(f"tool '{tool_id}': input_schema must be a JSON object with type 'object'.")
    try:
        size = len(json.dumps(schema).encode("utf-8"))
    except (TypeError, ValueError) as error:
        raise ClientToolError(f"tool '{tool_id}': input_schema is not valid JSON.") from error
    if size > MAX_SCHEMA_BYTES:
        raise ClientToolError(f"tool '{tool_id}': input_schema exceeds {MAX_SCHEMA_BYTES // 1024} KiB.")
    read_only = raw.get("read_only", False)
    if not isinstance(read_only, bool):
        raise ClientToolError(f"tool '{tool_id}': read_only must be a boolean.")
    operation = raw.get("operation", READ if read_only else UPDATE)
    if not isinstance(operation, str) or operation.strip().casefold() not in OPERATIONS:
        raise ClientToolError(
            f"tool '{tool_id}': operation must be one of read, create, update, delete, execute.")
    operation = READ if read_only else operation.strip().casefold()
    timeout = raw.get("timeout_seconds")
    if timeout is not None:
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) \
                or not 0 < timeout <= MAX_TIMEOUT_SECONDS:
            raise ClientToolError(
                f"tool '{tool_id}': timeout_seconds must be a number in (0, {MAX_TIMEOUT_SECONDS}].")
        timeout = float(timeout)
    return ClientToolDefinition(tool_id, description.strip(), schema, operation, read_only, timeout)


class ClientToolCatalog:
    """Engine-wide memory of client tool groups (latest registration wins).

    Definitions are remembered after the owning connection goes away so the tools settings UI
    can still show and toggle them; ``live`` tells which are currently offered by a connection.
    """

    def __init__(self) -> None:
        self._groups: dict[str, ClientToolGroup] = {}
        self._owners: dict[str, set[Hashable]] = {}

    def register(self, owner: Hashable, group: ClientToolGroup) -> None:
        self._groups[group.group] = group
        self._owners.setdefault(group.group, set()).add(owner)

    def unregister(self, owner: Hashable, group: str) -> None:
        self._owners.get(group, set()).discard(owner)

    def disconnect(self, owner: Hashable) -> None:
        for owners in self._owners.values():
            owners.discard(owner)

    def is_live(self, group: str) -> bool:
        return bool(self._owners.get(group))

    def live_groups(self) -> set[str]:
        return {name for name, owners in self._owners.items() if owners}

    def get(self, group: str) -> ClientToolGroup | None:
        return self._groups.get(group)

    def catalog(self) -> dict[str, list[dict[str, str]]]:
        """``{group: [{name, doc, operation}]}`` in the shape of ``ToolRegistry.catalog()``."""
        return {
            name: [{"name": tool.id, "doc": tool.description, "operation": tool.operation}
                   for tool in group.tools]
            for name, group in self._groups.items() if group.tools
        }


def tool_enabled(config: dict[str, Any], group: str, tool_id: str) -> bool:
    """The ``tools_config`` toggles (builtin_enabled / builtin[group].enabled / .tools[id])."""
    if config.get("builtin_enabled", True) is False:
        return False
    builtin = config.get("builtin")
    group_config = builtin.get(group) if isinstance(builtin, dict) else None
    if not isinstance(group_config, dict):
        return True
    if group_config.get("enabled", True) is False:
        return False
    overrides = group_config.get("tools")
    return not (isinstance(overrides, dict) and overrides.get(tool_id, True) is False)
