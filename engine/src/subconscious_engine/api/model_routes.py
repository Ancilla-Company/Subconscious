"""Self-contained Starlette routes for encrypted model configurations."""

from pathlib import Path
from typing import Any
from urllib.parse import quote

from pydantic import ValidationError
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from subconscious_engine.configuration import (
    EncryptedModelConfigurationStore,
    ModelConfigurationStoreError,
    UpsertModelConfigurationRequest,
    build_model_catalog,
)
from subconscious_engine.configuration.catalog import build_model_catalog_with_capabilities
import logging
_LOG = logging.getLogger(__name__)


def _json_model(value: Any, status_code: int = 200, headers: dict[str, str] | None = None) -> JSONResponse:
    if isinstance(value, list):
        content = [item.model_dump(mode="json", by_alias=True) for item in value]
    else:
        content = value.model_dump(mode="json", by_alias=True)
    return JSONResponse(content, status_code=status_code, headers=headers)


def _storage_problem(error: ModelConfigurationStoreError) -> JSONResponse:
    return JSONResponse(
        {
            "type": "about:blank",
            "title": "Encrypted credential storage is unavailable.",
            "status": 503,
            "detail": str(error),
        },
        status_code=503,
        media_type="application/problem+json",
    )


async def _parse_upsert(request: Request) -> UpsertModelConfigurationRequest | Response:
    try:
        return UpsertModelConfigurationRequest.model_validate(await request.json())
    except (ValidationError, ValueError, UnicodeDecodeError):
        _LOG.warning("api.model_routes._parse_upsert: handled (ValidationError, ValueError, UnicodeDecodeError); continuing with fallback", exc_info=True)
        return JSONResponse({"error": "Invalid request body."}, status_code=400)


def _request_store(request: Request) -> EncryptedModelConfigurationStore:
    store = getattr(request.app.state, "model_configuration_store", None)
    if store is None:
        raise ModelConfigurationStoreError("Encrypted model configuration storage is not configured.")
    return store


async def list_model_configurations(request: Request) -> Response:
    try:
        return _json_model(await _request_store(request).list())
    except ModelConfigurationStoreError as error:
        _LOG.warning("api.model_routes.list_model_configurations: handled ModelConfigurationStoreError; continuing with fallback", exc_info=True)
        return _storage_problem(error)


async def create_model_configuration(request: Request) -> Response:
    body = await _parse_upsert(request)
    if isinstance(body, Response):
        return body
    try:
        created = await _request_store(request).create(body)
        location = f"/api/v1/model-configurations/{quote(created.id, safe='')}"
        return _json_model(created, status_code=201, headers={"Location": location})
    except ValueError as error:
        _LOG.warning("api.model_routes.create_model_configuration: handled ValueError; continuing with fallback", exc_info=True)
        return JSONResponse({"error": str(error)}, status_code=400)
    except ModelConfigurationStoreError as error:
        _LOG.warning("api.model_routes.create_model_configuration: handled ModelConfigurationStoreError; continuing with fallback", exc_info=True)
        return _storage_problem(error)


async def update_model_configuration(request: Request) -> Response:
    body = await _parse_upsert(request)
    if isinstance(body, Response):
        return body
    try:
        updated = await _request_store(request).update(request.path_params["id"], body)
        return Response(status_code=404) if updated is None else _json_model(updated)
    except ValueError as error:
        _LOG.warning("api.model_routes.update_model_configuration: handled ValueError; continuing with fallback", exc_info=True)
        return JSONResponse({"error": str(error)}, status_code=400)
    except ModelConfigurationStoreError as error:
        _LOG.warning("api.model_routes.update_model_configuration: handled ModelConfigurationStoreError; continuing with fallback", exc_info=True)
        return _storage_problem(error)


async def delete_model_configuration(request: Request) -> Response:
    try:
        deleted = await _request_store(request).delete(request.path_params["id"])
        return Response(status_code=204 if deleted else 404)
    except ModelConfigurationStoreError as error:
        _LOG.warning("api.model_routes.delete_model_configuration: handled ModelConfigurationStoreError; continuing with fallback", exc_info=True)
        return _storage_problem(error)


async def list_models(request: Request) -> Response:
    try:
        configurations = await _request_store(request).list()
        resolver = getattr(request.app.state, "capability_resolver", None)
        dev_models = getattr(request.app.state, "dev_models", False) is True
        if resolver is None:
            return _json_model(
                build_model_catalog(configurations, include_dev_models=dev_models)
            )
        return _json_model(
            await build_model_catalog_with_capabilities(
                configurations, resolver, include_dev_models=dev_models
            )
        )
    except ModelConfigurationStoreError as error:
        _LOG.warning("api.model_routes.list_models: handled ModelConfigurationStoreError; continuing with fallback", exc_info=True)
        return _storage_problem(error)


def model_routes(
    store: EncryptedModelConfigurationStore | None = None,
    *,
    data_directory: str | Path | None = None,
) -> list[Route]:
    """Create model routes without requiring edits to the shared app or schemas.

    When supplied, the store is captured by the route endpoints. Otherwise callers
    may assign ``app.state.model_configuration_store`` before serving requests.
    """

    selected = store
    if selected is None and data_directory is not None:
        selected = EncryptedModelConfigurationStore(data_directory)

    def endpoint(handler: Any) -> Any:
        if selected is None:
            return handler

        async def with_store(request: Request) -> Response:
            previous = getattr(request.app.state, "model_configuration_store", None)
            request.app.state.model_configuration_store = selected
            try:
                return await handler(request)
            finally:
                if previous is None:
                    try:
                        delattr(request.app.state, "model_configuration_store")
                    except AttributeError:
                        _LOG.warning("api.model_routes.model_routes.endpoint.with_store: handled AttributeError; continuing with fallback", exc_info=True)
                        pass
                else:
                    request.app.state.model_configuration_store = previous

        return with_store

    return [
        Route(
            "/api/v1/model-configurations",
            endpoint(list_model_configurations),
            methods=["GET"],
        ),
        Route(
            "/api/v1/model-configurations",
            endpoint(create_model_configuration),
            methods=["POST"],
        ),
        Route(
            "/api/v1/model-configurations/{id}",
            endpoint(update_model_configuration),
            methods=["PUT"],
        ),
        Route(
            "/api/v1/model-configurations/{id}",
            endpoint(delete_model_configuration),
            methods=["DELETE"],
        ),
        Route("/api/v1/models", endpoint(list_models), methods=["GET"]),
    ]


create_model_routes = model_routes

__all__ = [
    "create_model_configuration",
    "create_model_routes",
    "delete_model_configuration",
    "list_model_configurations",
    "list_models",
    "model_routes",
    "update_model_configuration",
]
