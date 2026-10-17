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
}
_PREFIXES: tuple[tuple[str, str], ...] = (
    (("add_", "create_", "insert_", "new_"), CREATE),
    (("get_", "list_", "read_", "find_", "search_", "fetch_", "check_",
      "view_", "show_", "describe_", "lookup_", "recall"), READ),
    (("delete_", "remove_", "forget_", "purge_"), DELETE),
    (("update_", "edit_", "set_", "replace_", "complete_", "run_", "write_",
      "move_", "copy_", "rename_"), UPDATE),
)


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
        return bool(getattr(self, classify_operation(tool_name)))
