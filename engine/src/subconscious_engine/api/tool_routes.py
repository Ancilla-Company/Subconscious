"""Configured and built-in tool catalog endpoints."""

from pydantic import ValidationError
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from subconscious_engine.api.common import json_response
from subconscious_engine.api.extra_schemas import UpsertToolRegistryRequest
from subconscious_engine.configuration import ModelConfigurationStoreError
from subconscious_engine.services.tool_registry import ToolRegistryService
import logging
_LOG = logging.getLogger(__name__)


def _storage_error(error: ModelConfigurationStoreError) -> JSONResponse:
    return JSONResponse({"type": "about:blank", "title": "Encrypted credential storage is unavailable.",
        "status": 503, "detail": str(error)}, 503, media_type="application/problem+json")


def _service(request: Request, session: AsyncSession) -> ToolRegistryService:
    return ToolRegistryService(session, request.app.state.model_configuration_store,
                               getattr(request.app.state, "configured_tools", None))


async def test_tool(request: Request) -> Response:
    """Connect to (MCP) or resolve (CLI) a registry tool and list what the model would see."""
    runtime = getattr(request.app.state, "configured_tools", None)
    uuid = request.path_params["uuid"]
    try:
        result = await runtime.test(uuid) if runtime is not None else None
    except Exception as error:  # the test endpoint reports failures, it never returns a 500
        _LOG.exception("api.tool_routes.test_tool: tool test failed")
        return json_response({"ok": False, "tools": [], "error": str(error) or error.__class__.__name__,
                              "needsAuth": False})
    return Response(status_code=404) if result is None else json_response(result)


async def _body(request: Request) -> UpsertToolRegistryRequest | Response:
    try:
        return UpsertToolRegistryRequest.model_validate(await request.json())
    except (ValidationError, ValueError):
        _LOG.warning("api.tool_routes._body: handled (ValidationError, ValueError); continuing with fallback", exc_info=True)
        return JSONResponse({"error": "Invalid request body."}, 400)


async def list_tools(request: Request) -> Response:
    try:
        async with request.app.state.database.session() as session:
            return json_response(await _service(request, session).list())
    except ModelConfigurationStoreError as error:
        _LOG.warning("api.tool_routes.list_tools: handled ModelConfigurationStoreError; continuing with fallback", exc_info=True)
        return _storage_error(error)


async def get_tool(request: Request) -> Response:
    try:
        async with request.app.state.database.session() as session:
            result = await _service(request, session).get(request.path_params["uuid"])
        return Response(status_code=404) if result is None else json_response(result)
    except ModelConfigurationStoreError as error:
        _LOG.warning("api.tool_routes.get_tool: handled ModelConfigurationStoreError; continuing with fallback", exc_info=True)
        return _storage_error(error)

async def create_tool(request: Request) -> Response:
    body = await _body(request)
    if isinstance(body, Response):
        return body
    try:
        async with request.app.state.database.session() as session:
            result = await _service(request, session).create(body)
        return json_response(result, 201, {"Location": f"/api/v1/tool-registry/{result.uuid}"})
    except ValueError as error:
        _LOG.warning("api.tool_routes.create_tool: handled ValueError; continuing with fallback", exc_info=True)
        return JSONResponse({"error": str(error)}, 400)
    except ModelConfigurationStoreError as error:
        _LOG.warning("api.tool_routes.create_tool: handled ModelConfigurationStoreError; continuing with fallback", exc_info=True)
        return _storage_error(error)


async def update_tool(request: Request) -> Response:
    body = await _body(request)
    if isinstance(body, Response):
        return body
    try:
        async with request.app.state.database.session() as session:
            result = await _service(request, session).update(
                request.path_params["uuid"], body)
        return Response(status_code=404) if result is None else json_response(result)
    except ValueError as error:
        _LOG.warning("api.tool_routes.update_tool: handled ValueError; continuing with fallback", exc_info=True)
        return JSONResponse({"error": str(error)}, 400)
    except ModelConfigurationStoreError as error:
        _LOG.warning("api.tool_routes.update_tool: handled ModelConfigurationStoreError; continuing with fallback", exc_info=True)
        return _storage_error(error)


async def delete_tool(request: Request) -> Response:
    try:
        async with request.app.state.database.session() as session:
            deleted = await _service(request, session).delete(
                request.path_params["uuid"])
        return Response(status_code=204 if deleted else 404)
    except ModelConfigurationStoreError as error:
        _LOG.warning("api.tool_routes.delete_tool: handled ModelConfigurationStoreError; continuing with fallback", exc_info=True)
        return _storage_error(error)


async def tool_catalog(request: Request) -> Response:
    try:
        async with request.app.state.database.session() as session:
            configured = await _service(request, session).list()
        builtin = dict(request.app.state.tool_registry.catalog())
        client_tools = getattr(request.app.state, "client_tool_catalog", None)
        if client_tools is not None:
            # Groups registered by clients (live, or remembered until the engine restarts).
            for group, items in client_tools.catalog().items():
                builtin.setdefault(group, items)
        return json_response({"builtin": builtin, "configured": configured})
    except ModelConfigurationStoreError as error:
        _LOG.warning("api.tool_routes.tool_catalog: handled ModelConfigurationStoreError; continuing with fallback", exc_info=True)
        return _storage_error(error)


def tool_routes() -> list[Route]:
    return [Route("/api/v1/tools/catalog", tool_catalog, methods=["GET"]),
            Route("/api/v1/tool-registry", list_tools, methods=["GET"]),
            Route("/api/v1/tool-registry", create_tool, methods=["POST"]),
            Route("/api/v1/tool-registry/{uuid}", get_tool, methods=["GET"]),
            Route("/api/v1/tool-registry/{uuid}", update_tool, methods=["PUT"]),
            Route("/api/v1/tool-registry/{uuid}", delete_tool, methods=["DELETE"]),
            Route("/api/v1/tool-registry/{uuid}/test", test_tool, methods=["POST"])]
