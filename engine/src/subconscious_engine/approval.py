"""Safe-by-default human approval policy and CRUD tool classification."""

from dataclasses import dataclass
import json
import logging
_LOG = logging.getLogger(__name__)

CREATE = "create"
READ = "read"
UPDATE = "update"
DELETE = "delete"
# Source-compatible names for older integrations.
QUERY = READ
MUTATION = UPDATE

_EXPLICIT: dict[str, str] = {
    "calculate": READ, "convert_units": READ, "convert_timezone": READ,
    "remember": CREATE, "save_note": CREATE, "search_knowledge": READ,
    "complete_todo": UPDATE, "replace_in_file": UPDATE, "run_command": UPDATE,
    "forget": DELETE, "forget_all": DELETE,
    # Tool/skill management (see services.tool_management; approval is forced for these anyway).
    "test_configured_tool": UPDATE, "connect_tool": UPDATE, "disconnect_tool": UPDATE,
    "add_mcp_server": CREATE, "add_cli_tool": CREATE, "create_skill": CREATE,
    "update_configured_tool": UPDATE, "update_skill": UPDATE,
    "remove_configured_tool": DELETE, "remove_skill": DELETE,
    "list_configured_tools": READ, "get_configured_tool": READ, "list_skills": READ, "get_skill_info": READ,
    # Persistent ACP agent sessions (services.acp_session_tools). Ending one never asks.
    "start_agent_session": UPDATE, "send_agent_session": UPDATE, "end_agent_session": UPDATE,
    "list_agent_sessions": READ,
}
# Read-only tools that exist only because of the Subconscious platform: they read the app's
# own state (workspace data, configuration, skills, the files the user put in this turn) or are
# pure computation. They never need a human decision, whatever the user's read policy says.
# Not included on purpose: filesystem tools (they read any path on the machine), weather
# (network), and everything that creates, changes, deletes or runs something.
PLATFORM_READ_TOOLS: frozenset[str] = frozenset({
    # tool and skill management (listing only; the mutating ones stay approval-gated)
    "list_configured_tools", "get_configured_tool", "list_skills", "get_skill_info", "read_skill",
    "list_agent_sessions",
    # workspace data
    "list_todos", "recall", "list_memories", "list_notes", "get_note", "list_contacts", "find_contact",
    "search_knowledge",
    # this turn's context
    "list_context_files", "read_context_file", "read_attachment",
    # pure computation
    "get_current_time", "get_current_date", "convert_timezone", "list_common_timezones",
    "calculate", "convert_units", "list_supported_units",
})
_PREFIXES: tuple[tuple[str, str], ...] = (
    (("add_", "create_", "insert_", "new_"), CREATE),
    (("get_", "list_", "read_", "find_", "search_", "fetch_", "check_",
      "view_", "show_", "describe_", "lookup_", "recall"), READ),
    (("delete_", "remove_", "forget_", "purge_"), DELETE),
    (("update_", "edit_", "set_", "replace_", "complete_", "run_", "write_",
      "move_", "copy_", "rename_"), UPDATE),
)


def is_platform_read_tool(tool_name: str) -> bool:
    """True for a built-in, read-only platform tool. Prefixed (MCP/remote) names never match."""
    return "__" not in tool_name and tool_name in PLATFORM_READ_TOOLS


def classify_operation(tool_name: str) -> str:
    # Remote tools are named "<node alias>__<tool>"; classify by the tool itself.
    tool_name = tool_name.rpartition("__")[2] or tool_name
    explicit = _EXPLICIT.get(tool_name)
    if explicit is not None:
        return explicit
    for prefixes, operation in _PREFIXES:
        if tool_name.startswith(prefixes):
            return operation
    return UPDATE


@dataclass(frozen=True, init=False)
class ApprovalConfig:
    create: bool
    read: bool
    update: bool
    delete: bool

    def __init__(self, create: bool = True, read: bool = True,
                 update: bool = True, delete: bool = True, *,
                 query: bool | None = None, mutation: bool | None = None) -> None:
        if query is not None:
            read = query
        if mutation is not None:
            create = update = delete = mutation
        object.__setattr__(self, "create", create)
        object.__setattr__(self, "read", read)
        object.__setattr__(self, "update", update)
        object.__setattr__(self, "delete", delete)

    @property
    def query(self) -> bool:
        return self.read

    @property
    def mutation(self) -> bool:
        return self.update

    @classmethod
    def from_json(cls, raw: str | None) -> "ApprovalConfig":
        try:
            value = json.loads(raw) if raw else {}
        except (TypeError, json.JSONDecodeError):
            _LOG.warning("approval.ApprovalConfig.from_json: handled (TypeError, json.JSONDecodeError); continuing with fallback", exc_info=True)
            return cls()
        if not isinstance(value, dict):
            return cls()
        legacy_read = value.get("query") if isinstance(value.get("query"), bool) else True
        legacy_write = value.get("mutation") if isinstance(value.get("mutation"), bool) else True

        def setting(name: str, fallback: bool) -> bool:
            if name not in value:
                return fallback
            candidate = value[name]
            return candidate if isinstance(candidate, bool) else True

        return cls(
            create=setting("create", legacy_write),
            read=setting("read", legacy_read),
            update=setting("update", legacy_write),
            delete=setting("delete", legacy_write),
        )

    def requires(self, tool_name: str) -> bool:
        if is_platform_read_tool(tool_name):
            return False
        return bool(getattr(self, classify_operation(tool_name)))

    def requires_operation(self, operation: str) -> bool:
        """Approval needed for an already-classified operation; unknown operations always ask."""
        if operation not in {CREATE, READ, UPDATE, DELETE}:
            return True
        return bool(getattr(self, operation))
