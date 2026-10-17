"""Capability sources and the resolver that layers them."""

from __future__ import annotations

import asyncio
import logging
import re
import time
from collections.abc import Callable, Mapping
from typing import Any
from urllib.parse import quote

import httpx

from .models import ModelCapabilities

logger = logging.getLogger(__name__)


# --- built-in heuristics ----------------------------------------------------------------------

_STT = re.compile(r"whisper|transcri|speech-to-text|(^|[-_/])stt([-_/]|$)|parakeet")
_TTS = re.compile(r"(^|[-_/])tts|text-to-speech|kokoro|piper|xtts|speecht5|bark")
_REALTIME = re.compile(r"realtime|gpt-live|voice-live")
_AUDIO_CHAT = re.compile(r"gpt-4o(-mini)?-audio|audio-preview|gemini|omni|voxtral|ultravox")
_VISION = re.compile(r"gpt-4o|gpt-4\.1|gpt-5|gemini|claude|llava|vision|pixtral|qwen.*vl")


def heuristic_capabilities(provider: str, model: str) -> ModelCapabilities:
    """Best guess from the model id alone. A fallback for when no service knows better."""
    name = model.casefold()
    if _REALTIME.search(name):
        return ModelCapabilities(
            chat=False, tool_calling=True, audio_input=True, audio_output=True,
            realtime=True, sources=["heuristic"],
        )
    if _STT.search(name):
        return ModelCapabilities(
            chat=False, tool_calling=False, speech_to_text=True, sources=["heuristic"]
        )
    if _TTS.search(name):
        return ModelCapabilities(
            chat=False, tool_calling=False, text_to_speech=True, sources=["heuristic"]
        )
    flags: dict[str, bool] = {}
    if _AUDIO_CHAT.search(name):
        flags["audio_input"] = True
    if _VISION.search(name):
        flags["vision"] = True
    return ModelCapabilities(**flags, sources=["heuristic"] if flags else [])


# --- remote capability service ----------------------------------------------------------------

_ALIASES: dict[str, tuple[str, ...]] = {
    "chat": ("chat", "supports_chat"),
    "tool_calling": ("tool_calling", "toolCalling", "supports_function_calling",
                     "supports_tool_choice", "function_calling", "tools"),
    "vision": ("vision", "supports_vision", "image_input"),
    "audio_input": ("audio_input", "audioInput", "supports_audio_input"),
    "audio_output": ("audio_output", "audioOutput", "supports_audio_output"),
    "speech_to_text": ("speech_to_text", "speechToText", "stt", "transcription"),
    "text_to_speech": ("text_to_speech", "textToSpeech", "tts", "speech"),
    "realtime": ("realtime", "supports_realtime", "speech_to_speech"),
}
_MODES = {
    "audio_transcription": {"speech_to_text": True, "chat": False},
    "audio_speech": {"text_to_speech": True, "chat": False},
    "realtime": {"realtime": True, "audio_input": True, "audio_output": True, "chat": False},
    "chat": {"chat": True},
}


def adapt_remote_payload(payload: Any) -> ModelCapabilities | None:
    """Map a capability service response onto ``ModelCapabilities``.

    This is the single place that knows the remote shape. It accepts a flat object of
    flags (snake or camel case), the same under a ``capabilities`` key, a litellm style
    ``mode`` plus ``supports_*`` keys, and ``modalities: {input: [...], output: [...]}``.
    """
    if isinstance(payload, Mapping) and isinstance(payload.get("capabilities"), Mapping):
        merged = {**{k: v for k, v in payload.items() if k != "capabilities"},
                  **payload["capabilities"]}
    elif isinstance(payload, Mapping):
        merged = dict(payload)
    else:
        return None
    flags: dict[str, bool] = {}
    mode = merged.get("mode")
    if isinstance(mode, str):
        flags.update(_MODES.get(mode, {}))
    modalities = merged.get("modalities")
    if isinstance(modalities, Mapping):
        for direction, flag in (("input", "audio_input"), ("output", "audio_output")):
            values = modalities.get(direction)
            if isinstance(values, (list, tuple)):
                flags[flag] = "audio" in [str(v).casefold() for v in values]
        inputs = modalities.get("input")
        if isinstance(inputs, (list, tuple)):
            flags["vision"] = "image" in [str(v).casefold() for v in inputs]
    for flag, names in _ALIASES.items():
        for name in names:
            if isinstance(merged.get(name), bool):
                flags[flag] = merged[name]
                break
    if not flags:
        return None
    return ModelCapabilities(**flags, sources=["remote"])


class RemoteCapabilitySource:
    """Looks a model up on a capability service. Never blocks or breaks chat.

    ``url`` may contain ``{provider}`` and ``{model}`` placeholders; without them both
    are appended as query parameters. Results (including misses and failures) are cached.
    """

    def __init__(
        self,
        url: str,
        *,
        token: str | None = None,
        ttl_seconds: float = 6 * 3600,
        failure_ttl_seconds: float = 120,
        timeout_seconds: float = 3.0,
        client: httpx.AsyncClient | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.url, self.token = url, token
        self.ttl, self.failure_ttl, self.timeout = ttl_seconds, failure_ttl_seconds, timeout_seconds
        self._client = client
        self._clock = clock
        self._cache: dict[tuple[str, str], tuple[float, ModelCapabilities | None]] = {}
        self._inflight: dict[tuple[str, str], asyncio.Future[ModelCapabilities | None]] = {}

    def _request_url(self, provider: str, model: str) -> str:
        if "{provider}" in self.url or "{model}" in self.url:
            return self.url.replace("{provider}", quote(provider, safe="")).replace(
                "{model}", quote(model, safe="")
            )
        return self.url

    async def lookup(self, provider: str, model: str) -> ModelCapabilities | None:
        key = (provider.casefold(), model.casefold())
        cached = self._cache.get(key)
        if cached is not None and cached[0] > self._clock():
            return cached[1]
        pending = self._inflight.get(key)
        if pending is not None:
            return await asyncio.shield(pending)
        future: asyncio.Future[ModelCapabilities | None] = asyncio.get_running_loop().create_future()
        self._inflight[key] = future
        result: ModelCapabilities | None = None
        ttl = self.failure_ttl
        try:
            result = await self._fetch(provider, model)
            ttl = self.ttl
        except Exception as error:  # a down service must not affect chat
            logger.info("capability lookup failed for %s/%s: %s", provider, model, error)
        finally:
            self._cache[key] = (self._clock() + ttl, result)
            self._inflight.pop(key, None)
            future.set_result(result)
        return result

    async def _fetch(self, provider: str, model: str) -> ModelCapabilities | None:
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        params = None if ("{provider}" in self.url or "{model}" in self.url) else {
            "provider": provider, "model": model,
        }
        owned = self._client is None
        client = self._client or httpx.AsyncClient(timeout=self.timeout)
        try:
            response = await client.get(
                self._request_url(provider, model), params=params, headers=headers,
                timeout=self.timeout,
            )
        finally:
            if owned:
                await client.aclose()
        if response.status_code == 404:
            return None
        response.raise_for_status()
        return adapt_remote_payload(response.json())


# --- resolver ---------------------------------------------------------------------------------


class CapabilityResolver:
    """Layers user override > remote service > built-in heuristics."""

    def __init__(self, remote: RemoteCapabilitySource | None = None) -> None:
        self.remote = remote

    async def resolve(
        self, provider: str, model: str, override: Any = None
    ) -> ModelCapabilities:
        result = heuristic_capabilities(provider, model)
        if self.remote is not None:
            found = await self.remote.lookup(provider, model)
            if found is not None:
                result = result.overlaid_by(found, "remote")
        explicit = ModelCapabilities.from_override(override)
        if explicit.known():
            result = result.overlaid_by(explicit, "override")
        return result
