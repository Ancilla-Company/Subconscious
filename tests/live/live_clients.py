"""Client simulators for the live tests.

* ``ThinClient``: a thin node (browser extension, web page, phone ...) built from the engine's REAL
  hive client pieces: ``HiveApi`` (server registry), ``SignalingClient`` (the server's ``/signal``
  socket) and ``PeerManager`` (the encrypted socket relay, or WebRTC when not forced). It registers
  with exactly the ``platform`` and ``name`` it is given, which is what the server then lists.
* ``LocalClient``: a client on the engine's own WebSocket (``/api/v1/events``), the way the desktop
  app, TUI, VS Code and a loopback browser extension talk to the engine.
"""

from __future__ import annotations

import asyncio
import base64
import json
import time
from contextlib import suppress
from typing import Any
from urllib.parse import urlencode

from websockets.asyncio.client import connect as ws_connect

from hive_testkit import until
from subconscious_engine.hive.directory import Directory, HiveApi, PinStore
from subconscious_engine.hive.identity import NodeIdentity, register_message
from subconscious_engine.hive.peers import PeerManager
from subconscious_engine.hive.signaling import SignalingClient


class ThinClient:
    """A registered thin node with a live signalling socket and a peer manager."""

    def __init__(
        self,
        server_url: str,
        account: dict[str, Any],
        *,
        name: str = "Thin",
        platform: str = "browser",
        kind: str = "thin",
        force_relay: bool = True,
        identity: NodeIdentity | None = None,
    ) -> None:
        self.server_url = server_url
        self.account = account
        self.name, self.platform, self.kind = name, platform, kind
        self.force_relay = force_relay
        self.identity = identity or NodeIdentity.generate()
        self.api = HiveApi(server_url, lambda: self.account["access_token"])
        self.directory = Directory(self.account["user_id"], self.identity.node_id, PinStore(None))
        self.signaling: SignalingClient | None = None
        self.peers: PeerManager | None = None
        self.online: dict[str, bool] = {}
        self.frames: list[tuple[str, Any]] = []  # (channel, Envelope) from every link
        self.registered: dict[str, Any] = {}

    @property
    def node_id(self) -> str:
        return self.identity.node_id

    async def register(self) -> dict[str, Any]:
        """Enrol with the server (``POST /nodes``) exactly as a real client does."""
        key = self.identity.public_key_b64u
        self.registered = await self.api.register({
            "kind": self.kind, "name": self.name, "platform": self.platform, "app_version": "0",
            "protocol_version": 1, "public_key": key,
            "proof": self.identity.sign(register_message(self.account["user_id"], key)),
        })
        return self.registered

    async def refresh(self) -> dict[str, Any]:
        listing = await self.api.list_nodes()
        self.directory.update(listing["nodes"], listing["hive_id"])
        return listing

    async def start(self, *, connect_timeout: float = 20.0) -> "ThinClient":
        """Register (idempotent), load the directory and open the signalling socket."""
        if not self.registered:
            await self.register()
        await self.refresh()
        self.signaling = SignalingClient(self.api, self.identity)
        ice_cache: dict[str, Any] = {}

        async def ice() -> dict[str, Any]:
            if not ice_cache:
                ice_cache.update(await self.api.ice_config(self.node_id))
            return dict(ice_cache)

        self.peers = PeerManager(
            self.identity, self.directory, self.signaling, ice,
            relay_sender=self.signaling, relay_enabled=True, force_relay=self.force_relay, direct_timeout=5.0,
        )
        self.signaling.on("signal", self.peers.handle_signal)
        self.signaling.on("relay", self.peers.handle_relay)
        self.signaling.on("presence.snapshot", self._on_presence)
        self.signaling.on("presence.update", self._on_presence)
        self.signaling.start()
        await self.signaling.wait_connected(connect_timeout)
        return self

    async def _on_presence(self, data: dict[str, Any]) -> None:
        entries = data.get("nodes")
        for entry in entries if isinstance(entries, list) else [data]:
            if isinstance(entry, dict) and isinstance(entry.get("node_id"), str):
                self.online[entry["node_id"]] = entry.get("online") is True

    async def disconnect_signalling(self) -> None:
        """Close the signalling socket (the node then goes offline after the server's grace)."""
        if self.signaling is not None:
            await self.signaling.stop()
            self.signaling = None

    async def open_link(self, engine_node_id: str, *, timeout: float = 40.0) -> Any:
        """Connect to an engine (waits until the directory lists it) and record every inbound frame."""

        async def trusted() -> bool:
            await self.refresh()
            return self.directory.is_trusted(engine_node_id)

        await until(trusted, timeout, step=0.3)
        assert self.peers is not None
        last: Exception | None = None
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                link = await self.peers.connect(engine_node_id)
            except ConnectionError as error:  # the engine may not know us yet; its directory refreshes on presence
                last = error
                await asyncio.sleep(0.5)
                continue
            link.handler = lambda _link, channel, envelope: self.frames.append((channel, envelope))
            return link
        raise AssertionError(f"could not open a link to {engine_node_id}: {last!r}")

    def link(self, engine_node_id: str) -> Any:
        assert self.peers is not None
        return self.peers.link(engine_node_id)

    def of_type(self, frame_type: str, identifier: str | None = None) -> list[Any]:
        return [
            envelope for _channel, envelope in self.frames
            if envelope.type == frame_type and (identifier is None or envelope.id == identifier)
        ]

    async def wait_for(self, frame_type: str, identifier: str | None = None, *, timeout: float = 30.0) -> Any:
        await until(lambda: self.of_type(frame_type, identifier), timeout, step=0.05)
        return self.of_type(frame_type, identifier)[-1]

    async def say(self, engine_node_id: str, frame_type: str, data: Any = None, identifier: str | None = None) -> None:
        link = self.link(engine_node_id)
        assert link is not None, "open_link first"
        await link.send_frame("control", frame_type, data if data is not None else {}, identifier)

    async def hello(self, engine_node_id: str, *, client_type: str = "browser_extension", name: str | None = None) -> Any:
        """``client.hello`` over the link; returns the next ack/reject frame."""
        before = len(self.of_type("client.hello.ack")) + len(self.of_type("client.hello.reject"))
        await self.say(engine_node_id, "client.hello", {"clientType": client_type, "clientName": name or self.name})
        await until(
            lambda: len(self.of_type("client.hello.ack")) + len(self.of_type("client.hello.reject")) > before, 20, 0.05
        )
        replies = [e for _c, e in self.frames if e.type in {"client.hello.ack", "client.hello.reject"}]
        return replies[before]

    async def chat(self, engine_node_id: str, workspace_uuid: str, text: str, *, turn_id: str, timeout: float = 40.0) -> str:
        """One ``chat.send`` round trip (echo model); returns the streamed text."""
        await self.say(engine_node_id, "chat.send", {"workspace_uuid": workspace_uuid, "content": text}, turn_id)
        await self.wait_for("chat.done", turn_id, timeout=timeout)
        return "".join(e.data["delta"] for e in self.of_type("chat.delta", turn_id))

    async def rest(self, engine_node_id: str, method: str, path: str, *, timeout: float = 20.0) -> tuple[int, Any]:
        """A REST call through the link's ``rpc`` channel (``http.request`` frame)."""
        identifier = f"rpc-{time.monotonic_ns()}"
        link = self.link(engine_node_id)
        await link.send_frame("rpc", "http.request", {"method": method, "path": path}, identifier)
        await until(lambda: self.of_type("http.response", identifier), timeout, step=0.05)
        data = self.of_type("http.response", identifier)[-1].data
        body = base64.b64decode(data["body"]) if data.get("body") else b""
        try:
            return data["status"], json.loads(body) if body else None
        except ValueError:
            return data["status"], body

    async def delete_node(self) -> None:
        """``DELETE /nodes/{id}`` (what 'remove this device' does)."""
        await self.api.revoke(self.node_id)

    async def stop(self) -> None:
        with suppress(Exception):
            if self.peers is not None:
                await self.peers.close()
        with suppress(Exception):
            await self.disconnect_signalling()
        with suppress(Exception):
            await self.api.close()


class LocalClient:
    """A client on the engine's own WebSocket; collects every frame it receives."""

    def __init__(
        self,
        engine: Any,
        *,
        client_id: str | None = None,
        client_type: str = "browser_extension",
        client_name: str = "Live client",
        token: str | None = None,
        extra_query: dict[str, str] | None = None,
    ) -> None:
        self.engine = engine
        self.client_id = client_id
        self.client_type, self.client_name = client_type, client_name
        self.token = token or engine.token
        self.extra_query = extra_query or {}
        self.frames: list[dict[str, Any]] = []
        self.socket: Any = None
        self.close_code: int | None = None
        self._reader: asyncio.Task[None] | None = None

    def url(self) -> str:
        query = {"token": self.token, "client_type": self.client_type, "client_name": self.client_name, **self.extra_query}
        return f"ws://{self.engine.url.split('://', 1)[1]}/api/v1/events?{urlencode(query)}"

    async def connect(self) -> "LocalClient":
        self.socket = await ws_connect(self.url(), open_timeout=10, max_size=8 * 1024 * 1024)
        self._reader = asyncio.create_task(self._read())
        return self

    async def _read(self) -> None:
        try:
            async for raw in self.socket:
                self.frames.append(json.loads(raw))
        except Exception:  # noqa: BLE001 - the socket ended; the close code is read below
            pass
        finally:
            self.close_code = self.socket.close_code

    async def send(self, frame_type: str, data: Any = None, identifier: str | None = None) -> None:
        frame: dict[str, Any] = {"v": 1, "type": frame_type, "data": data if data is not None else {}}
        if identifier is not None:
            frame["id"] = identifier
        await self.socket.send(json.dumps(frame))

    def of_type(self, frame_type: str, identifier: str | None = None) -> list[dict[str, Any]]:
        return [f for f in self.frames if f.get("type") == frame_type and (identifier is None or f.get("id") == identifier)]

    async def wait_for(self, frame_type: str, identifier: str | None = None, *, timeout: float = 30.0, after: int = 0) -> dict[str, Any]:
        await until(lambda: len(self.of_type(frame_type, identifier)) > after, timeout, step=0.03)
        return self.of_type(frame_type, identifier)[-1]

    async def hello(self, client_id: str | None = None, *, expect: str = "client.hello.ack") -> dict[str, Any]:
        """Send ``client.hello`` and return the next ack/reject."""
        before = len(self.of_type("client.hello.ack")) + len(self.of_type("client.hello.reject"))
        data: dict[str, Any] = {"clientType": self.client_type, "clientName": self.client_name}
        if client_id or self.client_id:
            data["clientId"] = client_id or self.client_id
        await self.send("client.hello", data)
        await until(
            lambda: len(self.of_type("client.hello.ack")) + len(self.of_type("client.hello.reject")) > before, 15, 0.03
        )
        replies = [f for f in self.frames if f["type"] in {"client.hello.ack", "client.hello.reject"}]
        return replies[before]

    async def chat(self, workspace_uuid: str, text: str, *, turn_id: str, timeout: float = 30.0) -> str:
        await self.send("chat.send", {"workspace_uuid": workspace_uuid, "content": text}, turn_id)
        await self.wait_for("chat.done", turn_id, timeout=timeout)
        return "".join(f["data"]["delta"] for f in self.of_type("chat.delta", turn_id))

    async def close(self) -> None:
        with suppress(Exception):
            await self.socket.close()
        if self._reader is not None:
            with suppress(Exception):
                await asyncio.wait_for(self._reader, 5)

    async def __aenter__(self) -> "LocalClient":
        return await self.connect()

    async def __aexit__(self, *_exc: object) -> None:
        await self.close()
