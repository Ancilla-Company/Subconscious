"""Agent endpoints (``/api/v1/agents``): workspace-scoped or account-wide assistant profiles."""

import logging
from collections.abc import Awaitable, Callable
from typing import Any

from pydantic import ValidationError
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from subconscious_engine.api.common import json_response
from subconscious_engine.api.extra_schemas import AgentDto, UpsertAgentRequest
from subconscious_engine.services.agent_definitions import AgentDefinitionService

_LOG = logging.getLogger(__name__)

AgentPublisher = Callable[[str, dict[str, Any]], Awaitable[None]]


def agent_event(agent: AgentDto) -> dict[str, Any]:
    """The payload of ``agent.created`` / ``agent.updated`` / ``agent.deleted`` events."""
    return {"agentId": agent.uuid, "workspaceId": agent.workspace_uuid, "name": agent.name}


async def _body(request: Request) -> UpsertAgentRequest | Response:
    try:
        return UpsertAgentRequest.model_validate(await request.json())
    except (ValidationError, ValueError):
        _LOG.warning("api.agent_routes._body: invalid request body", exc_info=True)
        return JSONResponse({"error": "Invalid request body."}, 400)


async def list_agents(request: Request) -> Response:
    workspace = request.query_params.get("workspaceUuid") or request.query_params.get("workspace_uuid")
    async with request.app.state.database.session() as session:
        return json_response(await AgentDefinitionService(session).list_all(workspace))


async def get_agent(request: Request) -> Response:
    async with request.app.state.database.session() as session:
        result = await AgentDefinitionService(session).get(request.path_params["uuid"])
    return Response(status_code=404) if result is None else json_response(result)


async def create_agent(request: Request) -> Response:
    body = await _body(request)
    if isinstance(body, Response):
        return body
    try:
        async with request.app.state.database.session() as session:
            result = await AgentDefinitionService(session).create(body)
    except ValueError as error:
        _LOG.warning("api.agent_routes.create_agent: rejected: %s", error)
        return JSONResponse({"error": str(error)}, 400)
    await request.app.state.publish_agent_event("agent.created", agent_event(result))
    return json_response(result, 201, {"Location": f"/api/v1/agents/{result.uuid}"})


async def update_agent(request: Request) -> Response:
    body = await _body(request)
    if isinstance(body, Response):
        return body
    try:
        async with request.app.state.database.session() as session:
            result = await AgentDefinitionService(session).update(request.path_params["uuid"], body)
    except ValueError as error:
        _LOG.warning("api.agent_routes.update_agent: rejected: %s", error)
        return JSONResponse({"error": str(error)}, 400)
    if result is None:
        return Response(status_code=404)
    await request.app.state.publish_agent_event("agent.updated", agent_event(result))
    return json_response(result)


async def delete_agent(request: Request) -> Response:
    async with request.app.state.database.session() as session:
        service = AgentDefinitionService(session)
        existing = await service.get(request.path_params["uuid"])
        deleted = await service.delete(request.path_params["uuid"])
    if deleted and existing is not None:
        await request.app.state.publish_agent_event("agent.deleted", agent_event(existing))
    return Response(status_code=204 if deleted else 404)


def agent_routes() -> list[Route]:
    return [Route("/api/v1/agents", list_agents, methods=["GET"]),
            Route("/api/v1/agents", create_agent, methods=["POST"]),
            Route("/api/v1/agents/{uuid}", get_agent, methods=["GET"]),
            Route("/api/v1/agents/{uuid}", update_agent, methods=["PUT"]),
            Route("/api/v1/agents/{uuid}", delete_agent, methods=["DELETE"])]
