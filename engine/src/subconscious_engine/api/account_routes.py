"""Authenticated local API endpoints for engine-owned cloud account sessions."""

from typing import Any
import logging

from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from subconscious_engine.account import AccountError, AccountSessionService, AccountUser
_LOG = logging.getLogger(__name__)

_LOGGER = logging.getLogger("uvicorn.error")


def _service(request: Request) -> AccountSessionService:
    return request.app.state.account_session_service


def _session_response(
    user: AccountUser | None, *, notice: str | None = None
) -> JSONResponse:
    return JSONResponse(
        {
            "authenticated": user is not None,
            "user": user.to_api() if user is not None else None,
            **({"notice": notice} if notice else {}),
        }
    )


async def _body(request: Request) -> dict[str, Any] | None:
    try:
        value = await request.json()
    except ValueError:
        _LOG.warning("api.account_routes._body: handled ValueError; continuing with fallback", exc_info=True)
        return None
    return value if isinstance(value, dict) else None


def _text(value: dict[str, Any], key: str, *, required: bool = True) -> str | None:
    result = value.get(key)
    if not isinstance(result, str):
        return None if required else ""
    result = result.strip()
    return result or None if required else result


async def get_session(request: Request) -> Response:
    try:
        return _session_response(await _service(request).restore())
    except AccountError as error:
        _LOG.warning("api.account_routes.get_session: handled AccountError; continuing with fallback", exc_info=True)
        return JSONResponse({"error": error.message}, error.status_code)


async def login(request: Request) -> Response:
    body = await _body(request)
    email = _text(body, "email") if body else None
    password = _text(body, "password") if body else None
    if email is None or password is None:
        return JSONResponse({"error": "Email and password are required."}, 400)
    try:
        return _session_response(await _service(request).login(email, password))
    except AccountError as error:
        _LOGGER.debug(
            "Account login failed: status=%s reason=%s",
            error.status_code,
            error.message,
            exc_info=True,
        )
        return JSONResponse({"error": error.message}, error.status_code)


async def request_signup_code(request: Request) -> Response:
    body = await _body(request)
    email = _text(body, "email") if body else None
    if email is None:
        return JSONResponse({"error": "Email is required."}, 400)
    try:
        notice = await _service(request).request_signup_code(email)
        return JSONResponse({"notice": notice})
    except AccountError as error:
        _LOG.warning("api.account_routes.request_signup_code: handled AccountError; continuing with fallback", exc_info=True)
        return JSONResponse({"error": error.message}, error.status_code)


async def complete_signup(request: Request) -> Response:
    body = await _body(request)
    email = _text(body, "email") if body else None
    code = _text(body, "code") if body else None
    password = _text(body, "password") if body else None
    display_name = _text(body, "display_name", required=False) if body else None
    if email is None or code is None or password is None:
        return JSONResponse(
            {"error": "Email, verification code, and password are required."}, 400
        )
    try:
        user = await _service(request).complete_signup(
            email, code, password, display_name
        )
        return _session_response(user)
    except AccountError as error:
        _LOG.warning("api.account_routes.complete_signup: handled AccountError; continuing with fallback", exc_info=True)
        return JSONResponse({"error": error.message}, error.status_code)


async def logout(request: Request) -> Response:
    try:
        await _service(request).logout()
    except AccountError as error:
        _LOG.warning("api.account_routes.logout: handled AccountError; continuing with fallback", exc_info=True)
        return JSONResponse({"error": error.message}, error.status_code)
    return _session_response(None)


def account_routes() -> list[Route]:
    return [
        Route("/api/v1/account/session", get_session, methods=["GET"]),
        Route("/api/v1/account/login", login, methods=["POST"]),
        Route("/api/v1/account/signup/code", request_signup_code, methods=["POST"]),
        Route("/api/v1/account/signup/complete", complete_signup, methods=["POST"]),
        Route("/api/v1/account/logout", logout, methods=["POST"]),
    ]
