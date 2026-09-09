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
