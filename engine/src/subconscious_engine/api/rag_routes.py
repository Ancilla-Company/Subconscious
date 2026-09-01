"""Additive workspace RAG indexing and retrieval routes."""

from pydantic import ValidationError
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from subconscious_engine.api.common import json_response
from subconscious_engine.api.extra_schemas import RagSearchRequest
from subconscious_engine.services.rag_service import RagServiceError


def _failure(error: RagServiceError) -> JSONResponse:
    return JSONResponse({"error": str(error)}, error.status_code)


async def index_workspace(request: Request) -> Response:
    try:
        async with request.app.state.database.session() as session:
            return json_response(await request.app.state.rag_service.index(session, request.path_params["uuid"]))
    except RagServiceError as error:
        return _failure(error)


async def search_workspace(request: Request) -> Response:
    try:
        body = RagSearchRequest.model_validate(await request.json())
    except (ValidationError, ValueError):
        return JSONResponse({"error": "Invalid request body."}, 400)
    try:
        async with request.app.state.database.session() as session:
            result = await request.app.state.rag_service.search(
                session, request.path_params["uuid"], body.query, body.mode, body.limit)
        return json_response(result)
    except RagServiceError as error:
        return _failure(error)


def rag_routes() -> list[Route]:
    return [Route("/api/v1/workspaces/{uuid}/rag/index", index_workspace, methods=["POST"]),
            Route("/api/v1/workspaces/{uuid}/rag/search", search_workspace, methods=["POST"])]
