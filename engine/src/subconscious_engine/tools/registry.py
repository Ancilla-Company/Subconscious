"""Cross-platform time, calculator, and workspace-knowledge tools."""

import ast
from dataclasses import dataclass
from datetime import datetime
import json
import math
import operator
from typing import Any, Awaitable, Callable
from zoneinfo import ZoneInfo, available_timezones

import httpx
from pydantic_ai import Tool
from urllib.parse import quote

from subconscious_engine.approval import ApprovalConfig, classify_operation
from subconscious_engine.services.rag_service import WorkspaceRagService
from subconscious_engine.services.workspace_files import WorkspaceFileService
from subconscious_engine.tools.database_tools import database_tool_entries

ToolFunction = Callable[..., Any]


@dataclass(frozen=True, slots=True)
class ContextFile:
    id: str
    label: str
    root_index: int
    path: str


@dataclass(frozen=True, slots=True)
class ContextAttachment:
    id: str
    name: str
    media_type: str
    content: bytes


@dataclass(frozen=True, slots=True)
class ToolContext:
    rag: WorkspaceRagService
    database: Any
    workspace_uuid: str
    thread_id: int | None = None
    context_files: tuple[ContextFile, ...] = ()
    active_file: ContextFile | None = None
    attachments: tuple[ContextAttachment, ...] = ()


@dataclass(frozen=True, slots=True)
class ToolSpec:
    slug: str
    name: str
    description: str
    factory: Callable[[ToolContext], ToolFunction]


def _file_summary(file: ContextFile | None) -> dict[str, Any] | None:
    if file is None:
        return None
    return {
        "id": file.id,
        "label": file.label,
        "rootIndex": file.root_index,
        "path": file.path,
    }


def _deep_merge(baseline: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    result = dict(baseline)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = _deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def merge_tool_config(workspace_raw: str | None, thread_raw: str | None) -> str | None:
    def parse(raw: str | None) -> dict[str, Any]:
        if not raw:
            return {}
        value = json.loads(raw)
        if not isinstance(value, dict):
            raise ValueError("Stored tool configuration must be a JSON object.")
        return value
    baseline = parse(workspace_raw)
    return json.dumps(_deep_merge(baseline, parse(thread_raw))) if thread_raw else workspace_raw


class ToolRegistry:
    def __init__(self) -> None:
        self._specs = self._build_specs()

    def catalog(self) -> dict[str, list[dict[str, str]]]:
        result: dict[str, list[dict[str, str]]] = {}
        for spec in self._specs:
            result.setdefault(spec.slug, []).append({"name": spec.name, "doc": spec.description,
                                                     "operation": classify_operation(spec.name)})
        return result

    def tools_for_config(self, raw: str | None, context: ToolContext,
                         approval: ApprovalConfig) -> list[Tool[Any]]:
        config: dict[str, Any] = {}
        if raw:
            parsed = json.loads(raw)
            if not isinstance(parsed, dict):
                raise ValueError("Stored tool configuration must be a JSON object.")
            config = parsed
        if config.get("builtin_enabled", True) is False:
            return []
        builtin_value = config.get("builtin")
        builtin: dict[str, Any] = builtin_value if isinstance(builtin_value, dict) else {}
        tools: list[Tool[Any]] = []
        for spec in self._specs:
            slug_value = builtin.get(spec.slug)
            slug_config: dict[str, Any] = slug_value if isinstance(slug_value, dict) else {}
            if slug_config.get("enabled", True) is False:
                continue
            overrides_value = slug_config.get("tools")
            overrides: dict[str, Any] = overrides_value if isinstance(overrides_value, dict) else {}
            if overrides.get(spec.name, True) is False:
                continue
            tools.append(Tool(spec.factory(context), name=spec.name, description=spec.description,
                              requires_approval=approval.requires(spec.name)))
        return tools

    @staticmethod
    def _build_specs() -> list[ToolSpec]:
        def plain(function: ToolFunction) -> Callable[[ToolContext], ToolFunction]:
            return lambda _: function

        def search_knowledge_tool(context: ToolContext) -> ToolFunction:
            async def search_knowledge(query: str, mode: str = "hybrid",
                                       limit: int = 8) -> list[dict[str, Any]]:
                async with context.database.session() as session:
                    return await context.rag.search(
                        session, context.workspace_uuid, query, mode, limit)
            return search_knowledge

        def list_context_files_tool(context: ToolContext) -> ToolFunction:
            def list_context_files() -> dict[str, Any]:
                return {
                    "active": _file_summary(context.active_file),
                    "tagged": [_file_summary(item) for item in context.context_files],
                    "attachments": [
                        {
                            "id": item.id,
                            "name": item.name,
                            "mediaType": item.media_type,
                            "size": len(item.content),
                        }
                        for item in context.attachments
                    ],
                }
            return list_context_files

        def read_context_file_tool(context: ToolContext) -> ToolFunction:
            async def read_context_file(file_id: str) -> dict[str, Any]:
                file = next(
                    (item for item in context.context_files if item.id == file_id),
                    None,
                )
                if file_id == "active":
                    file = context.active_file
                if file is None:
                    raise ValueError("The requested file is not in this turn's context.")
                async with context.database.session() as session:
                    result = await WorkspaceFileService(session).read(
                        context.workspace_uuid, file.root_index, file.path
                    )
                return {**_file_summary(file), "content": result.content}
            return read_context_file

        def read_attachment_tool(context: ToolContext) -> ToolFunction:
            def read_attachment(attachment_id: str) -> dict[str, Any]:
                attachment = next(
                    (item for item in context.attachments if item.id == attachment_id),
                    None,
                )
                if attachment is None:
                    raise ValueError("The requested attachment is not in this turn's context.")
                try:
                    content = attachment.content.removeprefix(b"\xef\xbb\xbf").decode("utf-8")
                except UnicodeDecodeError as error:
                    raise ValueError(
                        "This attachment is binary; only UTF-8 text attachments can be read."
                    ) from error
                return {
                    "id": attachment.id,
                    "name": attachment.name,
                    "mediaType": attachment.media_type,
                    "content": content,
                }
            return read_attachment

        def replace_active_file_tool(context: ToolContext) -> ToolFunction:
            async def replace_active_file(content: str) -> dict[str, Any]:
                file = context.active_file
                if file is None:
                    raise ValueError("No active workspace file was supplied for this turn.")
                async with context.database.session() as session:
                    result = await WorkspaceFileService(session).write(
                        context.workspace_uuid, file.root_index, file.path, content
                    )
                return {
                    "status": "updated",
                    **_file_summary(file),
                    "characters": len(result.content),
                }
            return replace_active_file

        specs = [
            ToolSpec("time", "get_current_time", "Get the current time in an IANA timezone.",
                     plain(get_current_time)),
            ToolSpec("time", "get_current_date", "Get the current date in an IANA timezone.",
                     plain(get_current_date)),
            ToolSpec("time", "convert_timezone", "Convert an ISO timestamp between IANA timezones.",
                     plain(convert_timezone)),
            ToolSpec("time", "list_common_timezones", "List common IANA timezone names.",
                     plain(list_common_timezones)),
            ToolSpec("calculator", "calculate", "Safely evaluate an arithmetic expression.", plain(calculate)),
            ToolSpec("calculator", "convert_units", "Convert between supported compatible units.",
                     plain(convert_units)),
            ToolSpec("calculator", "list_supported_units", "List units supported by convert_units.",
                     plain(list_supported_units)),
            ToolSpec("weather", "get_current_weather", "Get current weather using wttr.in.",
                     plain(get_current_weather)),
            ToolSpec("weather", "get_weather_forecast", "Get up to three forecast days using wttr.in.",
                     plain(get_weather_forecast)),
        ]
        specs.extend(ToolSpec(*entry) for entry in database_tool_entries())
        specs.extend([
            ToolSpec(
                "workspace_files",
                "list_context_files",
                "List the active file, # tagged workspace files, and attachments for this turn.",
                list_context_files_tool,
            ),
            ToolSpec(
                "workspace_files",
                "read_context_file",
                "Read a UTF-8 workspace file that is active or # tagged in this turn.",
                read_context_file_tool,
            ),
            ToolSpec(
                "workspace_files",
                "read_attachment",
                "Read a UTF-8 text attachment supplied with this turn.",
                read_attachment_tool,
            ),
            ToolSpec(
                "workspace_files",
                "replace_active_file",
                "Replace the complete contents of only the active workspace file.",
                replace_active_file_tool,
            ),
            ToolSpec(
                "knowledge",
                "search_knowledge",
                "Search indexed workspace folders using keyword, vector, or hybrid retrieval; sensitive files return names only.",
                search_knowledge_tool,
            ),
        ])
        return specs

_BINARY: dict[type[Any], Callable[[float, float], float]] = {
    ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
    ast.Div: operator.truediv, ast.FloorDiv: operator.floordiv,
    ast.Mod: operator.mod, ast.Pow: operator.pow,
}
_UNARY: dict[type[Any], Callable[[float], float]] = {
    ast.UAdd: operator.pos, ast.USub: operator.neg,
}
_UNITS = {
    "m": ("length", 1.0), "km": ("length", 1000.0), "cm": ("length", 0.01),
    "mm": ("length", 0.001), "in": ("length", 0.0254), "ft": ("length", 0.3048),
    "g": ("mass", 1.0), "kg": ("mass", 1000.0), "lb": ("mass", 453.59237),
    "s": ("time", 1.0), "min": ("time", 60.0), "h": ("time", 3600.0),
}


def _evaluate(node: ast.AST) -> float:
    if isinstance(node, ast.Expression):
        return _evaluate(node.body)
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)) and not isinstance(node.value, bool):
        return float(node.value)
    if isinstance(node, ast.BinOp) and type(node.op) in _BINARY:
        left, right = _evaluate(node.left), _evaluate(node.right)
        if isinstance(node.op, ast.Pow) and abs(right) > 100:
            raise ValueError("Exponent is too large.")
        return float(_BINARY[type(node.op)](left, right))
    if isinstance(node, ast.UnaryOp) and type(node.op) in _UNARY:
        return float(_UNARY[type(node.op)](_evaluate(node.operand)))
    raise ValueError("Expression contains unsupported syntax.")


def calculate(expression: str) -> str:
    """Safely evaluate arithmetic without names, calls, or attribute access."""
    if len(expression) > 500:
        raise ValueError("Expression is too long.")
    result = _evaluate(ast.parse(expression, mode="eval"))
    if not math.isfinite(result):
        raise ValueError("Result is not finite.")
    return format(result, ".15g")


def convert_units(value: float, from_unit: str, to_unit: str) -> float:
    source, target = _UNITS.get(from_unit.casefold()), _UNITS.get(to_unit.casefold())
    if source is None or target is None or source[0] != target[0]:
        raise ValueError("Units are unknown or incompatible.")
    return value * source[1] / target[1]


def list_supported_units() -> dict[str, list[str]]:
    result: dict[str, list[str]] = {}
    for name, (dimension, _) in _UNITS.items():
        result.setdefault(dimension, []).append(name)
    return result


def get_current_time(timezone: str = "UTC") -> str:
    return datetime.now(ZoneInfo(timezone)).isoformat(timespec="seconds")


def get_current_date(timezone: str = "UTC") -> str:
    return datetime.now(ZoneInfo(timezone)).date().isoformat()


def convert_timezone(timestamp: str, from_timezone: str, to_timezone: str) -> str:
    value = datetime.fromisoformat(timestamp)
    if value.tzinfo is None:
        value = value.replace(tzinfo=ZoneInfo(from_timezone))
    return value.astimezone(ZoneInfo(to_timezone)).isoformat(timespec="seconds")


def list_common_timezones() -> list[str]:
    preferred = ["UTC", "America/New_York", "America/Chicago", "America/Denver",
                 "America/Los_Angeles", "Europe/London", "Europe/Paris", "Asia/Tokyo",
                 "Asia/Shanghai", "Asia/Kolkata", "Australia/Sydney"]
    known = available_timezones()
    return [name for name in preferred if name in known]


async def _weather_data(location: str) -> dict[str, Any]:
    if not location.strip():
        raise ValueError("Location is required.")
    url = f"https://wttr.in/{quote(location.strip(), safe='')}"
    async with httpx.AsyncClient(timeout=10.0, follow_redirects=True) as client:
        response = await client.get(url, params={"format": "j1"})
        response.raise_for_status()
        value = response.json()
    if not isinstance(value, dict):
        raise ValueError("Weather service returned an invalid response.")
    return value


async def get_current_weather(location: str) -> str:
    try:
        value = await _weather_data(location)
        conditions = value.get("current_condition")
        current = conditions[0] if isinstance(conditions, list) and conditions else None
        if not isinstance(current, dict):
            return f"Could not retrieve weather data for '{location}'."
        descriptions = current.get("weatherDesc")
        description = descriptions[0].get("value", "Unknown") \
            if isinstance(descriptions, list) and descriptions and isinstance(descriptions[0], dict) else "Unknown"
        return (f"Weather in {location}:\n"
                f"Temperature: {current.get('temp_C', '?')}°C "
                f"(feels like {current.get('FeelsLikeC', '?')}°C)\n"
                f"Condition: {description}\nHumidity: {current.get('humidity', '?')}%\n"
                f"Wind: {current.get('windspeedKmph', '?')} km/h {current.get('winddir16Point', '?')}\n"
                f"Precipitation: {current.get('precipMM', '?')} mm\n"
                f"Pressure: {current.get('pressure', '?')} mb\n"
                f"Visibility: {current.get('visibility', '?')} km\n"
                f"Cloud cover: {current.get('cloudcover', '?')}%")
    except (httpx.HTTPError, ValueError) as error:
        return f"Failed to fetch weather data: {error}"


async def get_weather_forecast(location: str, days: int = 3) -> str:
    days = days if 1 <= days <= 3 else 3
    try:
        value = await _weather_data(location)
        weather = value.get("weather")
        if not isinstance(weather, list) or not weather:
            return f"Could not retrieve forecast data for '{location}'."
        lines = [f"{days}-day forecast for {location}:", ""]
        for index, day in enumerate(weather[:days], start=1):
            if not isinstance(day, dict):
                continue
            hourly = day.get("hourly")
            sample = hourly[0] if isinstance(hourly, list) and hourly and isinstance(hourly[0], dict) else {}
            descriptions = sample.get("weatherDesc")
            condition = descriptions[0].get("value", "Unknown") \
                if isinstance(descriptions, list) and descriptions and isinstance(descriptions[0], dict) else "Unknown"
            lines.extend([f"Day {index} ({day.get('date', 'Unknown date')}):",
                f"  Temperature: {day.get('mintempC', '?')}°C to {day.get('maxtempC', '?')}°C "
                f"(avg {day.get('avgtempC', '?')}°C)", f"  Condition: {condition}",
                f"  Total precipitation: {day.get('totalSnow_cm', '0')} mm",
                f"  Sun hours: {day.get('sunHour', '?')}", f"  UV Index: {day.get('uvIndex', '?')}", ""])
        return "\n".join(lines).rstrip()
    except (httpx.HTTPError, ValueError) as error:
        return f"Failed to fetch forecast data: {error}"
