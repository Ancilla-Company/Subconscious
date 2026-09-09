import asyncio
import json
from datetime import datetime
from unittest.mock import AsyncMock, patch

import pytest

from subconscious_engine.approval import ApprovalConfig
from subconscious_engine.api.schemas import CreateWorkspaceRequest
from subconscious_engine.services.rag_service import WorkspaceRagService
from subconscious_engine.services.workspaces import WorkspaceService
from subconscious_engine.storage.database import Database
from subconscious_engine.tools.database_tools import database_tool_entries
from subconscious_engine.tools.registry import (
    ToolContext, ToolRegistry, calculate, convert_timezone, convert_units,
    get_current_date, get_current_time, get_current_weather, get_weather_forecast,
    list_common_timezones, list_supported_units, merge_tool_config,
)


def run(coro):
    return asyncio.run(coro)


def test_merge_tool_config_deeply_overrides_without_mutating_and_validates_objects():
    workspace = json.dumps({"builtin_enabled": True, "builtin": {
        "todo": {"enabled": True, "tools": {"add_todo": True, "delete_todo": True}},
        "notes": {"enabled": True},
    }})
    thread = json.dumps({"builtin": {
        "todo": {"tools": {"delete_todo": False}}, "notes": {"enabled": False},
    }})
    merged = json.loads(merge_tool_config(workspace, thread))
    assert merged["builtin"]["todo"] == {
        "enabled": True, "tools": {"add_todo": True, "delete_todo": False}}
    assert merged["builtin"]["notes"] == {"enabled": False}
    assert merge_tool_config(workspace, None) == workspace
    assert merge_tool_config(None, None) is None
    with pytest.raises(ValueError, match="JSON object"):
        merge_tool_config("[]", "{}")
    with pytest.raises(json.JSONDecodeError):
        merge_tool_config("{}", "not-json")


def test_registry_catalog_configuration_and_approval_flags():
    registry = ToolRegistry()
    catalog = registry.catalog()
    assert {key: len(value) for key, value in catalog.items()} == {
        "time": 4, "calculator": 3, "weather": 2, "todo": 5, "memory": 5,
        "notes": 4, "contacts": 5, "knowledge": 1,
    }
    assert next(item for item in catalog["todo"] if item["name"] == "add_todo")["operation"] == "create"
    assert next(item for item in catalog["todo"] if item["name"] == "list_todos")["operation"] == "read"
    context = ToolContext(WorkspaceRagService(), object(), "workspace")
    approval = ApprovalConfig(create=True, read=False, update=True, delete=True)
    tools = registry.tools_for_config(json.dumps({"builtin": {
        "weather": {"enabled": False},
        "todo": {"tools": {"delete_todo": False}},
    }}), context, approval)
    by_name = {tool.name: tool for tool in tools}
    assert "get_current_weather" not in by_name and "get_weather_forecast" not in by_name
    assert "delete_todo" not in by_name
    assert by_name["list_todos"].requires_approval is False
    assert by_name["add_todo"].requires_approval is True
    assert registry.tools_for_config('{"builtin_enabled": false}', context, approval) == []
    with pytest.raises(ValueError, match="JSON object"):
        registry.tools_for_config("[]", context, approval)


def test_calculator_units_and_timezones_cover_success_and_errors():
    assert calculate("2 + 3 * 4") == "14"
    assert calculate("-(7 // 2) + 2 ** 3") == "5"
    for expression, message in [
        ("__import__('os')", "unsupported"), ("True + 1", "unsupported"),
        ("2 ** 101", "Exponent"), ("1e309", "not finite"), ("1" * 501, "too long"),
    ]:
        with pytest.raises((ValueError, SyntaxError), match=message):
            calculate(expression)
    assert convert_units(1, "KM", "m") == 1000
    assert convert_units(2.2046226218487757, "lb", "kg") == pytest.approx(1.0)
    with pytest.raises(ValueError, match="unknown or incompatible"):
        convert_units(1, "kg", "m")
    assert list_supported_units() == {
        "length": ["m", "km", "cm", "mm", "in", "ft"],
        "mass": ["g", "kg", "lb"], "time": ["s", "min", "h"]}
    assert convert_timezone("2024-01-15T12:00:00", "UTC", "America/New_York") == \
        "2024-01-15T07:00:00-05:00"
    assert convert_timezone("2024-01-15T12:00:00+00:00", "Asia/Tokyo", "UTC") == \
        "2024-01-15T12:00:00+00:00"
    assert "UTC" in list_common_timezones()


def test_current_time_and_date_are_deterministic_when_clock_is_mocked():
    class FixedDateTime(datetime):
        @classmethod
        def now(cls, tz=None):
            return cls(2024, 6, 1, 12, 34, 56, tzinfo=tz)

    with patch("subconscious_engine.tools.registry.datetime", FixedDateTime):
        assert get_current_time("UTC") == "2024-06-01T12:34:56+00:00"
        assert get_current_date("UTC") == "2024-06-01"


def test_weather_formatting_and_failures_use_mocked_fetch_only():
    current = {"current_condition": [{"temp_C": "18", "FeelsLikeC": "17",
        "weatherDesc": [{"value": "Clear"}], "humidity": "40", "windspeedKmph": "8",
        "winddir16Point": "N", "precipMM": "0", "pressure": "1012",
        "visibility": "10", "cloudcover": "5"}]}
    with patch("subconscious_engine.tools.registry._weather_data", AsyncMock(return_value=current)):
        text = run(get_current_weather("Paris"))
    assert "Weather in Paris" in text and "Condition: Clear" in text and "18°C" in text
    forecast = {"weather": [{"date": "2024-06-01", "mintempC": "10", "maxtempC": "20",
        "avgtempC": "15", "hourly": [{"weatherDesc": [{"value": "Sunny"}]}],
        "totalSnow_cm": "0", "sunHour": "12", "uvIndex": "4"}]}
    with patch("subconscious_engine.tools.registry._weather_data", AsyncMock(return_value=forecast)):
        text = run(get_weather_forecast("Paris", days=9))
    assert text.startswith("3-day forecast for Paris") and "Condition: Sunny" in text
    with patch("subconscious_engine.tools.registry._weather_data", AsyncMock(return_value={})):
        assert run(get_current_weather("X")) == "Could not retrieve weather data for 'X'."
        assert run(get_weather_forecast("X")) == "Could not retrieve forecast data for 'X'."
    with patch("subconscious_engine.tools.registry._weather_data",
               AsyncMock(side_effect=ValueError("offline"))):
        assert run(get_current_weather("X")) == "Failed to fetch weather data: offline"
        assert run(get_weather_forecast("X")) == "Failed to fetch forecast data: offline"


async def configured_context(path):
    database = Database(path)
    await database.initialize()
    async with database.session() as session:
        first = await WorkspaceService(session).create(CreateWorkspaceRequest(name="First"))
        second = await WorkspaceService(session).create(CreateWorkspaceRequest(name="Second"))
    return database, ToolContext(WorkspaceRagService(), database, first.uuid), second.uuid


def tool_functions(context):
    return {name: factory(context) for _, name, _, factory in database_tool_entries()}


def test_todo_and_memory_tools_use_real_sqlite_and_isolate_workspaces(tmp_path):
    async def scenario():
        database, context, other_uuid = await configured_context(tmp_path / "todo-memory.db")
        try:
            tools = tool_functions(context)
            first = await tools["add_todo"]("Ship", "details", "high", "2025-01-02")
            todo_id = first["todo"]["id"]
            await tools["add_todo"]("Later", priority="low")
            assert [item["title"] for item in (await tools["list_todos"](priority="high"))["todos"]] == ["Ship"]
            updated = await tools["update_todo"](todo_id, title="", notes="", status="blocked",
                                                   priority="urgent", due_date="")
            assert updated["todo"] == {"id": todo_id, "title": "Ship", "notes": "",
                "priority": "urgent", "status": "blocked", "due_date": None}
            assert (await tools["complete_todo"](todo_id))["status"] == "success"
            assert (await tools["delete_todo"](todo_id))["status"] == "success"
            for name in ("update_todo", "complete_todo", "delete_todo"):
                assert (await tools[name](999))["message"] == "Todo not found"

            assert await tools["list_memories"]() == "No memories stored."
            assert await tools["remember"]("z", "one") == "Remembered z = one"
            await tools["remember"]("a", "first")
            await tools["remember"]("z", "updated")
            assert await tools["recall"]("z") == "updated"
            assert await tools["list_memories"]() == "a = first\nz = updated"
            other = tool_functions(ToolContext(context.rag, database, other_uuid))
            assert await other["list_memories"]() == "No memories stored."
            assert await tools["forget"]("missing") == "No memory found for key 'missing'"
            assert await tools["forget"]("a") == "Forgot a"
            assert await tools["forget_all"]() == "Cleared 1 memories from workspace."
        finally:
            await database.close()
    run(scenario())


def test_note_and_contact_tools_use_real_sqlite_and_cover_not_found(tmp_path):
    async def scenario():
        database, context, _ = await configured_context(tmp_path / "notes-contacts.db")
        try:
            tools = tool_functions(context)
            note = await tools["save_note"]("Plan", "body", "work,urgent")
            await tools["save_note"]("Home", "chores", "personal")
            note_id = note["note"]["id"]
            assert [item["title"] for item in (await tools["list_notes"]("urgent"))["notes"]] == ["Plan"]
            fetched = await tools["get_note"](note_id)
            assert fetched["note"]["content"] == "body"
            assert (await tools["get_note"](999))["message"] == "Note not found"
            assert (await tools["delete_note"](note_id))["status"] == "success"
            assert (await tools["delete_note"](note_id))["message"] == "Note not found"

            amy = await tools["add_contact"]("Amy", "AMY@example.com", "1", "friend")
            await tools["add_contact"]("Zed", "zed@example.com")
            contact_id = amy["contact"]["id"]
            assert [row["name"] for row in (await tools["list_contacts"]())["contacts"]] == ["Amy", "Zed"]
            assert (await tools["find_contact"]("amy@"))["contacts"][0]["name"] == "Amy"
            updated = await tools["update_contact"](contact_id, name="", email="", phone="2", notes="")
            assert updated["contact"] == {"id": contact_id, "name": "Amy", "email": "",
                                           "phone": "2", "notes": ""}
            assert (await tools["update_contact"](999))["message"] == "Contact not found"
            assert (await tools["delete_contact"](contact_id))["status"] == "success"
            assert (await tools["delete_contact"](contact_id))["message"] == "Contact not found"
        finally:
            await database.close()
    run(scenario())


def test_database_tools_reject_missing_workspace(tmp_path):
    async def scenario():
        database = Database(tmp_path / "missing.db")
        await database.initialize()
        try:
            tools = tool_functions(ToolContext(WorkspaceRagService(), database, "missing"))
            with pytest.raises(ValueError, match="no longer exists"):
                await tools["list_todos"]()
            with pytest.raises(ValueError, match="no longer exists"):
                await tools["recall"]("x")
        finally:
            await database.close()
    run(scenario())
