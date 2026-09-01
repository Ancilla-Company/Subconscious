"""App-state settings endpoints."""

from pydantic import TypeAdapter, ValidationError
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from subconscious_engine.api.common import json_response
from subconscious_engine.api.extra_schemas import AppStateSettingDto
from subconscious_engine.services.settings import SettingsService


async def list_settings(request: Request) -> Response:
    query = request.query_params
    async with request.app.state.database.session() as session:
        values = await SettingsService(session).list(query.get("key"), query.get("tag"), query.get("client"))
    return json_response(values)


async def update_settings(request: Request) -> Response:
    try:
        values = TypeAdapter(list[AppStateSettingDto]).validate_python(await request.json())
    except (ValidationError, ValueError):
        return JSONResponse({"error": "Invalid request body."}, 400)
    scopes = [(item.key, item.tag, item.client) for item in values]
    if not values or any(not item.key.strip() for item in values) or len(scopes) != len(set(scopes)):
        return JSONResponse({"error": "Settings must have a key, value, and unique key/tag/client scope."}, 400)
    async with request.app.state.database.session() as session:
        await SettingsService(session).upsert(values)
    return json_response(values)


def settings_routes() -> list[Route]:
    return [Route("/api/v1/settings", list_settings, methods=["GET"]),
            Route("/api/v1/settings", update_settings, methods=["PUT"])]
