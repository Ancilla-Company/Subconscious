"""Workspace file routes with consistent safety error mapping."""

from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from subconscious_engine.api.common import json_response, parse_request
from subconscious_engine.api.extra_schemas import WriteWorkspaceFileRequest
from subconscious_engine.services.workspace_files import WorkspaceFileError, WorkspaceFileService


def _root_index(request: Request) -> int:
    try:
        return int(request.query_params["rootIndex"])
    except (KeyError, ValueError) as error:
        raise WorkspaceFileError(400, "rootIndex must be an integer.") from error


def _path(request: Request) -> str | None:
    return request.query_params.get("path")


def _failure(error: Exception) -> JSONResponse:
    if isinstance(error, WorkspaceFileError):
        return JSONResponse({"error": str(error)}, error.status_code)
    if isinstance(error, FileNotFoundError):
        return JSONResponse({"error": "The requested workspace path does not exist."}, 404)
    if isinstance(error, (PermissionError, OSError)):
        return JSONResponse({"error": "The workspace path cannot be accessed."}, 403)
    return JSONResponse({"error": "Workspace file operation failed."}, 500)


async def list_files(request: Request) -> Response:
    try:
        async with request.app.state.database.session() as session:
            result = await WorkspaceFileService(session).list(
                request.path_params["uuid"], _root_index(request), _path(request))
        return json_response(result)
    except (WorkspaceFileError, OSError) as error:
        return _failure(error)

async def read_file(request: Request) -> Response:
    try:
        async with request.app.state.database.session() as session:
            result = await WorkspaceFileService(session).read(
                request.path_params["uuid"], _root_index(request), _path(request) or "")
        return json_response(result)
    except (WorkspaceFileError, OSError) as error:
        return _failure(error)


async def preview_file(request: Request) -> Response:
    try:
        async with request.app.state.database.session() as session:
            result = await WorkspaceFileService(session).preview(
                request.path_params["uuid"], _root_index(request), _path(request) or "")
        return json_response(result)
    except (WorkspaceFileError, OSError) as error:
        return _failure(error)


async def mutate_file(request: Request) -> Response:
    body = await parse_request(request, WriteWorkspaceFileRequest)
    if isinstance(body, Response):
        return body
    try:
        async with request.app.state.database.session() as session:
            service = WorkspaceFileService(session)
            operation = service.create if request.method == "POST" else service.write
            result = await operation(request.path_params["uuid"], _root_index(request),
                                     _path(request) or "", body.content)
        return json_response(result)
    except (WorkspaceFileError, OSError) as error:
        return _failure(error)


async def create_directory(request: Request) -> Response:
    try:
        async with request.app.state.database.session() as session:
            result = await WorkspaceFileService(session).create_directory(
                request.path_params["uuid"], _root_index(request), _path(request) or "")
        return json_response(result)
    except (WorkspaceFileError, OSError) as error:
        return _failure(error)


def file_routes() -> list[Route]:
    return [
        Route("/api/v1/workspaces/{uuid}/files", list_files, methods=["GET"]),
        Route("/api/v1/workspaces/{uuid}/files/content", read_file, methods=["GET"]),
        Route("/api/v1/workspaces/{uuid}/files/preview", preview_file, methods=["GET"]),
        Route("/api/v1/workspaces/{uuid}/files/content", mutate_file, methods=["POST", "PUT"]),
        Route("/api/v1/workspaces/{uuid}/files/directory", create_directory, methods=["POST"]),
    ]
