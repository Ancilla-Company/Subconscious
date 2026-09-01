"""Workspace REST handlers."""

from starlette.requests import Request
from starlette.responses import Response

from subconscious_engine.api.common import json_response, not_found, parse_request
from subconscious_engine.api.schemas import CreateWorkspaceRequest
from subconscious_engine.services import WorkspaceService


async def list_workspaces(request: Request) -> Response:
    async with request.app.state.database.session() as session:
        return json_response(await WorkspaceService(session).list())


async def get_workspace(request: Request) -> Response:
    async with request.app.state.database.session() as session:
        row = await WorkspaceService(session).get(request.path_params["uuid"])
        return not_found("Workspace") if row is None else json_response(WorkspaceService._dto(row))


async def create_workspace(request: Request) -> Response:
    body = await parse_request(request, CreateWorkspaceRequest)
    if isinstance(body, Response):
        return body
    async with request.app.state.database.session() as session:
        return json_response(await WorkspaceService(session).create(body))


async def update_workspace(request: Request) -> Response:
    body = await parse_request(request, CreateWorkspaceRequest)
    if isinstance(body, Response):
        return body
    async with request.app.state.database.session() as session:
        service = WorkspaceService(session)
        row = await service.get(request.path_params["uuid"])
        return not_found("Workspace") if row is None else json_response(await service.update(row, body))


async def delete_workspace(request: Request) -> Response:
    async with request.app.state.database.session() as session:
        service = WorkspaceService(session)
        row = await service.get(request.path_params["uuid"])
        if row is None:
            return not_found("Workspace")
        await service.delete(row)
        return Response(status_code=204)
