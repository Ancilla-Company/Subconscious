"""OAuth sign-in endpoints for remote MCP tools (see ``services.oauth``).

Only ``GET /api/v1/oauth/callback`` is public: the browser hits it without the engine's bearer
token. Everything else requires the bearer token like the rest of the API.
"""

import asyncio
import logging

from pydantic import BaseModel, ConfigDict, ValidationError
from starlette.requests import Request
from starlette.responses import HTMLResponse, JSONResponse, Response
from starlette.routing import Route

from subconscious_engine.api.common import json_response
from subconscious_engine.auth import OAUTH_CALLBACK_PATH
from subconscious_engine.services.configured_tools import AUTHORIZE_WAIT_SECONDS, ConfiguredRow
from subconscious_engine.services.oauth import OAuthBroker, OAuthCallbackError, result_page

_LOG = logging.getLogger(__name__)
# The URL carries the authorization code and state: never cache it or leak it via Referer.
_PAGE_HEADERS = {
    "Cache-Control": "no-store",
    "Pragma": "no-cache",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
}


class _CompleteRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    redirect_url: str | None = None
    code: str | None = None
    state: str | None = None


def _broker(request: Request) -> OAuthBroker | None:
    broker = getattr(request.app.state, "oauth_broker", None)
    if isinstance(broker, OAuthBroker):
        # The loopback redirect needs our own port; learn it from the request if the host did not set it.
        port = request.url.port or (request.scope.get("server") or (None, None))[1]
        broker.set_port(port, overwrite=False)
    return broker


def _page(title: str, message: str, status: int) -> HTMLResponse:
    return HTMLResponse(result_page(title, message), status, headers=_PAGE_HEADERS)


async def oauth_callback(request: Request) -> Response:
    """The browser lands here after the authorization server's consent page."""
    broker = _broker(request)
    if broker is None:
        return _page("Sign-in unavailable", "OAuth sign-in is not available.", 404)
    params = request.query_params
    try:
        pending = await broker.complete(
            params.get("state"), params.get("code"), error=params.get("error"),
            error_description=params.get("error_description"))
    except OAuthCallbackError as error:
        _LOG.warning("api.oauth_routes.oauth_callback: rejected callback: %s", error)
        return _page("Sign-in failed", str(error), 400)
    if pending.status == "authorized":
        return _page(f"Signed in to {pending.tool_name}",
                     "You can close this tab and return to Subconscious.", 200)
    return _page("Sign-in was not completed",
                 f"The sign-in for {pending.tool_name} was not completed. You can close this tab and try again "
                 "from Subconscious.", 200)


async def list_pending(request: Request) -> Response:
    broker = _broker(request)
    pending = await broker.list_pending() if broker is not None else []
    return json_response([item.to_json() for item in pending])


async def complete_authorization(request: Request) -> Response:
    """Paste fallback for a UI whose browser could not reach the engine's loopback address."""
    broker = _broker(request)
    auth_id = request.path_params["auth_id"]
    try:
        body = _CompleteRequest.model_validate(_camel(await request.json()))
    except (ValidationError, ValueError):
        _LOG.warning("api.oauth_routes.complete_authorization: invalid body", exc_info=True)
        return JSONResponse({"error": "Invalid request body."}, 400)
    if broker is None:
        return JSONResponse({"error": "OAuth sign-in is unavailable."}, 404)
    try:
        if body.redirect_url:
            pending = await broker.complete_from_url(auth_id, body.redirect_url)
        elif body.code or body.state:
            pending = await broker.complete_from_params(auth_id, body.code, body.state)
        else:
            return JSONResponse({"error": "Provide redirectUrl, or code and state."}, 400)
    except KeyError:
        _LOG.info("api.oauth_routes.complete_authorization: unknown authorization %s", auth_id)
        return JSONResponse({"error": "Authorization not found."}, 404)
    except OAuthCallbackError as error:
        _LOG.warning("api.oauth_routes.complete_authorization: rejected: %s", error)
        return JSONResponse({"error": str(error)}, 400)
    return JSONResponse({"status": pending.status})


def _camel(value: object) -> object:
    """Accept camelCase bodies (redirectUrl) for the snake_case model."""
    if not isinstance(value, dict):
        raise ValueError("The body must be a JSON object.")
    return {"redirect_url" if key == "redirectUrl" else key: item for key, item in value.items()}


async def cancel_authorization(request: Request) -> Response:
    broker = _broker(request)
    if broker is not None:
        await broker.cancel(request.path_params["auth_id"])
    return Response(status_code=204)


async def _oauth_row(request: Request) -> ConfiguredRow | Response:
    runtime = getattr(request.app.state, "configured_tools", None)
    row = await runtime.get_row(request.path_params["uuid"]) if runtime is not None else None
    if row is None:
        return Response(status_code=404)
    if not row.is_oauth:
        return JSONResponse({"error": "This tool does not use OAuth sign-in."}, 400)
    return row


async def authorize_tool(request: Request) -> Response:
    """Start the interactive sign-in of an OAuth tool; returns as soon as the browser URL exists."""
    broker = _broker(request)
    row = await _oauth_row(request)
    if isinstance(row, Response):
        return row
    if broker is None:
        return JSONResponse({"error": "OAuth sign-in is unavailable."}, 503)
    runtime = request.app.state.configured_tools
    flow = runtime.start_authorization(row.uuid)
    loop = asyncio.get_running_loop()
    deadline = loop.time() + AUTHORIZE_WAIT_SECONDS
    while loop.time() < deadline:
        pending = broker.pending_for_tool(row.uuid)
        if pending is not None:
            return JSONResponse({"authId": pending.auth_id, "url": pending.url, "status": "pending"}, 202)
        if flow.done():
            outcome = flow.result()
            if outcome.get("ok"):
                return JSONResponse({"authId": None, "url": None, "status": "connected"})
            return JSONResponse({"error": outcome.get("error") or "Sign-in could not be started."}, 502)
        await asyncio.sleep(0.05)
    return JSONResponse({"error": "The sign-in did not start in time."}, 504)


async def forget_tool_oauth(request: Request) -> Response:
    row = await _oauth_row(request)
    if isinstance(row, Response):
        return row
    await request.app.state.configured_tools.forget_oauth(row.uuid)
    return Response(status_code=204)


def oauth_routes() -> list[Route]:
    return [Route(OAUTH_CALLBACK_PATH, oauth_callback, methods=["GET"]),
            Route("/api/v1/oauth/pending", list_pending, methods=["GET"]),
            Route("/api/v1/oauth/{auth_id}/complete", complete_authorization, methods=["POST"]),
            Route("/api/v1/oauth/{auth_id}/cancel", cancel_authorization, methods=["POST"]),
            Route("/api/v1/tool-registry/{uuid}/authorize", authorize_tool, methods=["POST"]),
            Route("/api/v1/tool-registry/{uuid}/oauth", forget_tool_oauth, methods=["DELETE"])]
