"""Browser-extension pairing routes.

``POST /api/v1/pair`` is public (the middleware lets it through) and performs its own checks.
The ``/api/v1/pair/clients`` management routes are enforced master-token-only by the middleware.
"""

import logging

from pydantic import BaseModel, ConfigDict, Field
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from subconscious_engine.pairing import PairingError, is_extension_origin

from .common import json_response, not_found, parse_request


_LOG = logging.getLogger(__name__)


class PairRequest(BaseModel):
    model_config = ConfigDict(extra="ignore")

    assertion: str = Field(min_length=1, max_length=512)
    client_nonce: str = Field(min_length=16, max_length=128)


async def pair(request: Request) -> JSONResponse:
    origin = request.headers.get("origin")
    if not is_extension_origin(origin):
        return JSONResponse({"error": "Pairing is only available to browser extensions."}, 403)
    host = request.client.host if request.client else "unknown"
    if not request.app.state.pair_rate_limiter.allow(f"{origin}|{host}"):
        return JSONResponse({"error": "Too many pairing attempts."}, 429, headers={"Retry-After": "60"})
    body = await parse_request(request, PairRequest)
    if isinstance(body, JSONResponse):
        return body
    try:
        token, client = await request.app.state.pairing_service.pair(
            body.assertion, body.client_nonce, origin
        )
    except PairingError as error:
        _LOG.info("pair: rejected status=%s reason=%s", error.status_code, error.message)
        return JSONResponse({"error": error.message}, error.status_code)
    return json_response(
        {"token": token, "client_id": client.id, "expires_at": client.expires_at}
    )


async def list_clients(request: Request) -> JSONResponse:
    store = request.app.state.paired_clients
    return json_response({"clients": [client.to_api() for client in store.list()]})


async def revoke_client(request: Request) -> JSONResponse:
    if not request.app.state.paired_clients.revoke(request.path_params["client_id"]):
        return not_found("Paired client")
    return json_response({"revoked": True})


def pair_routes() -> list[Route]:
    return [
        Route("/api/v1/pair", pair, methods=["POST"]),
        Route("/api/v1/pair/clients", list_clients, methods=["GET"]),
        Route("/api/v1/pair/clients/{client_id}", revoke_client, methods=["DELETE"]),
    ]
