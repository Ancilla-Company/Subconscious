"""Safe-by-default human approval policy and tool classification."""

from dataclasses import dataclass
import json

QUERY = "query"
MUTATION = "mutation"

_QUERY_TOOLS = frozenset({
    "get_current_time", "get_current_date", "convert_timezone", "list_common_timezones",
    "calculate", "convert_units", "list_supported_units", "get_weather", "get_forecast",
    "list_todos", "recall", "list_memories", "list_notes", "get_note",
    "list_contacts", "find_contact", "search_knowledge", "search_knowledge_graph",
    "read_file", "read_range", "search_in_file", "search_files", "list_directory",
})
_MUTATION_TOOLS = frozenset({
    "add_todo", "update_todo", "complete_todo", "delete_todo", "remember", "forget",
    "forget_all", "save_note", "delete_note", "add_contact", "update_contact",
    "delete_contact", "create_file", "replace_in_file", "run_command",
})
_QUERY_PREFIXES = ("get_", "list_", "read_", "find_", "search_", "fetch_", "check_",
                   "view_", "show_", "describe_", "lookup_", "recall")


def classify_operation(tool_name: str) -> str:
    if tool_name in _MUTATION_TOOLS:
        return MUTATION
    if tool_name in _QUERY_TOOLS or tool_name.startswith(_QUERY_PREFIXES):
        return QUERY
    return MUTATION


@dataclass(frozen=True, slots=True)
class ApprovalConfig:
    query: bool = True
    mutation: bool = True

    @classmethod
    def from_json(cls, raw: str | None) -> "ApprovalConfig":
        try:
            value = json.loads(raw) if raw else {}
        except (TypeError, json.JSONDecodeError):
            return cls()
        if not isinstance(value, dict):
            return cls()
        query_value = value.get("query")
        mutation_value = value.get("mutation")
        return cls(query=query_value if isinstance(query_value, bool) else True,
                   mutation=mutation_value if isinstance(mutation_value, bool) else True)

    def requires(self, tool_name: str) -> bool:
        return self.query if classify_operation(tool_name) == QUERY else self.mutation
