"""``sync.*`` frames over the ``sync`` data channel (webrtc.md 7.3).

Per link: both sides send ``sync.hello`` and then push whatever the other is
missing in bounded, acknowledged batches. After catch-up, new ops are pushed
live and accepted remote ops are forwarded to every other ready peer.
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any
from uuid import uuid4

from ..channels import Envelope
from ..peers import PeerLink
from .engine import SCHEMA_VERSION, SyncEngine
from .ops import OpError, SyncOp
from ...logging_setup import logged_suppress, spawn_logged
_LOG = logging.getLogger(__name__)

_LOGGER = logging.getLogger("uvicorn.error")
BATCH_OPS = 200
BATCH_BYTES = 256 * 1024
ACK_TIMEOUT_SECONDS = 30.0
PULL_INTERVAL_SECONDS = 2.0
MAX_OPS_PER_FRAME = 500
SYNC_FRAMES = frozenset({"sync.hello", "sync.ops", "sync.ack", "sync.snapshot", "sync.pull"})


@dataclass(slots=True)
class PeerSyncState:
    node_id: str
    link: PeerLink
    phase: str = "handshake"  # handshake | catching_up | snapshot | ready | closed
    verified: bool = False
    ready: bool = False
    remote_vv: dict[str, int] = field(default_factory=dict)
    ops_sent: int = 0
    ops_received: int = 0
    last_error: str | None = None
    catchup: asyncio.Task[None] | None = None
    waiters: dict[str, tuple[asyncio.Future[None], set[str]]] = field(default_factory=dict)
    last_pull: float = 0.0
    snapshot_open: bool = False
    pull_again: bool = False


class SyncCoordinator:
    def __init__(
        self,
        engine: SyncEngine,
        *,
        batch_ops: int = BATCH_OPS,
        batch_bytes: int = BATCH_BYTES,
        ack_timeout: float = ACK_TIMEOUT_SECONDS,
        on_mismatch: Callable[[str], None] | None = None,
    ) -> None:
        self.engine = engine
        self.batch_ops = batch_ops
        self.batch_bytes = batch_bytes
        self.ack_timeout = ack_timeout
        self.on_mismatch = on_mismatch
        self.peers: dict[str, PeerSyncState] = {}
        self._tasks: set[asyncio.Task[Any]] = set()
        self._unsubscribe = engine.subscribe(self._on_local_ops)
        self._loop: asyncio.AbstractEventLoop | None = None

    # --- lifecycle ----------------------------------------------------------
    def close(self) -> None:
        self._unsubscribe()
        for task in list(self._tasks):
            task.cancel()
        for state in list(self.peers.values()):
            self._drop(state)
        self.peers.clear()

    def _spawn(self, coro: Any) -> asyncio.Task[Any]:
        task = spawn_logged(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return task

    def on_link(self, link: PeerLink) -> None:
        """A hive_peer link opened: introduce ourselves."""
        self._loop = asyncio.get_running_loop()
        previous = self.peers.pop(link.node_id, None)
        if previous is not None:
            self._drop(previous)
        state = PeerSyncState(link.node_id, link)
        self.peers[link.node_id] = state
        self._spawn(self._send_hello(state))

    def on_link_closed(self, node_id: str) -> None:
        state = self.peers.pop(node_id, None)
        if state is not None:
            self._drop(state)

    def _drop(self, state: PeerSyncState) -> None:
        state.phase, state.ready = "closed", False
        if state.catchup is not None:
            state.catchup.cancel()
        for future, _ in state.waiters.values():
            if not future.done():
                future.cancel()
        state.waiters.clear()

    async def _send(self, state: PeerSyncState, frame_type: str, data: dict[str, Any]) -> None:
        await state.link.send("sync", Envelope(frame_type, data))

    async def _send_hello(self, state: PeerSyncState) -> None:
        if self.engine.hive_id is None or self.engine.blocked is not None:
            return
        vv = await self.engine.version_vector()
        with logged_suppress(Exception):
            await self._send(state, "sync.hello", {
                "hive_id": self.engine.hive_id, "vv": vv, "schema_version": SCHEMA_VERSION})

    # --- inbound ------------------------------------------------------------
    def on_frame(self, link: PeerLink, envelope: Envelope) -> None:
        state = self.peers.get(link.node_id)
        if state is None or state.link is not link or envelope.type not in SYNC_FRAMES:
            return
        data = envelope.data if isinstance(envelope.data, dict) else {}
        self._spawn(self._dispatch(state, envelope.type, data))

    async def _dispatch(self, state: PeerSyncState, frame_type: str, data: dict[str, Any]) -> None:
        try:
            if frame_type == "sync.hello":
                await self._on_hello(state, data)
            elif frame_type == "sync.ack":
                self._on_ack(state, data)
            elif not state.verified:
                return  # nothing but a matching hello unlocks the channel
            elif frame_type == "sync.ops":
                await self._on_ops(state, data)
            elif frame_type == "sync.snapshot":
                await self._on_snapshot(state, data)
            elif frame_type == "sync.pull":
                vv = _vv(data.get("vv"))
                state.remote_vv = vv if vv is not None else state.remote_vv
                self._start_catchup(state)
        except asyncio.CancelledError:
            raise
        except Exception:
            state.last_error = "frame_failed"
            _LOGGER.warning("Sync frame failed.", exc_info=True)

    async def _on_hello(self, state: PeerSyncState, data: dict[str, Any]) -> None:
        if data.get("hive_id") != self.engine.hive_id or self.engine.hive_id is None:
            state.last_error = "hive_mismatch"
            if self.on_mismatch is not None:
                self.on_mismatch(state.node_id)
            await state.link.close()
            return
        vv = _vv(data.get("vv"))
        if vv is None:
            state.last_error = "bad_hello"
            await state.link.close()
            return
        state.remote_vv, state.verified = vv, True
        first = state.phase == "handshake"
        if first:
            state.phase = "catching_up"
        self._start_catchup(state)

    def _on_ack(self, state: PeerSyncState, data: dict[str, Any]) -> None:
        batch, origin = data.get("batch"), data.get("origin")
        waiter = state.waiters.get(batch) if isinstance(batch, str) else None
        if waiter is None or not isinstance(origin, str):
            return
        future, remaining = waiter
        remaining.discard(origin)
        if not remaining and not future.done():
            future.set_result(None)

    async def _on_ops(self, state: PeerSyncState, data: dict[str, Any]) -> None:
        batch = data.get("batch")
        ops = self._parse(data.get("ops"))
        state.ops_received += len(ops)
        report = await self.engine.apply(ops)
        await self._ack(state, batch, ops)
        for op, reason in report.rejected:
            _LOGGER.info("Rejected a sync op (%s).", reason)
        if report.accepted:
            self._broadcast(report.accepted, exclude=state.node_id)
            await self._detect_gap(state, ops)

    async def _on_snapshot(self, state: PeerSyncState, data: dict[str, Any]) -> None:
        stage, batch = data.get("stage"), data.get("batch")
        if stage == "begin":
            state.snapshot_open = True
        elif stage == "ops" and state.snapshot_open:
            ops = self._parse(data.get("ops"))
            state.ops_received += len(ops)
            await self.engine.apply(ops)
            await self._ack(state, batch, ops)
            return
        elif stage == "end" and state.snapshot_open:
            vv, live = _vv(data.get("vv")), data.get("live")
            if vv is not None and isinstance(live, dict):
                clean = {k: [u for u in v if isinstance(u, str)] for k, v in live.items() if isinstance(v, list)}
                await self.engine.finish_snapshot(vv, clean)
            state.snapshot_open = False
        if isinstance(batch, str):
            await self._send(state, "sync.ack", {"batch": batch, "origin": "*", "seq": 0})

    @staticmethod
    def _parse(raw: Any) -> list[SyncOp]:
        if not isinstance(raw, list):
            return []
        ops: list[SyncOp] = []
        for item in raw[:MAX_OPS_PER_FRAME]:
            try:
                ops.append(SyncOp.from_wire(item))
            except OpError:
                _LOG.warning("hive.sync.protocol.SyncCoordinator._parse: handled OpError; continuing with fallback", exc_info=True)
                continue
        return ops

    async def _ack(self, state: PeerSyncState, batch: Any, ops: list[SyncOp]) -> None:
        if not isinstance(batch, str):
            return
        top: dict[str, int] = {}
        for op in ops:
            top[op.origin] = max(top.get(op.origin, 0), op.seq)
        if not top:
            await self._send(state, "sync.ack", {"batch": batch, "origin": "*", "seq": 0})
        for origin, seq in top.items():
            await self._send(state, "sync.ack", {"batch": batch, "origin": origin, "seq": seq})

    async def _detect_gap(self, state: PeerSyncState, ops: list[SyncOp]) -> None:
        vv = await self.engine.version_vector()
        if any(op.seq > vv.get(op.origin, 0) for op in ops):
            now = time.monotonic()
            if now - state.last_pull >= PULL_INTERVAL_SECONDS:
                state.last_pull = now
                with logged_suppress(Exception):
                    await self._send(state, "sync.pull", {"vv": vv})

    # --- outbound -------------------------------------------------------------
    def _start_catchup(self, state: PeerSyncState) -> None:
        if state.catchup is not None and not state.catchup.done():
            state.pull_again = True
            return
        state.catchup = self._spawn(self._catch_up(state))

    def _origin_ok(self, origin: str) -> bool:
        return self.engine.resolve_origin(origin) is not None

    async def _catch_up(self, state: PeerSyncState) -> None:
        try:
            while True:
                if await self.engine.needs_snapshot(state.remote_vv):
                    state.phase = "snapshot"
                    state.remote_vv = await self._send_snapshot(state)
                    state.phase = "catching_up"
                cursor = dict(state.remote_vv)
                while True:
                    ops = await self.engine.read_ops(
                        cursor, max_ops=self.batch_ops, max_bytes=self.batch_bytes, origin_ok=self._origin_ok)
                    if not ops:
                        break
                    await self._send_batch(state, "sync.ops", {"live": False}, ops)
                    for op in ops:
                        cursor[op.origin] = max(cursor.get(op.origin, 0), op.seq)
                    state.remote_vv = dict(cursor)
                if not state.ready:
                    state.ready = True  # live pushes flow from here; one more pass closes the race
                    state.phase = "ready"
                    continue
                if state.pull_again:
                    state.pull_again = False
                    continue
                break
        except asyncio.TimeoutError:
            _LOG.warning("hive.sync.protocol.SyncCoordinator._catch_up: handled asyncio.TimeoutError; continuing with fallback", exc_info=True)
            state.last_error = "ack_timeout"
        except Exception:
            state.last_error = "catchup_failed"
            _LOGGER.warning("Sync catch-up failed.", exc_info=True)

    async def _send_batch(
        self, state: PeerSyncState, frame_type: str, extra: dict[str, Any], ops: list[SyncOp]
    ) -> None:
        batch = uuid4().hex
        origins = {op.origin for op in ops}
        future: asyncio.Future[None] = asyncio.get_running_loop().create_future()
        state.waiters[batch] = (future, set(origins))
        try:
            await self._send(state, frame_type, {"batch": batch, "ops": [op.to_wire() for op in ops], **extra})
            state.ops_sent += len(ops)
            await asyncio.wait_for(future, self.ack_timeout)
        finally:
            state.waiters.pop(batch, None)

    async def _send_snapshot(self, state: PeerSyncState) -> dict[str, int]:
        vv = await self.engine.version_vector()
        await self._send(state, "sync.snapshot", {"stage": "begin", "vv": vv})
        cursor: dict[str, int] = {}
        while True:
            ops = await self.engine.read_ops(
                cursor, max_ops=self.batch_ops, max_bytes=self.batch_bytes, origin_ok=self._origin_ok)
            if not ops:
                break
            await self._send_batch(state, "sync.snapshot", {"stage": "ops"}, ops)
            for op in ops:
                cursor[op.origin] = max(cursor.get(op.origin, 0), op.seq)
        live = await self.engine.export_live()
        batch = uuid4().hex
        future: asyncio.Future[None] = asyncio.get_running_loop().create_future()
        state.waiters[batch] = (future, {"*"})
        try:
            await self._send(state, "sync.snapshot", {"stage": "end", "batch": batch, "vv": vv, "live": live})
            await asyncio.wait_for(future, self.ack_timeout)
        finally:
            state.waiters.pop(batch, None)
        return vv

    # --- live push / forwarding ---------------------------------------------------
    def _on_local_ops(self, ops: list[SyncOp]) -> None:
        if not self.peers:
            return
        self._broadcast(ops, exclude=None)

    def _broadcast(self, ops: list[SyncOp], exclude: str | None) -> None:
        for node_id, state in list(self.peers.items()):
            if node_id == exclude or not state.ready:
                continue
            self._spawn(self._push(state, ops))

    async def _push(self, state: PeerSyncState, ops: list[SyncOp]) -> None:
        wire = [op.to_wire() for op in ops if self._origin_ok(op.origin)]
        if not wire:
            return
        try:
            for start in range(0, len(wire), self.batch_ops):
                await self._send(state, "sync.ops", {
                    "batch": uuid4().hex, "ops": wire[start:start + self.batch_ops], "live": True})
            state.ops_sent += len(wire)
        except Exception:
            _LOG.exception("hive.sync.protocol.SyncCoordinator._push: handled Exception; continuing with fallback")
            state.last_error = "push_failed"

    # --- reporting -------------------------------------------------------------------
    def status(self) -> list[dict[str, Any]]:
        return [
            {"node_id": s.node_id, "phase": s.phase, "ready": s.ready, "ops_sent": s.ops_sent,
             "ops_received": s.ops_received, "error": s.last_error}
            for s in self.peers.values()
        ]

    async def wait_ready(self, node_id: str, timeout: float = 30.0) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            state = self.peers.get(node_id)
            if state is not None and state.ready:
                return True
            await asyncio.sleep(0.05)
        return False


def _vv(raw: Any) -> dict[str, int] | None:
    if not isinstance(raw, dict) or len(raw) > 1024:
        return None
    out: dict[str, int] = {}
    for key, value in raw.items():
        if not isinstance(key, str) or not isinstance(value, int) or isinstance(value, bool) or value < 0:
            return None
        out[key] = value
    return out
