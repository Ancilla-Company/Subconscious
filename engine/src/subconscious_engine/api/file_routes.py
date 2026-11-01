"""Workspace file routes with consistent safety error mapping."""

from urllib.parse import quote

from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from subconscious_engine.api.common import json_response, parse_request
from subconscious_engine.api.extra_schemas import (
    CopyWorkspaceFileRequest,
    MoveWorkspaceFileRequest,
    WriteWorkspaceFileRequest,
)
from subconscious_engine.services.workspace_files import WorkspaceFileError, WorkspaceFileService
import logging
_LOG = logging.getLogger(__name__)


def _root_index(request: Request) -> int:
    try:
        return int(request.query_params["rootIndex"])
    except (KeyError, ValueError) as error:
        raise WorkspaceFileError(400, "rootIndex must be an integer.") from error


def _path(request: Request) -> str | None:
    return request.query_params.get("path")


def _failure(error: Exception) -> JSONResponse:
    if isinstance(error, WorkspaceFileError):
        body: dict[str, object] = {"error": str(error)}
        if error.code is not None:
            body["code"] = error.code
        body.update(error.details)
        return JSONResponse(body, error.status_code)
    if isinstance(error, FileNotFoundError):
        return JSONResponse({"error": "The requested workspace path does not exist."}, 404)
    if isinstance(error, (PermissionError, OSError)):
        return JSONResponse({"error": "The workspace path cannot be accessed."}, 403)
    return JSONResponse({"error": "Workspace file operation failed."}, 500)


async def search_files(request: Request) -> Response:
    query = request.query_params.get("q", "")
    try:
        limit = int(request.query_params.get("limit", "20"))
    except ValueError:
        _LOG.warning("api.file_routes.search_files: handled ValueError; continuing with fallback", exc_info=True)
        return _failure(WorkspaceFileError(400, "limit must be an integer."))
    try:
        async with request.app.state.database.session() as session:
            result = await WorkspaceFileService(session).search(
                request.path_params["uuid"], query, limit
            )
        return json_response(result)
    except (WorkspaceFileError, OSError) as error:
        _LOG.warning("api.file_routes.search_files: handled (WorkspaceFileError, OSError); continuing with fallback", exc_info=True)
        return _failure(error)


async def list_files(request: Request) -> Response:
    try:
        async with request.app.state.database.session() as session:
            result = await WorkspaceFileService(session).list(
                request.path_params["uuid"], _root_index(request), _path(request))
        return json_response(result)
    except (WorkspaceFileError, OSError) as error:
        _LOG.warning("api.file_routes.list_files: handled (WorkspaceFileError, OSError); continuing with fallback", exc_info=True)
        return _failure(error)

async def read_file(request: Request) -> Response:
    try:
        async with request.app.state.database.session() as session:
            result = await WorkspaceFileService(session).read(
                request.path_params["uuid"], _root_index(request), _path(request) or "")
        return json_response(result)
    except (WorkspaceFileError, OSError) as error:
        _LOG.warning("api.file_routes.read_file: handled (WorkspaceFileError, OSError); continuing with fallback", exc_info=True)
        return _failure(error)


async def file_version(request: Request) -> Response:
    try:
        async with request.app.state.database.session() as session:
            result = await WorkspaceFileService(session).version(
                request.path_params["uuid"], _root_index(request), _path(request) or "")
        return json_response(result)
    except (WorkspaceFileError, OSError) as error:
        _LOG.warning("api.file_routes.file_version: handled (WorkspaceFileError, OSError); continuing with fallback", exc_info=True)
        return _failure(error)


async def preview_file(request: Request) -> Response:
    try:
        async with request.app.state.database.session() as session:
            result = await WorkspaceFileService(session).preview(
                request.path_params["uuid"], _root_index(request), _path(request) or "")
        ascii_filename = "".join(
            character if 32 <= ord(character) < 127 and character not in {'"', "\\"}
            else "_"
            for character in result.filename
        ) or "preview"
        disposition = (
            f'inline; filename="{ascii_filename}"; '
            f"filename*=UTF-8''{quote(result.filename, safe='')}"
        )
        return Response(
            result.content,
            media_type=result.media_type,
            headers={
                "Content-Disposition": disposition,
                "Content-Length": str(len(result.content)),
                "Cache-Control": "no-store, private",
                "X-Content-Type-Options": "nosniff",
                "X-Preview-Kind": result.kind,
            },
        )
    except (WorkspaceFileError, OSError) as error:
        _LOG.warning("api.file_routes.preview_file: handled (WorkspaceFileError, OSError); continuing with fallback", exc_info=True)
        return _failure(error)


async def mutate_file(request: Request) -> Response:
    body = await parse_request(request, WriteWorkspaceFileRequest)
    if isinstance(body, Response):
        return body
    try:
        async with request.app.state.database.session() as session:
            service = WorkspaceFileService(session)
            uuid, root_index, path = (
                request.path_params["uuid"], _root_index(request), _path(request) or "")
            if request.method == "POST":
                result = await service.create(uuid, root_index, path, body.content)
            else:
                result = await service.write(
                    uuid, root_index, path, body.content, body.expected_version)
        return json_response(result)
    except (WorkspaceFileError, OSError) as error:
        _LOG.warning("api.file_routes.mutate_file: handled (WorkspaceFileError, OSError); continuing with fallback", exc_info=True)
        return _failure(error)


async def create_directory(request: Request) -> Response:
    try:
        async with request.app.state.database.session() as session:
            result = await WorkspaceFileService(session).create_directory(
                request.path_params["uuid"], _root_index(request), _path(request) or "")
        return json_response(result)
    except (WorkspaceFileError, OSError) as error:
        _LOG.warning("api.file_routes.create_directory: handled (WorkspaceFileError, OSError); continuing with fallback", exc_info=True)
        return _failure(error)


async def move_path(request: Request) -> Response:
    body = await parse_request(request, MoveWorkspaceFileRequest)
    if isinstance(body, Response):
        return body
    try:
        async with request.app.state.database.session() as session:
            result = await WorkspaceFileService(session).move(
                request.path_params["uuid"],
                body.source_root_index,
                body.source_path,
                body.destination_root_index,
                body.destination_path,
                body.new_name,
            )
        return json_response(result)
    except (WorkspaceFileError, OSError) as error:
        _LOG.warning("api.file_routes.move_path: handled (WorkspaceFileError, OSError); continuing with fallback", exc_info=True)
        return _failure(error)


async def copy_path(request: Request) -> Response:
    body = await parse_request(request, CopyWorkspaceFileRequest)
    if isinstance(body, Response):
        return body
    try:
        async with request.app.state.database.session() as session:
            result = await WorkspaceFileService(session).copy(
                request.path_params["uuid"],
                body.source_root_index,
                body.source_path,
                body.destination_root_index,
                body.destination_path,
            )
        return json_response(result)
    except (WorkspaceFileError, OSError) as error:
        _LOG.warning("api.file_routes.copy_path: handled (WorkspaceFileError, OSError); continuing with fallback", exc_info=True)
        return _failure(error)


async def delete_path(request: Request) -> Response:
    """Delete the file or directory (with its contents) at ``rootIndex``/``path``."""
    try:
        async with request.app.state.database.session() as session:
            await WorkspaceFileService(session).delete(
                request.path_params["uuid"], _root_index(request), _path(request) or "")
        return Response(status_code=204)
    except (WorkspaceFileError, OSError) as error:
        _LOG.warning("api.file_routes.delete_path: handled (WorkspaceFileError, OSError); continuing with fallback", exc_info=True)
        return _failure(error)


def file_routes() -> list[Route]:
    return [
        Route("/api/v1/workspaces/{uuid}/files/search", search_files, methods=["GET"]),
        Route("/api/v1/workspaces/{uuid}/files", list_files, methods=["GET"]),
        Route("/api/v1/workspaces/{uuid}/files", delete_path, methods=["DELETE"]),
        Route("/api/v1/workspaces/{uuid}/files/content", read_file, methods=["GET"]),
        Route("/api/v1/workspaces/{uuid}/files/version", file_version, methods=["GET"]),
        Route("/api/v1/workspaces/{uuid}/files/preview", preview_file, methods=["GET"]),
        Route("/api/v1/workspaces/{uuid}/files/content", mutate_file, methods=["POST", "PUT"]),
        Route("/api/v1/workspaces/{uuid}/files/directory", create_directory, methods=["POST"]),
        Route("/api/v1/workspaces/{uuid}/files/move", move_path, methods=["POST"]),
        Route("/api/v1/workspaces/{uuid}/files/copy", copy_path, methods=["POST"]),
    ]
