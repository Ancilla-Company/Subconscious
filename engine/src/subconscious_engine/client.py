"""Local authenticated client used by the Subconscious command-line harness."""

from dataclasses import dataclass
import json
from pathlib import Path
import sys
from typing import Any, TextIO
from urllib.parse import quote, urlencode
from uuid import uuid4

import httpx
from websockets.asyncio.client import connect

from .config import EngineConfig
from .runtime import RuntimeInfo, RuntimeInfoReader


class EngineClientError(RuntimeError):
    """A user-actionable runtime, REST, or WebSocket client failure."""


@dataclass(frozen=True, slots=True)
class ChatResult:
    response: str
    thread_uuid: str
    created_thread: bool


async def one_shot_chat(
    prompt: str,
    *,
    workspace: str | None = None,
    thread: str | None = None,
    tools: bool = False,
    dev: bool = False,
    data_directory: Path | None = None,
    timeout: float = 300.0,
    error_output: TextIO = sys.stderr,
) -> ChatResult:
    config = EngineConfig(dev=dev, data_directory=data_directory)
    runtime = RuntimeInfoReader.read(config.resolved_data_directory)
    if runtime is None:
        raise EngineClientError(
            "The engine is not running or its runtime file is unavailable; "
            "run 'subconscious start'."
        )
    headers = {"Authorization": f"Bearer {runtime.token}"}
    base_url = f"http://{runtime.host}:{runtime.port}/api/v1/"
    try:
        async with httpx.AsyncClient(
            base_url=base_url, headers=headers, timeout=10.0, trust_env=False
        ) as client:
            health = await client.get("health")
            health.raise_for_status()
            target = await _resolve_target(client, workspace, thread)
    except (httpx.HTTPError, ValueError) as error:
        raise EngineClientError(f"Could not connect to the engine: {error}") from error

    return await _run_turn(
        runtime,
        prompt,
        target,
        tools=tools,
        timeout=timeout,
        error_output=error_output,
    )
@dataclass(frozen=True, slots=True)
class _ChatTarget:
    key: str
    value: str
    creates_thread: bool


async def _resolve_target(
    client: httpx.AsyncClient,
    workspace: str | None,
    thread: str | None,
) -> _ChatTarget:
    if thread is not None:
        response = await client.get(f"threads/{quote(thread, safe='')}")
        if response.status_code == 404:
            raise EngineClientError(f"Thread '{thread}' was not found.")
        response.raise_for_status()
        return _ChatTarget("thread_uuid", thread, False)

    workspace_uuid = await _resolve_workspace(client, workspace)
    return _ChatTarget("workspace_uuid", workspace_uuid, True)


async def _resolve_workspace(
    client: httpx.AsyncClient, selector: str | None
) -> str:
    if selector is not None:
        direct = await client.get(f"workspaces/{quote(selector, safe='')}")
        if direct.status_code == 200:
            return _required_string(direct.json(), "uuid", "workspace")
        if direct.status_code != 404:
            direct.raise_for_status()

    response = await client.get("workspaces")
    response.raise_for_status()
    payload = response.json()
    if not isinstance(payload, list):
        raise EngineClientError("The engine returned an invalid workspace list.")
    name = selector or "General"
    matches = [
        item
        for item in payload
        if isinstance(item, dict)
        and isinstance(item.get("name"), str)
        and item["name"].casefold() == name.casefold()
    ]
    if len(matches) > 1:
        raise EngineClientError(
            f"Workspace name '{name}' is ambiguous; specify its UUID."
        )
    if matches:
        return _required_string(matches[0], "uuid", "workspace")
    if selector is not None:
        raise EngineClientError(f"Workspace '{selector}' was not found.")

    created = await client.post("workspaces", json={"name": "General"})
    created.raise_for_status()
    return _required_string(created.json(), "uuid", "workspace")


def _required_string(payload: Any, key: str, kind: str) -> str:
    if not isinstance(payload, dict) or not isinstance(payload.get(key), str):
        raise EngineClientError(f"The engine returned an invalid {kind} response.")
    return payload[key]
async def _run_turn(
    runtime: RuntimeInfo,
    prompt: str,
    target: _ChatTarget,
    *,
    tools: bool,
    timeout: float,
    error_output: TextIO,
) -> ChatResult:
    query = urlencode({"token": runtime.token})
    endpoint = f"ws://{runtime.host}:{runtime.port}/api/v1/events?{query}"
    turn_id = f"cli-{uuid4().hex}"
    client_id = f"cli-{uuid4().hex}"
    chunks: list[str] = []
    try:
        async with connect(endpoint, open_timeout=10, close_timeout=5) as socket:
            await socket.send(
                json.dumps(
                    {"v": 1, "type": "client.hello", "data": {"clientId": client_id}}
                )
            )
            await _wait_for_hello(socket, timeout)
            await socket.send(
                json.dumps(
                    {
                        "v": 1,
                        "type": "chat.send",
                        "id": turn_id,
                        "data": {
                            "content": prompt,
                            target.key: target.value,
                            "tools_enabled": tools,
                        },
                    }
                )
            )
            while True:
                frame = await _receive_frame(socket, timeout)
                frame_type = frame.get("type")
                data = frame.get("data") if isinstance(frame.get("data"), dict) else {}
                if frame_type == "tool.approval.request" and frame.get("id") == turn_id:
                    approval_id = data.get("approval_id")
                    if isinstance(approval_id, str):
                        print(
                            "Tool approval denied in non-interactive chat mode.",
                            file=error_output,
                        )
                        await socket.send(
                            json.dumps(
                                {
                                    "v": 1,
                                    "type": "tool.approval.response",
                                    "id": turn_id,
                                    "data": {
                                        "approval_id": approval_id,
                                        "decision": "deny",
                                    },
                                }
                            )
                        )
                    continue
                if frame_type == "error":
                    raise EngineClientError(str(data.get("error", "Engine request failed.")))
                if frame.get("id") != turn_id:
                    continue
                if frame_type == "chat.delta":
                    delta = data.get("delta")
                    if isinstance(delta, str):
                        chunks.append(delta)
                elif frame_type == "chat.error":
                    raise EngineClientError(str(data.get("error", "Chat turn failed.")))
                elif frame_type == "chat.cancelled":
                    raise EngineClientError("Chat turn was cancelled.")
                elif frame_type == "chat.done":
                    thread_uuid = data.get("thread_uuid")
                    if not isinstance(thread_uuid, str) or not thread_uuid:
                        raise EngineClientError("The engine omitted the chat thread ID.")
                    return ChatResult("".join(chunks), thread_uuid, target.creates_thread)
    except EngineClientError:
        raise
    except Exception as error:
        raise EngineClientError(f"Chat connection failed: {error}") from error
async def _wait_for_hello(socket: Any, timeout: float) -> None:
    while True:
        frame = await _receive_frame(socket, timeout)
        frame_type = frame.get("type")
        data = frame.get("data") if isinstance(frame.get("data"), dict) else {}
        if frame_type == "client.hello.ack":
            return
        if frame_type == "client.hello.reject":
            raise EngineClientError(str(data.get("reason", "Engine rejected the client.")))
        if frame_type == "error":
            raise EngineClientError(str(data.get("error", "Engine handshake failed.")))


async def _receive_frame(socket: Any, timeout: float) -> dict[str, Any]:
    import asyncio

    try:
        raw = await asyncio.wait_for(socket.recv(), timeout)
    except TimeoutError as error:
        raise EngineClientError(f"The engine did not respond within {timeout:g} seconds.") from error
    if not isinstance(raw, str):
        raise EngineClientError("The engine returned a non-text WebSocket frame.")
    try:
        frame = json.loads(raw)
    except json.JSONDecodeError as error:
        raise EngineClientError("The engine returned invalid WebSocket JSON.") from error
    if not isinstance(frame, dict):
        raise EngineClientError("The engine returned an invalid WebSocket frame.")
    return frame
