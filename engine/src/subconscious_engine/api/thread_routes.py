"""Thread and message REST handlers."""

from starlette.requests import Request
from starlette.responses import Response

from subconscious_engine.api.common import json_response, not_found, parse_request
from subconscious_engine.api.schemas import CreateThreadRequest, SendMessageRequest, UpdateThreadRequest
from subconscious_engine.services import MessageService, ThreadService


async def list_threads(request: Request) -> Response:
    async with request.app.state.database.session() as session:
        return json_response(await ThreadService(session).list(request.path_params["uuid"]))


async def get_thread(request: Request) -> Response:
    async with request.app.state.database.session() as session:
        service = ThreadService(session)
        row = await service.get(request.path_params["uuid"])
        return not_found("Thread") if row is None else json_response(service._dto(row, row.workspace))


async def create_thread(request: Request) -> Response:
    body = await parse_request(request, CreateThreadRequest)
    if isinstance(body, Response):
        return body
    async with request.app.state.database.session() as session:
        result = await ThreadService(session).create(body)
    if result is None:
        return not_found("Workspace")
    await request.app.state.event_bus.publish("thread.created", {
        "threadId": result.uuid, "workspaceId": result.workspace_uuid, "title": result.title or ""})
    return json_response(result)


async def update_thread(request: Request) -> Response:
    body = await parse_request(request, UpdateThreadRequest)
    if isinstance(body, Response):
        return body
    async with request.app.state.database.session() as session:
        service = ThreadService(session)
        row = await service.get(request.path_params["uuid"])
        if row is None:
            return not_found("Thread")
        result = await service.update(row, body)
    await request.app.state.event_bus.publish("thread.updated", {
        "threadId": result.uuid, "title": result.title, "description": result.description})
    return json_response(result)


async def delete_thread(request: Request) -> Response:
    async with request.app.state.database.session() as session:
        service = ThreadService(session)
        row = await service.get(request.path_params["uuid"])
        if row is None:
            return not_found("Thread")
        await service.delete(row)
        return Response(status_code=204)


async def list_messages(request: Request) -> Response:
    async with request.app.state.database.session() as session:
        return json_response(await MessageService(session).list(request.path_params["uuid"]))


async def create_message(request: Request) -> Response:
    body = await parse_request(request, SendMessageRequest)
    if isinstance(body, Response):
        return body
    async with request.app.state.database.session() as session:
        result = await MessageService(session).create(body)
    if result is None:
        return not_found("Thread")
    await request.app.state.event_bus.publish("message.created", {
        "messageId": result.uuid, "threadId": result.thread_uuid,
        "role": result.role, "content": result.content})
    return json_response(result)
