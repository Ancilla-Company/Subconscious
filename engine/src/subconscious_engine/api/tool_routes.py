"""Configured and built-in tool catalog endpoints."""

from pydantic import ValidationError
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from subconscious_engine.api.common import json_response
from subconscious_engine.api.extra_schemas import UpsertToolRegistryRequest
from subconscious_engine.configuration import ModelConfigurationStoreError
from subconscious_engine.services.tool_registry import ToolRegistryService


def _storage_error(error: ModelConfigurationStoreError) -> JSONResponse:
    return JSONResponse({"type": "about:blank", "title": "Encrypted credential storage is unavailable.",
        "status": 503, "detail": str(error)}, 503, media_type="application/problem+json")


async def _body(request: Request) -> UpsertToolRegistryRequest | Response:
    try:
        return UpsertToolRegistryRequest.model_validate(await request.json())
    except (ValidationError, ValueError):
        return JSONResponse({"error": "Invalid request body."}, 400)


async def list_tools(request: Request) -> Response:
    try:
        async with request.app.state.database.session() as session:
            return json_response(await ToolRegistryService(session, request.app.state.model_configuration_store).list())
    except ModelConfigurationStoreError as error:
        return _storage_error(error)


async def get_tool(request: Request) -> Response:
    try:
        async with request.app.state.database.session() as session:
            result = await ToolRegistryService(session, request.app.state.model_configuration_store).get(request.path_params["uuid"])
        return Response(status_code=404) if result is None else json_response(result)
    except ModelConfigurationStoreError as error:
        return _storage_error(error)

async def create_tool(request: Request) -> Response:
    body = await _body(request)
    if isinstance(body, Response):
        return body
    try:
        async with request.app.state.database.session() as session:
            result = await ToolRegistryService(session, request.app.state.model_configuration_store).create(body)
        return json_response(result, 201, {"Location": f"/api/v1/tool-registry/{result.uuid}"})
    except ValueError as error:
        return JSONResponse({"error": str(error)}, 400)
    except ModelConfigurationStoreError as error:
        return _storage_error(error)


async def update_tool(request: Request) -> Response:
    body = await _body(request)
    if isinstance(body, Response):
        return body
    try:
        async with request.app.state.database.session() as session:
            result = await ToolRegistryService(session, request.app.state.model_configuration_store).update(
                request.path_params["uuid"], body)
        return Response(status_code=404) if result is None else json_response(result)
    except ValueError as error:
        return JSONResponse({"error": str(error)}, 400)
    except ModelConfigurationStoreError as error:
        return _storage_error(error)


async def delete_tool(request: Request) -> Response:
    try:
        async with request.app.state.database.session() as session:
            deleted = await ToolRegistryService(session, request.app.state.model_configuration_store).delete(
                request.path_params["uuid"])
        return Response(status_code=204 if deleted else 404)
    except ModelConfigurationStoreError as error:
        return _storage_error(error)


async def tool_catalog(request: Request) -> Response:
    try:
        async with request.app.state.database.session() as session:
            configured = await ToolRegistryService(session, request.app.state.model_configuration_store).list()
        return json_response({"builtin": request.app.state.tool_registry.catalog(), "configured": configured})
    except ModelConfigurationStoreError as error:
        return _storage_error(error)


def tool_routes() -> list[Route]:
    return [Route("/api/v1/tools/catalog", tool_catalog, methods=["GET"]),
            Route("/api/v1/tool-registry", list_tools, methods=["GET"]),
            Route("/api/v1/tool-registry", create_tool, methods=["POST"]),
            Route("/api/v1/tool-registry/{uuid}", get_tool, methods=["GET"]),
            Route("/api/v1/tool-registry/{uuid}", update_tool, methods=["PUT"]),
            Route("/api/v1/tool-registry/{uuid}", delete_tool, methods=["DELETE"])]
