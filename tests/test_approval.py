import pytest

from subconscious_engine.approval import (
    MUTATION, QUERY, ApprovalConfig, classify_operation,
)


@pytest.mark.parametrize("name", ["read_file", "list_todos", "search_custom", "get_status"])
def test_known_and_prefixed_read_operations_are_queries(name):
    assert classify_operation(name) == QUERY


@pytest.mark.parametrize("name", ["delete_note", "run_command", "custom_tool", "Read_File", ""])
def test_known_unknown_and_ambiguous_operations_fail_closed_as_mutations(name):
    assert classify_operation(name) == MUTATION


def test_valid_config_controls_each_operation_class():
    config = ApprovalConfig.from_json('{"query": false, "mutation": true}')
    assert config == ApprovalConfig(query=False, mutation=True)
    assert config.requires("read_file") is False
    assert config.requires("run_command") is True


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
