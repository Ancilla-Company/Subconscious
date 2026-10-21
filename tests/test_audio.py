"""Capabilities, speech-to-text / text-to-speech routes and the realtime voice bridge."""

import asyncio
import json
from types import SimpleNamespace

import httpx
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from hive_testkit import mesh, until
from subconscious_engine.api.app import create_app
from subconscious_engine.audio import AudioServices
from subconscious_engine.audio.realtime import ASK_AGENT_TOOL, realtime_url
from subconscious_engine.auth import EngineAuthToken
from subconscious_engine.capabilities import (
    CapabilityResolver,
    ModelCapabilities,
    RemoteCapabilitySource,
    adapt_remote_payload,
    heuristic_capabilities,
)
from subconscious_engine.configuration.models import ModelConfig, ModelConfigurationDto
from subconscious_engine.storage import Database
from subconscious_engine.storage.models import Message
from test_hive_tasks import TokenAgent, local_session, run


# --- capabilities -----------------------------------------------------------------------------


def test_heuristics_recognise_common_model_families():
    assert heuristic_capabilities("openai", "whisper-1").speech_to_text is True
    assert heuristic_capabilities("openai", "gpt-4o-mini-transcribe").speech_to_text is True
    assert heuristic_capabilities("openai", "gpt-4o-mini-tts").text_to_speech is True
    realtime = heuristic_capabilities("openai", "gpt-realtime")
    assert realtime.realtime and realtime.audio_input and realtime.audio_output
    assert realtime.chat is False
    assert heuristic_capabilities("openai", "gpt-4o-audio-preview").audio_input is True
    plain = heuristic_capabilities("ollama", "llama3")
    assert plain.known() == {} and not plain.supports("speech_to_text")


def test_remote_payload_adapter_accepts_the_common_shapes():
    assert adapt_remote_payload({"speechToText": True, "chat": False}).speech_to_text is True
    nested = adapt_remote_payload({"capabilities": {"realtime": True}, "id": "x"})
    assert nested.realtime is True
    lite = adapt_remote_payload({"mode": "audio_transcription"})
    assert lite.speech_to_text is True and lite.chat is False
    modal = adapt_remote_payload({"modalities": {"input": ["text", "audio"], "output": ["text"]},
                                  "supports_function_calling": True})
    assert modal.audio_input is True and modal.audio_output is False and modal.tool_calling is True
    assert adapt_remote_payload({"unrelated": 1}) is None
    assert adapt_remote_payload("nope") is None


def test_resolver_layers_override_over_remote_over_heuristics_and_survives_outages():
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(request.url.params.get("model"))
        if request.url.params.get("model") == "down":
            return httpx.Response(500)
        return httpx.Response(200, json={"capabilities": {"speechToText": True, "chat": False}})

    async def scenario():
        client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
        remote = RemoteCapabilitySource("https://caps.example/lookup", client=client)
        resolver = CapabilityResolver(remote)
        remote_only = await resolver.resolve("openai", "custom-model")
        assert remote_only.speech_to_text is True and "remote" in remote_only.sources
        await resolver.resolve("openai", "custom-model")
        assert calls == ["custom-model"]  # cached
        overridden = await resolver.resolve("openai", "custom-model", {"speechToText": False})
        assert overridden.speech_to_text is False and overridden.sources[0] == "override"
        # remote knowledge beats the heuristic, the heuristic fills the gaps
        merged = await resolver.resolve("openai", "whisper-large")
        assert merged.speech_to_text is True and merged.chat is False
        # an unreachable service never breaks resolution
        fallback = await resolver.resolve("openai", "down")
        assert fallback.known() == {}
        assert (await CapabilityResolver().resolve("openai", "gpt-realtime")).realtime is True

    run(scenario())


# --- REST: model catalog, transcription, speech ----------------------------------------------


def make_store(models):
    """models: id -> (provider, model, capabilities override)"""
    configs = {
        key: ModelConfig(id=key, provider=p, model=m, api_key="sk-test", extra={"capabilities": caps} if caps else {})
        for key, (p, m, caps) in models.items()
    }
    dtos = [ModelConfigurationDto(id=key, provider=p, model=m, hasApiKey=True, capabilities=caps)
            for key, (p, m, caps) in models.items()]

    async def resolve(identifier):
        return configs.get(identifier)

    async def listing():
        return dtos

    return SimpleNamespace(resolve=resolve, list=listing)


def build_app(tmp_path, models, audio):
    return create_app(Database(tmp_path / "t.db"), EngineAuthToken("tok"),
                      model_configuration_store=make_store(models), audio_services=audio,
                      dev_models=True)


def client_for(app):
    return AsyncClient(transport=ASGITransport(app=app), base_url="http://t",
                       headers={"Authorization": "Bearer tok"})


def test_models_endpoint_reports_capabilities_and_user_overrides(tmp_path):
    async def scenario():
        app = build_app(tmp_path, {
            "stt": ("openai", "whisper-1", None),
            "mine": ("openai-compatible", "my-local-asr", {"speech_to_text": True, "chat": False}),
            "chat": ("openai", "gpt-4.1", None),
        }, AudioServices())
        async with client_for(app) as http:
            models = {m["id"]: m for m in (await http.get("/api/v1/models")).json()}
        assert models["stt"]["capabilities"]["speechToText"] is True
        assert models["mine"]["capabilities"]["speechToText"] is True
        assert models["mine"]["capabilities"]["sources"][0] == "override"
        assert models["chat"]["capabilities"].get("speechToText") is None
        assert models["echo"]["capabilities"]["chat"] is True

    run(scenario())


def test_transcription_and_speech_routes_call_the_provider_and_check_capabilities(tmp_path):
    seen = {}

    def provider(request: httpx.Request) -> httpx.Response:
        seen[request.url.path] = request
        if request.url.path.endswith("/audio/transcriptions"):
            return httpx.Response(200, json={"text": " hello world "})
        return httpx.Response(200, content=b"MP3DATA")

    async def scenario():
        audio = AudioServices(httpx.AsyncClient(transport=httpx.MockTransport(provider)))
        app = build_app(tmp_path, {
            "stt": ("openai-compatible", "whisper-1", None),
            "tts": ("openai", "gpt-4o-mini-tts", None),
            "chat": ("openai", "gpt-4.1", None),
        }, audio)
        async with client_for(app) as http:
            ok = await http.post("/api/v1/audio/transcriptions?modelId=stt", content=b"RIFFxxxx",
                                 headers={"Content-Type": "audio/wav"})
            assert ok.status_code == 200 and ok.json() == {"text": "hello world"}
            sent = seen["/v1/audio/transcriptions"]
            assert sent.headers["authorization"] == "Bearer sk-test"
            assert b"whisper-1" in sent.content and b"RIFFxxxx" in sent.content
            wrong = await http.post("/api/v1/audio/transcriptions?modelId=chat", content=b"x",
                                    headers={"Content-Type": "audio/wav"})
            assert wrong.status_code == 400 and "speech to text" in wrong.json()["error"]
            missing = await http.post("/api/v1/audio/transcriptions?modelId=nope", content=b"x")
            assert missing.status_code == 404
            spoken = await http.post("/api/v1/audio/speech",
                                     json={"modelId": "tts", "input": "Hi there", "format": "wav"})
            assert spoken.status_code == 200 and spoken.content == b"MP3DATA"
            assert spoken.headers["content-type"] == "audio/wav"
            body = json.loads(seen["/v1/audio/speech"].content)
            assert body["model"] == "gpt-4o-mini-tts" and body["input"] == "Hi there"
            assert (await http.post("/api/v1/audio/speech",
                                    json={"modelId": "stt", "input": "x"})).status_code == 400
            assert (await http.post("/api/v1/audio/speech",
                                    json={"modelId": "tts", "input": "x" * 5000})).status_code == 413

    run(scenario())


# --- realtime ---------------------------------------------------------------------------------


class FakeUpstream:
    def __init__(self):
        self.sent, self.inbox, self.closed = [], asyncio.Queue(), False

    async def send(self, event):
        self.sent.append(event)

    async def receive(self):
        return await self.inbox.get()

    async def close(self):
        self.closed = True
        await self.inbox.put(None)


def test_realtime_url_follows_the_configured_base():
    assert realtime_url(None, "gpt-realtime") == "wss://api.openai.com/v1/realtime?model=gpt-realtime"
    assert realtime_url("http://localhost:8000/v1", "m") == "ws://localhost:8000/v1/realtime?model=m"
    assert realtime_url("https://h/v1/realtime", "m") == "wss://h/v1/realtime?model=m"


def test_realtime_voice_session_streams_audio_and_runs_function_calls_through_the_agent(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a"], agent_manager=TokenAgent(["The ", "answer"])) as (engines, _):
            a = engines["a"]
            upstream = FakeUpstream()

            async def connector(config):
                assert config.model == "gpt-realtime"
                return upstream

            a.app.state.model_configuration_store = make_store({
                "rt": ("openai", "gpt-realtime", None),
                "plain": ("openai", "gpt-4.1", None),
            })
            a.app.state.realtime_connector = connector
            ws = await a.workspace("W")
            session = local_session(a.app)

            # a model without the capability is refused
            await session._handle({"type": "realtime.start", "id": "bad",
                                   "data": {"model_id": "plain", "workspace_uuid": ws}})
            assert any(f["type"] == "realtime.error" and f["id"] == "bad" for f in session.frames)

            await session._handle({"type": "realtime.start", "id": "rt1", "data": {
                "model_id": "rt", "workspace_uuid": ws, "agent_model_id": "echo"}})
            await until(lambda: any(f["type"] == "realtime.started" for f in session.frames))
            update = upstream.sent[0]
            assert update["type"] == "session.update"
            assert update["session"]["tools"] == [ASK_AGENT_TOOL]
            assert update["session"]["audio"]["input"]["format"] == {"type": "audio/pcm", "rate": 24000}

            # microphone audio goes up, model audio and transcripts come down
            await session._handle({"type": "realtime.audio", "data": {"audio": "AAAA"}})
            assert {"type": "input_audio_buffer.append", "audio": "AAAA"} in upstream.sent
            await upstream.inbox.put({"type": "response.output_audio.delta", "delta": "QkJC"})
            await upstream.inbox.put({"type": "input_audio_buffer.speech_started"})
            await upstream.inbox.put({"type": "conversation.item.input_audio_transcription.completed",
                                      "transcript": "what is the answer"})
            await until(lambda: any(f["type"] == "realtime.speech_started" for f in session.frames))
            audio = [f for f in session.frames if f["type"] == "realtime.audio"]
            assert audio and audio[0]["data"]["audio"] == "QkJC"
            transcript = [f for f in session.frames if f["type"] == "realtime.transcript"]
            assert transcript[0]["data"] == {"role": "user", "text": "what is the answer", "final": True}

            # a function call runs the real agent turn and its answer goes back to the model
            call = {"type": "response.function_call_arguments.done", "call_id": "c1",
                    "name": "ask_agent", "arguments": json.dumps({"request": "what is the answer"})}
            await upstream.inbox.put(call)
            await upstream.inbox.put({"type": "response.done", "response": {"output": [
                {"type": "function_call", **{k: call[k] for k in ("call_id", "name", "arguments")}}]}})
            await until(lambda: any(e.get("type") == "response.create" for e in upstream.sent))
            outputs = [e for e in upstream.sent if e.get("item", {}).get("type") == "function_call_output"]
            assert len(outputs) == 1  # the duplicate announcement was ignored
            assert outputs[0]["item"]["call_id"] == "c1" and outputs[0]["item"]["output"] == "The answer"
            thread = next(f["data"]["thread_uuid"] for f in session.frames if f["type"] == "realtime.thread")
            async with a.database.session() as db:
                rows = [(m.role, m.content) for m in (await db.scalars(select(Message).order_by(Message.hlc)))]
            assert rows == [("user", "what is the answer"), ("assistant", "The answer")]
            assert thread

            await session._handle({"type": "realtime.stop"})
            await until(lambda: any(f["type"] == "realtime.stopped" for f in session.frames))
            assert upstream.closed and session.realtime is None

    run(scenario())


def test_realtime_function_errors_are_returned_to_the_model_not_raised(tmp_path):
    async def scenario():
        async with mesh(tmp_path, ["a"], agent_manager=TokenAgent(["x"])) as (engines, _):
            a = engines["a"]
            upstream = FakeUpstream()

            async def connector(config):
                return upstream

            a.app.state.model_configuration_store = make_store({"rt": ("openai", "gpt-realtime", None)})
            a.app.state.realtime_connector = connector
            session = local_session(a.app)
            await session._handle({"type": "realtime.start", "id": "r", "data": {
                "model_id": "rt", "workspace_uuid": await a.workspace("W")}})
            await until(lambda: any(f["type"] == "realtime.started" for f in session.frames))
            await upstream.inbox.put({"type": "response.function_call_arguments.done", "call_id": "c9",
                                      "name": "nonsense", "arguments": "{}"})
            await until(lambda: any(e.get("type") == "response.create" for e in upstream.sent))
            output = next(e["item"]["output"] for e in upstream.sent
                          if e.get("item", {}).get("type") == "function_call_output")
            assert "Unknown function" in json.loads(output)["error"]
            await session._handle({"type": "realtime.stop"})

    run(scenario())


def test_websockets_upstream_authenticates_sends_and_reports_close():
    from websockets.asyncio.server import serve

    from subconscious_engine.audio.realtime import WebsocketsUpstream

    async def scenario():
        seen = {}

        async def handler(connection):
            seen["auth"] = connection.request.headers.get("Authorization")
            seen["path"] = connection.request.path
            message = json.loads(await connection.recv())
            await connection.send(json.dumps({"type": "echo", "got": message["type"]}))

        async with serve(handler, "127.0.0.1", 0) as server:
            port = server.sockets[0].getsockname()[1]
            upstream = await WebsocketsUpstream.connect(
                f"ws://127.0.0.1:{port}/v1/realtime?model=m", "sk-live")
            await upstream.send({"type": "session.update"})
            assert await upstream.receive() == {"type": "echo", "got": "session.update"}
            assert await upstream.receive() is None  # server closed after the handler returned
            await upstream.close()
        assert seen == {"auth": "Bearer sk-live", "path": "/v1/realtime?model=m"}

    run(scenario())


def test_capability_overrides_are_stored_with_the_model_and_reach_the_resolved_config(tmp_path, monkeypatch):
    from cryptography.fernet import Fernet

    from subconscious_engine.configuration import EncryptedModelConfigurationStore

    monkeypatch.setenv("SUBCONSCIOUS_FERNET_KEY", Fernet.generate_key().decode())

    async def scenario():
        store = EncryptedModelConfigurationStore(tmp_path)
        created = await store.create({
            "provider": "openai-compatible", "model": "my-asr", "baseUrl": "http://localhost:9000/v1",
            "capabilities": {"speechToText": True, "chat": False, "bogus": True},
        })
        assert created.capabilities == {"speech_to_text": True, "chat": False}
        resolved = await store.resolve(created.id)
        caps = await CapabilityResolver().resolve(
            resolved.provider, resolved.model, (resolved.extra or {}).get("capabilities"))
        assert caps.speech_to_text is True and caps.chat is False
        # omitting capabilities keeps them; an empty object clears them
        kept = await store.update(created.id, {"provider": "openai-compatible", "model": "my-asr"})
        assert kept.capabilities == {"speech_to_text": True, "chat": False}
        cleared = await store.update(created.id, {
            "provider": "openai-compatible", "model": "my-asr", "capabilities": {}})
        assert cleared.capabilities is None

    run(scenario())
