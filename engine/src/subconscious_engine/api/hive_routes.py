"""Local (bearer protected) management API for the hive; never exposed to peers."""

from typing import TYPE_CHECKING, Any

from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from subconscious_engine.hive.errors import HiveError
import logging
_LOG = logging.getLogger(__name__)

if TYPE_CHECKING:  # the service imports the API layer, so avoid a runtime cycle
    from subconscious_engine.hive.service import HiveService


def _service(request: Request) -> "HiveService | None":
    return getattr(request.app.state, "hive_service", None)


async def _body(request: Request) -> dict[str, Any]:
    try:
        value = await request.json()
    except ValueError:
        _LOG.warning("api.hive_routes._body: handled ValueError; continuing with fallback", exc_info=True)
        return {}
    return value if isinstance(value, dict) else {}


def _unavailable() -> Response:
    return JSONResponse({"error": "The hive is not available."}, 503)


async def list_nodes(request: Request) -> Response:
    service = _service(request)
    if service is None:
        return JSONResponse(
            {"enabled": False, "state": "stopped", "detail": "", "node_id": None,
             "hive_id": None, "nodes": []}
        )
    refresh = getattr(service, "refresh", None)
    if refresh is not None:
        await refresh()
    return JSONResponse(service.snapshot())


async def enroll(request: Request) -> Response:
    service = _service(request)
    if service is None:
        return _unavailable()
    invite = (await _body(request)).get("invite_code")
    try:
        return JSONResponse(await service.enroll(invite if isinstance(invite, str) else None))
    except HiveError as error:
        _LOG.warning("api.hive_routes.enroll: handled HiveError; continuing with fallback", exc_info=True)
        return JSONResponse({"error": error.message}, error.status_code)


async def create_invite(request: Request) -> Response:
    service = _service(request)
    if service is None:
        return _unavailable()
    try:
        return JSONResponse(await service.create_invite())
    except HiveError as error:
        _LOG.warning("api.hive_routes.create_invite: handled HiveError; continuing with fallback", exc_info=True)
        return JSONResponse({"error": error.message}, error.status_code)


async def approve_node(request: Request) -> Response:
    service = _service(request)
    if service is None:
        return _unavailable()
    sas = (await _body(request)).get("sas")
    if not isinstance(sas, str):
        return JSONResponse({"error": "The short authentication code is required."}, 400)
    try:
        await service.approve(request.path_params["node_id"], sas)
    except HiveError as error:
        _LOG.warning("api.hive_routes.approve_node: handled HiveError; continuing with fallback", exc_info=True)
        return JSONResponse({"error": error.message}, error.status_code)
    return JSONResponse({"approved": True})


async def revoke_node(request: Request) -> Response:
    service = _service(request)
    if service is None:
        return _unavailable()
    try:
        await service.revoke(request.path_params["node_id"])
    except HiveError as error:
        _LOG.warning("api.hive_routes.revoke_node: handled HiveError; continuing with fallback", exc_info=True)
        return JSONResponse({"error": error.message}, error.status_code)
    return JSONResponse({"revoked": True})


async def list_tasks(request: Request) -> Response:
    manager = getattr(request.app.state, "task_manager", None)
    if manager is None:
        return JSONResponse({"tasks": []})
    params = request.query_params
    try:
        limit = int(params.get("limit", "100"))
    except ValueError:
        _LOG.warning("api.hive_routes.list_tasks: handled ValueError; continuing with fallback", exc_info=True)
        return JSONResponse({"error": "limit must be a number."}, 400)
    tasks = await manager.list_tasks(
        status=params.get("status") or None, thread_uuid=params.get("thread_uuid") or None, limit=limit)
    return JSONResponse({"tasks": tasks})


async def get_remote_tools(request: Request) -> Response:
    service = getattr(request.app.state, "remote_tools", None)
    if service is None:
        return _unavailable()
    return JSONResponse(service.snapshot())


async def put_remote_tools(request: Request) -> Response:
    service = getattr(request.app.state, "remote_tools", None)
    if service is None:
        return _unavailable()
    try:
        value = await request.json()
    except ValueError:
        _LOG.warning("api.hive_routes.put_remote_tools: handled ValueError; continuing with fallback", exc_info=True)
        return JSONResponse({"error": "The request body must be a JSON object."}, 400)
    if not isinstance(value, dict):
        return JSONResponse({"error": "The request body must be a JSON object."}, 400)
    try:
        return JSONResponse(service.update(value))
    except ValueError as error:
        _LOG.warning("api.hive_routes.put_remote_tools: handled ValueError; continuing with fallback", exc_info=True)
        return JSONResponse({"error": str(error)}, 400)


async def sync_status(request: Request) -> Response:
    engine = getattr(request.app.state, "sync_engine", None)
    if engine is None:
        return JSONResponse({"state": "unavailable", "peers": []})
    status = await engine.status()
    service = _service(request)
    node = getattr(service, "node", None)
    status["peers"] = node.coordinator.status() if node is not None else []
    if service is not None and getattr(service, "state", "") == "hive_mismatch":
        status["state"] = "hive_mismatch"
        status["detail"] = service.detail
    return JSONResponse(status)


def hive_routes() -> list[Route]:
    return [
        Route("/api/v1/hive/tasks", list_tasks, methods=["GET"]),
        Route("/api/v1/hive/sync/status", sync_status, methods=["GET"]),
        # Local bearer only: authz.py has no rule for these, so peers always get a denial.
        Route("/api/v1/hive/remote-tools", get_remote_tools, methods=["GET"]),
        Route("/api/v1/hive/remote-tools", put_remote_tools, methods=["PUT"]),
        Route("/api/v1/hive/nodes", list_nodes, methods=["GET"]),
        Route("/api/v1/hive/enroll", enroll, methods=["POST"]),
        Route("/api/v1/hive/invites", create_invite, methods=["POST"]),
        Route("/api/v1/hive/nodes/{node_id}/approve", approve_node, methods=["POST"]),
        Route("/api/v1/hive/nodes/{node_id}", revoke_node, methods=["DELETE"]),
    ]
