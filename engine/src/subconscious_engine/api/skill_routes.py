"""Skill library endpoints (``/api/v1/skills``)."""

import logging

from pydantic import ValidationError
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from subconscious_engine.api.common import json_response
from subconscious_engine.api.extra_schemas import UpsertSkillRequest
from subconscious_engine.services.skills import SkillService

_LOG = logging.getLogger(__name__)


async def _body(request: Request) -> UpsertSkillRequest | Response:
    try:
        return UpsertSkillRequest.model_validate(await request.json())
    except (ValidationError, ValueError):
        _LOG.warning("api.skill_routes._body: invalid request body", exc_info=True)
        return JSONResponse({"error": "Invalid request body."}, 400)


async def list_skills(request: Request) -> Response:
    async with request.app.state.database.session() as session:
        return json_response(await SkillService(session).list())


async def get_skill(request: Request) -> Response:
    async with request.app.state.database.session() as session:
        result = await SkillService(session).get(request.path_params["uuid"])
    return Response(status_code=404) if result is None else json_response(result)


async def create_skill(request: Request) -> Response:
    body = await _body(request)
    if isinstance(body, Response):
        return body
    try:
        async with request.app.state.database.session() as session:
            result = await SkillService(session).create(body)
    except ValueError as error:
        _LOG.warning("api.skill_routes.create_skill: rejected: %s", error)
        return JSONResponse({"error": str(error)}, 400)
    return json_response(result, 201, {"Location": f"/api/v1/skills/{result.uuid}"})


async def update_skill(request: Request) -> Response:
    body = await _body(request)
    if isinstance(body, Response):
        return body
    try:
        async with request.app.state.database.session() as session:
            result = await SkillService(session).update(request.path_params["uuid"], body)
    except ValueError as error:
        _LOG.warning("api.skill_routes.update_skill: rejected: %s", error)
        return JSONResponse({"error": str(error)}, 400)
    return Response(status_code=404) if result is None else json_response(result)


async def delete_skill(request: Request) -> Response:
    async with request.app.state.database.session() as session:
        deleted = await SkillService(session).delete(request.path_params["uuid"])
    return Response(status_code=204 if deleted else 404)


def skill_routes() -> list[Route]:
    return [Route("/api/v1/skills", list_skills, methods=["GET"]),
            Route("/api/v1/skills", create_skill, methods=["POST"]),
            Route("/api/v1/skills/{uuid}", get_skill, methods=["GET"]),
            Route("/api/v1/skills/{uuid}", update_skill, methods=["PUT"]),
            Route("/api/v1/skills/{uuid}", delete_skill, methods=["DELETE"])]
