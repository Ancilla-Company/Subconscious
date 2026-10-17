"""REST routes for speech-to-text and text-to-speech."""

from __future__ import annotations

from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

from subconscious_engine.capabilities import CapabilityResolver, ModelCapabilities
from subconscious_engine.configuration import ModelConfigurationStoreError
from subconscious_engine.configuration.models import ModelConfig

from .services import MAX_AUDIO_BYTES, AudioServiceError, AudioServices
import logging
_LOG = logging.getLogger(__name__)


def _error(message: str, status: int) -> JSONResponse:
    return JSONResponse({"error": message}, status_code=status)


async def capabilities_for(app, config: ModelConfig) -> ModelCapabilities:
    resolver: CapabilityResolver = getattr(
        app.state, "capability_resolver", None
    ) or CapabilityResolver()
    return await resolver.resolve(
        config.provider, config.model, (config.extra or {}).get("capabilities")
    )


async def _model_for(request: Request, model_id: object, flag: str) -> ModelConfig | Response:
    """Resolve a configured model and require that it supports ``flag``."""
    if not isinstance(model_id, str) or not model_id:
        return _error("modelId is required.", 400)
    try:
        config = await request.app.state.model_configuration_store.resolve(model_id)
    except ModelConfigurationStoreError as error:
        _LOG.warning("audio.routes._model_for: handled ModelConfigurationStoreError; continuing with fallback", exc_info=True)
        return _error(str(error), 503)
    if config is None:
        return _error(f"Model configuration '{model_id}' was not found.", 404)
    if not (await capabilities_for(request.app, config)).supports(flag):
        label = flag.replace("_", " ")
        return _error(f"Model '{model_id}' is not marked as supporting {label}.", 400)
    return config


def _services(request: Request) -> AudioServices:
    return getattr(request.app.state, "audio_services", None) or AudioServices()


async def transcribe(request: Request) -> Response:
    """``POST /api/v1/audio/transcriptions?modelId=`` with the recording as the body."""
    config = await _model_for(request, request.query_params.get("modelId"), "speech_to_text")
    if isinstance(config, Response):
        return config
    declared = request.headers.get("content-length")
    if declared and declared.isdigit() and int(declared) > MAX_AUDIO_BYTES:
        return _error("The recording is larger than 25 MB.", 413)
    body = await request.body()
    media_type = request.headers.get("content-type", "audio/webm")
    try:
        text = await _services(request).transcribe(
            config, body, media_type, language=request.query_params.get("language")
        )
    except AudioServiceError as error:
        _LOG.warning("audio.routes.transcribe: handled AudioServiceError; continuing with fallback", exc_info=True)
        return _error(str(error), error.status_code)
    return JSONResponse({"text": text})


async def speak(request: Request) -> Response:
    """``POST /api/v1/audio/speech`` with ``{modelId, input, voice?, format?}``."""
    try:
        body = await request.json()
    except ValueError:
        _LOG.warning("audio.routes.speak: handled ValueError; continuing with fallback", exc_info=True)
        return _error("Invalid request body.", 400)
    if not isinstance(body, dict) or not isinstance(body.get("input"), str):
        return _error("input is required.", 400)
    config = await _model_for(request, body.get("modelId"), "text_to_speech")
    if isinstance(config, Response):
        return config
    voice = body.get("voice") if isinstance(body.get("voice"), str) else None
    audio_format = body.get("format") if isinstance(body.get("format"), str) else "mp3"
    try:
        result = await _services(request).speak(config, body["input"], voice, audio_format)
    except AudioServiceError as error:
        _LOG.warning("audio.routes.speak: handled AudioServiceError; continuing with fallback", exc_info=True)
        return _error(str(error), error.status_code)
    return Response(result.audio, media_type=result.media_type)


def audio_routes() -> list[Route]:
    return [
        Route("/api/v1/audio/transcriptions", transcribe, methods=["POST"]),
        Route("/api/v1/audio/speech", speak, methods=["POST"]),
    ]
