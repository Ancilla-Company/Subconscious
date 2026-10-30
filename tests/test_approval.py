import pytest

from subconscious_engine.approval import (
    CREATE, DELETE, READ, UPDATE, ApprovalConfig, classify_operation,
)


@pytest.mark.parametrize(("name", "operation"), [
    ("read_file", READ),
    ("list_todos", READ),
    ("search_custom", READ),
    ("get_status", READ),
    ("delete_note", DELETE),
    ("add_todo", CREATE),
    ("run_command", UPDATE),
    ("custom_tool", UPDATE),
    ("Read_File", UPDATE),
    ("", UPDATE),
])
def test_tools_are_classified_as_crud_and_unknown_operations_fail_closed(name, operation):
    assert classify_operation(name) == operation


def test_valid_config_controls_each_operation_class():
    config = ApprovalConfig.from_json(
        '{"create": true, "read": false, "update": true, "delete": false}'
    )
    assert config == ApprovalConfig(create=True, read=False, update=True, delete=False)
    assert config.requires("read_file") is False
    assert config.requires("add_todo") is True
    assert config.requires("run_command") is True
    assert config.requires("delete_note") is False


@pytest.mark.parametrize("raw", [None, "", "not-json", "[]", "null", "1"])
def test_missing_or_malformed_config_defaults_to_approval_required(raw):
    assert ApprovalConfig.from_json(raw) == ApprovalConfig()


def test_non_boolean_fields_default_independently_to_safe_value():
    assert ApprovalConfig.from_json('{"query": 0, "mutation": false}') == ApprovalConfig(
        query=True, mutation=False
    )


def test_frozen_config_cannot_be_mutated():
    config = ApprovalConfig()
    with pytest.raises(AttributeError):
        config.query = False


def test_requires_operation_uses_the_already_classified_operation_and_fails_closed():
    config = ApprovalConfig(create=True, read=False, update=False, delete=True)
    assert [config.requires_operation(op) for op in (CREATE, READ, UPDATE, DELETE)] == [True, False, False, True]
    assert config.requires_operation("bogus") is True
    # requires(name) is requires_operation(classify_operation(name))
    assert config.requires("get_thing") is config.requires_operation(READ) is False


def test_platform_read_tools_never_ask_even_with_the_safe_default_policy():
    from subconscious_engine.approval import PLATFORM_READ_TOOLS

    strict = ApprovalConfig()  # everything asks by default
    assert all(strict.requires(name) is False for name in PLATFORM_READ_TOOLS)
    for name in ("list_configured_tools", "get_configured_tool", "list_skills", "get_skill_info",
                 "read_skill", "list_todos", "search_knowledge", "read_context_file", "calculate"):
        assert strict.requires(name) is False


def test_platform_read_exemption_does_not_cover_writes_filesystem_weather_or_prefixed_tools():
    strict = ApprovalConfig()
    for name in ("add_mcp_server", "add_cli_tool", "update_configured_tool", "remove_configured_tool",
                 "test_configured_tool", "connect_tool", "create_skill", "remember", "save_note",
                 "read_filesystem_file", "list_filesystem_directory", "get_current_weather",
                 "run_command", "set_ui_theme_color"):
        assert strict.requires(name) is True, name
    # A remote or MCP tool that merely shares a platform tool's name is still asked about.
    assert strict.requires("someserver__list_skills") is True
    assert strict.requires("someserver__calculate") is True


def test_agent_session_tools_follow_the_invocation_rule():
    strict = ApprovalConfig()
    # Invoking an agent is a change the user approves; listing sessions is a platform read.
    assert strict.requires("start_agent_session") is True
    assert strict.requires("send_agent_session") is True
    assert strict.requires("list_agent_sessions") is False
    assert ApprovalConfig(update=False).requires("start_agent_session") is False
    # Ending a session is always allowed: the tool sets requires_approval=False itself.
    assert classify_operation("end_agent_session") == UPDATE
