"""Realtime speech-to-speech bridge (OpenAI Realtime protocol).

The realtime model is the voice front-end. Everything that needs the user's files, tools
or multi-step work goes through function calls; the bridge hands each call to a handler
(the websocket session runs it through the normal agent graph) and speaks the result.
Audio is PCM16 mono, base64 encoded, in both directions.
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Awaitable, Callable
from typing import Any, Protocol
from urllib.parse import quote, urlsplit, urlunsplit
from ..logging_setup import spawn_logged
_LOG = logging.getLogger(__name__)

logger = logging.getLogger(__name__)

DEFAULT_REALTIME_URL = "wss://api.openai.com/v1/realtime"
DEFAULT_TRANSCRIPTION_MODEL = "gpt-4o-mini-transcribe"
SAMPLE_RATE = 24_000

ASK_AGENT_TOOL: dict[str, Any] = {
    "type": "function",
    "name": "ask_agent",
    "description": (
        "Hand a request to the user's agent, which can read their files and notes, use "
        "tools and do multi-step work. Call it for anything beyond casual conversation. "
        "Pass the user's request in their own words. It returns the agent's answer."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "request": {"type": "string", "description": "What the user asked for."}
        },
        "required": ["request"],
    },
}

INSTRUCTIONS = (
    "You are the voice of the user's personal agent. Keep spoken replies short and natural. "
    "For small talk answer directly. For anything that needs information, files, tools or "
    "several steps, call ask_agent with the user's request and then tell the user the result "
    "in a sentence or two. Say a brief acknowledgement before a call that may take a while."
)

EmitFn = Callable[[str, dict[str, Any]], Awaitable[None]]
FunctionHandler = Callable[[str, dict[str, Any]], Awaitable[str]]


class RealtimeUpstream(Protocol):
    async def send(self, event: dict[str, Any]) -> None: ...
    async def receive(self) -> dict[str, Any] | None: ...
    async def close(self) -> None: ...


def realtime_url(base_url: str | None, model: str) -> str:
    """Derive the realtime websocket URL from a configured OpenAI-compatible base URL."""
    base = (base_url or "").strip()
    if not base:
        return f"{DEFAULT_REALTIME_URL}?model={quote(model, safe='')}"
    parts = urlsplit(base)
    scheme = {"http": "ws", "https": "wss"}.get(parts.scheme, parts.scheme)
    path = parts.path.rstrip("/")
    if not path.endswith("/realtime"):
        path += "/realtime"
    return urlunsplit((scheme, parts.netloc, path, f"model={quote(model, safe='')}", ""))


class WebsocketsUpstream:
    """The real connection, using the ``websockets`` client."""

    def __init__(self, connection: Any) -> None:
        self._connection = connection

    @classmethod
    async def connect(cls, url: str, api_key: str | None) -> "WebsocketsUpstream":
        from websockets.asyncio.client import connect

        from ..tls import ssl_for_url

        headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        return cls(
            await connect(url, additional_headers=headers, max_size=None, ssl=ssl_for_url(url))
        )

    async def send(self, event: dict[str, Any]) -> None:
        await self._connection.send(json.dumps(event))

    async def receive(self) -> dict[str, Any] | None:
        from websockets.exceptions import ConnectionClosed

        try:
            raw = await self._connection.recv()
        except ConnectionClosed:
            _LOG.warning("audio.realtime.WebsocketsUpstream.receive: handled ConnectionClosed; continuing with fallback", exc_info=True)
            return None
        try:
            event = json.loads(raw)
        except (TypeError, ValueError):
            _LOG.warning("audio.realtime.WebsocketsUpstream.receive: handled (TypeError, ValueError); continuing with fallback", exc_info=True)
            return {}
        return event if isinstance(event, dict) else {}

    async def close(self) -> None:
        await self._connection.close()


class RealtimeBridge:
    def __init__(
        self,
        upstream: RealtimeUpstream,
        emit: EmitFn,
        call_function: FunctionHandler,
        *,
        model: str,
        voice: str = "marin",
        instructions: str = INSTRUCTIONS,
        tools: list[dict[str, Any]] | None = None,
        transcription_model: str | None = DEFAULT_TRANSCRIPTION_MODEL,
    ) -> None:
        self.upstream, self._emit, self._call_function = upstream, emit, call_function
        self.model, self.voice, self.instructions = model, voice, instructions
        self.tools = tools if tools is not None else [ASK_AGENT_TOOL]
        self.transcription_model = transcription_model
        self._pump_task: asyncio.Task[None] | None = None
        self._calls: set[asyncio.Task[None]] = set()
        self._handled: set[str] = set()
        self._stopped = False

    def session_update(self) -> dict[str, Any]:
        audio_input: dict[str, Any] = {
            "format": {"type": "audio/pcm", "rate": SAMPLE_RATE},
            "turn_detection": {"type": "semantic_vad"},
        }
        if self.transcription_model:
            audio_input["transcription"] = {"model": self.transcription_model}
        return {
            "type": "session.update",
            "session": {
                "type": "realtime",
                "model": self.model,
                "output_modalities": ["audio"],
                "instructions": self.instructions,
                "tools": self.tools,
                "tool_choice": "auto",
                "audio": {
                    "input": audio_input,
                    "output": {
                        "format": {"type": "audio/pcm", "rate": SAMPLE_RATE},
                        "voice": self.voice,
                    },
                },
            },
        }

    async def start(self) -> None:
        await self.upstream.send(self.session_update())
        self._pump_task = spawn_logged(self._pump())

    async def send_audio(self, audio_base64: str) -> None:
        if not self._stopped:
            await self.upstream.send({"type": "input_audio_buffer.append", "audio": audio_base64})

    async def interrupt(self) -> None:
        if not self._stopped:
            await self.upstream.send({"type": "response.cancel"})

    async def stop(self) -> None:
        if self._stopped:
            return
        self._stopped = True
        tasks = [*self._calls]
        if self._pump_task is not None and self._pump_task is not asyncio.current_task():
            tasks.append(self._pump_task)
        for task in tasks:
            if task is not asyncio.current_task():
                task.cancel()
        for task in tasks:
            if task is not asyncio.current_task():
                try:
                    await task
                except (asyncio.CancelledError, Exception):
                    _LOG.debug("audio.realtime.RealtimeBridge.stop: handled (asyncio.CancelledError, Exception); continuing with fallback", exc_info=True)
                    pass
        try:
            await self.upstream.close()
        except Exception:
            _LOG.exception("audio.realtime.RealtimeBridge.stop: handled Exception; continuing with fallback")
            pass
        await self._emit("realtime.stopped", {})

    async def _pump(self) -> None:
        try:
            while True:
                event = await self.upstream.receive()
                if event is None:
                    break
                await self._handle(event)
        except asyncio.CancelledError:
            raise
        except Exception as error:
            logger.warning("realtime pump failed: %s", error)
            await self._emit("realtime.error", {"error": str(error)})
        if not self._stopped:
            await self.stop()

    async def _handle(self, event: dict[str, Any]) -> None:
        kind = event.get("type")
        if kind == "response.output_audio.delta" and isinstance(event.get("delta"), str):
            await self._emit("realtime.audio", {"audio": event["delta"]})
        elif kind == "response.output_audio_transcript.delta":
            await self._emit("realtime.transcript", {
                "role": "assistant", "text": event.get("delta", ""), "final": False})
        elif kind == "response.output_audio_transcript.done":
            await self._emit("realtime.transcript", {
                "role": "assistant", "text": event.get("transcript", ""), "final": True})
        elif kind == "conversation.item.input_audio_transcription.completed":
            await self._emit("realtime.transcript", {
                "role": "user", "text": event.get("transcript", ""), "final": True})
        elif kind == "input_audio_buffer.speech_started":
            await self._emit("realtime.speech_started", {})
        elif kind == "response.function_call_arguments.done":
            self._begin_call(event.get("call_id"), event.get("name"), event.get("arguments"))
        elif kind == "response.done":
            output = (event.get("response") or {}).get("output") or []
            for item in output:
                if isinstance(item, dict) and item.get("type") == "function_call":
                    self._begin_call(item.get("call_id"), item.get("name"), item.get("arguments"))
        elif kind == "error":
            error = event.get("error")
            message = error.get("message") if isinstance(error, dict) else error
            await self._emit("realtime.error", {"error": str(message or "Realtime error.")})

    def _begin_call(self, call_id: Any, name: Any, arguments: Any) -> None:
        if not isinstance(call_id, str) or not isinstance(name, str) or call_id in self._handled:
            return
        self._handled.add(call_id)
        task = spawn_logged(self._run_call(call_id, name, arguments))
        self._calls.add(task)
        task.add_done_callback(self._calls.discard)

    async def _run_call(self, call_id: str, name: str, arguments: Any) -> None:
        await self._emit("realtime.tool", {"name": name, "call_id": call_id, "status": "started"})
        try:
            parsed = json.loads(arguments) if isinstance(arguments, str) and arguments else {}
            if not isinstance(parsed, dict):
                raise ValueError("Function arguments must be an object.")
            output = await self._call_function(name, parsed)
            status = "done"
        except asyncio.CancelledError:
            raise
        except Exception as error:
            _LOG.exception("audio.realtime.RealtimeBridge._run_call: handled Exception; continuing with fallback")
            output = json.dumps({"error": str(error) or error.__class__.__name__})
            status = "failed"
        await self._emit("realtime.tool", {"name": name, "call_id": call_id, "status": status})
        await self.upstream.send({
            "type": "conversation.item.create",
            "item": {"type": "function_call_output", "call_id": call_id, "output": output},
        })
        await self.upstream.send({"type": "response.create"})
