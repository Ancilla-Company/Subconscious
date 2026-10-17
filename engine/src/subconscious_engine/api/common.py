"""Shared request parsing and response helpers."""

from typing import Any, TypeVar

from pydantic import BaseModel, ValidationError
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
import logging
_LOG = logging.getLogger(__name__)

T = TypeVar("T", bound=BaseModel)


def _json_content(value: Any) -> Any:
    if isinstance(value, BaseModel):
        return value.model_dump(mode="json", by_alias=True)
    if isinstance(value, list):
        return [_json_content(item) for item in value]
    if isinstance(value, dict):
        return {key: _json_content(item) for key, item in value.items()}
    return value


def json_response(value: Any, status_code: int = 200,
                  headers: dict[str, str] | None = None) -> JSONResponse:
    return JSONResponse(_json_content(value), status_code=status_code, headers=headers)


async def parse_request(request: Request, model: type[T]) -> T | Response:
    try:
        return model.model_validate(await request.json())
    except (ValidationError, ValueError) as error:
        _LOG.warning("api.common.parse_request: handled (ValidationError, ValueError); continuing with fallback", exc_info=True)
        return JSONResponse({"error": "Invalid request body.", "details": str(error)}, 400)


def not_found(resource: str) -> JSONResponse:
    return JSONResponse({"error": f"{resource} not found."}, 404)
