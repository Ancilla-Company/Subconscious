"""Speech-to-text and text-to-speech against OpenAI-compatible audio endpoints.

Local servers (faster-whisper-server, Kokoro-FastAPI, LocalAI ...) speak the same
``/audio/transcriptions`` and ``/audio/speech`` protocol, so one client covers cloud and
local models; only the configured ``base_url`` differs.
"""

from __future__ import annotations

import mimetypes
from dataclasses import dataclass

import httpx

from subconscious_engine.configuration.models import ModelConfig
import logging
_LOG = logging.getLogger(__name__)

DEFAULT_BASE_URL = "https://api.openai.com/v1"
MAX_AUDIO_BYTES = 25 * 1024 * 1024
MAX_SPEECH_CHARS = 4096
SPEECH_MEDIA_TYPES = {
    "mp3": "audio/mpeg",
    "opus": "audio/ogg",
    "aac": "audio/aac",
    "flac": "audio/flac",
    "wav": "audio/wav",
    "pcm": "audio/pcm",
}


class AudioServiceError(RuntimeError):
    """A provider rejected or failed an audio request; the message is user presentable."""

    def __init__(self, message: str, status_code: int = 502) -> None:
        super().__init__(message)
        self.status_code = status_code


@dataclass(frozen=True, slots=True)
class SpeechResult:
    audio: bytes
    media_type: str


def _base_url(config: ModelConfig) -> str:
    base = (config.base_url or "").strip() or DEFAULT_BASE_URL
    return base.rstrip("/")


def _headers(config: ModelConfig) -> dict[str, str]:
    key = (config.api_key or "").strip()
    return {"Authorization": f"Bearer {key}"} if key else {}


def _problem(response: httpx.Response) -> AudioServiceError:
    detail = ""
    try:
        body = response.json()
        error = body.get("error") if isinstance(body, dict) else None
        detail = (error.get("message") if isinstance(error, dict) else error) or ""
    except ValueError:
        _LOG.warning("audio.services._problem: handled ValueError; continuing with fallback", exc_info=True)
        detail = response.text[:200]
    return AudioServiceError(
        f"The audio provider returned {response.status_code}. {detail}".strip()
    )


class AudioServices:
    def __init__(self, client: httpx.AsyncClient | None = None, timeout: float = 120.0) -> None:
        self._client = client
        self._timeout = timeout

    async def _post(self, url: str, config: ModelConfig, **arguments) -> httpx.Response:
        owned = self._client is None
        client = self._client or httpx.AsyncClient(timeout=self._timeout)
        try:
            response = await client.post(
                url, headers=_headers(config), timeout=self._timeout, **arguments
            )
        except httpx.HTTPError as error:
            raise AudioServiceError(f"Could not reach the audio provider: {error}") from error
        finally:
            if owned:
                await client.aclose()
        if response.status_code >= 400:
            raise _problem(response)
        return response

    async def transcribe(
        self,
        config: ModelConfig,
        audio: bytes,
        media_type: str = "audio/webm",
        filename: str | None = None,
        language: str | None = None,
    ) -> str:
        if not audio:
            raise AudioServiceError("No audio was provided.", 400)
        if len(audio) > MAX_AUDIO_BYTES:
            raise AudioServiceError("The recording is larger than 25 MB.", 413)
        extension = (mimetypes.guess_extension(media_type.split(";")[0].strip()) or ".bin")
        data = {"model": config.model, "response_format": "json"}
        if language:
            data["language"] = language
        response = await self._post(
            f"{_base_url(config)}/audio/transcriptions",
            config,
            files={"file": (filename or f"recording{extension}", audio, media_type)},
            data=data,
        )
        try:
            text = response.json().get("text")
        except (ValueError, AttributeError):
            _LOG.warning("audio.services.AudioServices.transcribe: handled (ValueError, AttributeError); continuing with fallback", exc_info=True)
            text = None
        if not isinstance(text, str):
            raise AudioServiceError("The provider returned no transcript.")
        return text.strip()

    async def speak(
        self,
        config: ModelConfig,
        text: str,
        voice: str | None = None,
        audio_format: str = "mp3",
    ) -> SpeechResult:
        text = text.strip()
        if not text:
            raise AudioServiceError("There is no text to speak.", 400)
        if len(text) > MAX_SPEECH_CHARS:
            raise AudioServiceError(
                f"Text to speak is limited to {MAX_SPEECH_CHARS} characters.", 413
            )
        if audio_format not in SPEECH_MEDIA_TYPES:
            raise AudioServiceError(f"Unsupported audio format '{audio_format}'.", 400)
        configured_voice = (config.extra or {}).get("voice")
        response = await self._post(
            f"{_base_url(config)}/audio/speech",
            config,
            json={
                "model": config.model,
                "input": text,
                "voice": voice or (configured_voice if isinstance(configured_voice, str) else "alloy"),
                "response_format": audio_format,
            },
        )
        return SpeechResult(response.content, SPEECH_MEDIA_TYPES[audio_format])
