"""Tasks: agent work routed to one executor node (webrtc.md 7.4).

A task row is a normal synced entity. Only the executor writes its status after
creation (the creating node may additionally expire a task that was never
delivered). Statuses move forward only:

    queued -> running -> waiting_approval <-> running -> done|failed|cancelled|interrupted

The executor runs the existing ``_run_turn`` pipeline through a headless
``TaskSession``; its frames fan out to the requester and any thread viewers.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any
from uuid import uuid4

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from starlette.websockets import WebSocketDisconnect

from subconscious_engine.api.websocket import WebSocketSession, _parse_file_context
from subconscious_engine.approval import classify_operation
from subconscious_engine.storage.models import TaskRecord, utc_now

from .authz import HIVE_PEER, THIN_CLIENT
from .channels import Envelope
from ..logging_setup import logged_suppress, spawn_logged
_LOG = logging.getLogger(__name__)

_LOGGER = logging.getLogger("uvicorn.error")
DEFAULT_TTL_SECONDS = 600.0
SWEEP_INTERVAL_SECONDS = 1.0
MAX_CONTENT_CHARS = 1_000_000
LOCAL_NODE = "local"

TERMINAL = frozenset({"done", "failed", "cancelled", "interrupted"})
TRANSITIONS: dict[str, frozenset[str]] = {
    "queued": frozenset({"running", "failed", "cancelled", "interrupted"}),
    "running": frozenset({"waiting_approval", "done", "failed", "cancelled", "interrupted"}),
    "waiting_approval": frozenset({"running", "done", "failed", "cancelled", "interrupted"}),
    "done": frozenset(),
    "failed": frozenset(),
    "cancelled": frozenset(),
    "interrupted": frozenset(),
}
# Plain chat frames a hive peer may send us about a task or thread it executes.
PEER_EVENT_FRAMES = frozenset({
    "chat.delta", "chat.done", "chat.error", "chat.cancelled", "agui.event",
    "tool.approval.request", "tool.approval.resolved", "task.status",
    "task.accepted", "task.error", "thread.subscribed",
})


class TaskError(Exception):
    """A user-presentable task problem."""


class InvalidTransition(TaskError):
    """A status change that would move a task backwards or out of a final state."""


def can_transition(current: str, new: str) -> bool:
    return new in TRANSITIONS.get(current, frozenset())


@dataclass(frozen=True, slots=True)
class Principal:
    node_id: str
    role: str
    local: bool = False


class HiveContext:
    """What the manager needs from the hive; the standalone default is a lone engine."""

    local_node_id: str | None = None

    def node_role(self, node_id: str) -> str | None:
        """Role of an active same-account node, or ``None`` when unknown/inactive."""
        return None

    def link(self, node_id: str) -> Any | None:
        return None

    def links(self) -> dict[str, Any]:
        return {}

    def node_name(self, node_id: str) -> str | None:
        """Directory name of a trusted node (used to alias its remote tools)."""
        return None

    async def wait_synced(self, node_id: str, timeout: float = 10.0) -> bool:
        """Wait until history has been pushed to ``node_id`` (always true when nothing syncs)."""
        return True


@dataclass(slots=True)
class _Approval:
    task_id: str
    thread_uuid: str
    future: asyncio.Future[bool]


@dataclass(slots=True)
class _Relay:
    session: Any
    executor: str


def task_dict(row: TaskRecord) -> dict[str, Any]:
    def when(value: datetime | None) -> str | None:
        return value.replace(tzinfo=timezone.utc).isoformat() if value is not None else None

    return {
        "task_id": row.task_id, "thread_uuid": row.thread_uuid, "workspace_uuid": row.workspace_uuid,
        "executor_node_id": row.executor_node_id, "requester_node_id": row.requester_node_id,
        "status": row.status, "rev": row.rev, "turn_id": row.turn_id, "model_id": row.model_id,
        "client_msg_uuid": row.client_msg_uuid, "created_at": when(row.created_at),
        "started_at": when(row.started_at), "finished_at": when(row.finished_at), "error": row.error,
    }


class _FanoutSocket:
    """Transport for a headless turn: every frame goes to the task's audience."""

    def __init__(self, app: Any, manager: "TaskManager", task_id: str, thread_uuid: str) -> None:
        self.app = app
        self._manager = manager
        self._task_id = task_id
        self._thread_uuid = thread_uuid

    async def accept(self) -> None:
        return None

    async def receive_json(self) -> Any:
        raise WebSocketDisconnect(code=1001)

    async def send_json(self, data: Any) -> None:
        await self._manager.fan_out(self._task_id, self._thread_uuid, data)


class TaskSession(WebSocketSession):
    """A ``WebSocketSession`` driven by a task instead of a client connection."""

    def __init__(self, app: Any, manager: "TaskManager", task_id: str, thread_uuid: str) -> None:
        super().__init__(_FanoutSocket(app, manager, task_id, thread_uuid))
        self.manager = manager
        self.task_id = task_id

    async def _request_approval(self, turn_id: str, thread_uuid: str, call: Any) -> bool:
        return await self.manager.request_approval(self.task_id, thread_uuid, call)


class TaskManager:
    def __init__(
        self,
        app: Any,
        *,
        ttl_seconds: float = DEFAULT_TTL_SECONDS,
        sweep_interval: float = SWEEP_INTERVAL_SECONDS,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.app = app
        self.ttl_seconds = ttl_seconds
        self.sweep_interval = sweep_interval
        self._clock = clock
        self.context: HiveContext = HiveContext()
        self.viewers: dict[str, set[Any]] = {}
        self.requesters: dict[str, Any] = {}
        self.relays: dict[str, _Relay] = {}
        self.runs: dict[str, asyncio.Task[Any]] = {}
        self.approvals: dict[str, _Approval] = {}
        self._delivered: dict[str, tuple[str, float]] = {}
        self._delivering: set[str] = set()
        self._submit_lock = asyncio.Lock()
        self._finishers: set[asyncio.Task[Any]] = set()
        self._upstream: dict[str, int] = {}
        self._sessions_threads: dict[Any, set[str]] = {}
        self._sweeper: asyncio.Task[None] | None = None
        self._stopping = False
        self._lock = asyncio.Lock()

    # --- wiring ---------------------------------------------------------------
    def bind(self, context: HiveContext) -> None:
        self.context = context

    @property
    def local_id(self) -> str:
        return self.context.local_node_id or LOCAL_NODE

    def start(self) -> None:
        self._stopping = False
        if self._sweeper is None or self._sweeper.done():
            self._sweeper = spawn_logged(self._sweep_loop())

    async def stop(self) -> None:
        self._stopping = True  # running tasks stay "running" so the next start marks them interrupted
        sweeper, self._sweeper = self._sweeper, None
        if sweeper is not None:
            sweeper.cancel()
            with logged_suppress(asyncio.CancelledError, Exception):
                await sweeper
        for run in list(self.runs.values()):
            run.cancel()
        for run in list(self.runs.values()):
            with logged_suppress(asyncio.CancelledError, Exception):
                await run
        for finisher in list(self._finishers):
            with logged_suppress(asyncio.CancelledError, Exception):
                await finisher
        self.runs.clear()

    def principal_of(self, session: Any) -> Principal:
        link = getattr(session.socket, "link", None)
        if link is not None:
            return Principal(link.node_id, link.role)
        return Principal(self.local_id, HIVE_PEER, True)

    # --- frames from sessions -----------------------------------------------------
    async def handle_frame(self, session: Any, frame_type: str, data: dict[str, Any], frame_id: str | None) -> None:
        if frame_type == "task.submit":
            await self.submit(session, data, frame_id)
        elif frame_type == "task.cancel":
            task_id = data.get("task_id") if isinstance(data.get("task_id"), str) else frame_id
            if isinstance(task_id, str):
                await self.cancel(session, task_id)
        elif frame_type == "thread.subscribe":
            await self.subscribe(session, data.get("thread_uuid"))
        elif frame_type == "thread.unsubscribe":
            await self.unsubscribe(session, data.get("thread_uuid"))

    # --- submit ---------------------------------------------------------------------
    async def submit(self, session: Any, data: dict[str, Any], frame_id: str | None) -> None:
        try:
            await self._submit(session, data, frame_id)
        except TaskError as error:
            _LOG.warning("hive.tasks.TaskManager.submit: handled TaskError; continuing with fallback", exc_info=True)
            await _send(session, "task.error", {
                "error": str(error), "client_msg_uuid": data.get("client_msg_uuid")}, frame_id)
        except Exception:
            _LOGGER.warning("Task submit failed.", exc_info=True)
            await _send(session, "task.error", {
                "error": "The task could not be submitted.",
                "client_msg_uuid": data.get("client_msg_uuid")}, frame_id)

    async def _submit(self, session: Any, data: dict[str, Any], frame_id: str | None) -> None:
        principal = self.principal_of(session)
        request = _parse_submit(data)
        requester = principal.node_id
        if request.forwarded:
            if principal.local or principal.role != HIVE_PEER:
                raise TaskError("Only a hive peer may forward a task.")
            # Re-authorise at the executor: the original requester must be an active
            # node of this account whose role may submit work.
            claimed = request.requester_node_id
            if not claimed or self.context.node_role(claimed) not in {THIN_CLIENT, HIVE_PEER}:
                raise TaskError("The requesting node is not authorised.")
            requester = claimed
        executor = request.executor or self.local_id
        if request.forwarded and executor != self.local_id:
            raise TaskError("A forwarded task must target this node.")
        # Look-up and insert must be atomic per node, or two submits of the same client
        # message (e.g. a retry racing a queued delivery) both try to create the row.
        async with self._submit_lock:
            deliver_id = await self._accept(session, request, requester, executor, frame_id)
        if deliver_id is not None:
            await self._deliver(deliver_id)

    async def _accept(
        self, session: Any, request: "_Submit", requester: str, executor: str, frame_id: str | None,
    ) -> str | None:
        """Create or find the task row. Returns a task id that still needs delivering."""
        existing = await self._by_client_message(request.client_msg_uuid)
        takeover = (
            existing is not None and request.forwarded
            and existing.status == "queued" and existing.executor_node_id == self.local_id
        )
        if existing is not None and not takeover:
            # Same client message: idempotent. Report (and follow) the task that already exists.
            await self._attach(session, existing)
            await _send(session, "task.accepted", task_dict(existing), frame_id)
            return None
        task_id = request.task_id or (existing.task_id if existing is not None else str(uuid4()))
        thread_uuid = request.thread_uuid or str(uuid4())
        workspace_uuid = request.workspace_uuid if request.new_thread else None
        if executor == self.local_id:
            row = await self._take_local(task_id, request, requester, thread_uuid, workspace_uuid)
            self.requesters[row.task_id] = session
            await _send(session, "task.accepted", task_dict(row), frame_id)
            await self._emit_status(row)
            self._spawn_run(row, request, thread_uuid, workspace_uuid)
            return None
        row = await self._queue_remote(task_id, request, requester, executor, thread_uuid, workspace_uuid)
        self.relays[row.task_id] = _Relay(session, executor)
        await _send(session, "task.accepted", task_dict(row), frame_id)
        await self._emit_status(row)
        return row.task_id

    async def _attach(self, session: Any, row: TaskRecord) -> None:
        if row.status not in TERMINAL:
            if row.executor_node_id == self.local_id:
                self.requesters.setdefault(row.task_id, session)
            else:
                self.relays.setdefault(row.task_id, _Relay(session, row.executor_node_id))

    async def _by_client_message(self, client_msg_uuid: str) -> TaskRecord | None:
        async with self.app.state.database.session() as db:
            return await db.scalar(select(TaskRecord).where(
                TaskRecord.client_msg_uuid == client_msg_uuid, TaskRecord.deleted_at.is_(None)))

    async def _take_local(
        self, task_id: str, request: "_Submit", requester: str, thread_uuid: str, workspace_uuid: str | None,
    ) -> TaskRecord:
        # Sync can deliver this very task row (created by the accepting node) between our
        # look-up and insert. Retry once: the second pass finds it and takes it over.
        try:
            return await self._take_local_once(task_id, request, requester, thread_uuid, workspace_uuid)
        except IntegrityError:
            _LOG.warning("hive.tasks.TaskManager._take_local: handled IntegrityError; continuing with fallback", exc_info=True)
            return await self._take_local_once(task_id, request, requester, thread_uuid, workspace_uuid)

    async def _take_local_once(
        self, task_id: str, request: "_Submit", requester: str, thread_uuid: str, workspace_uuid: str | None,
    ) -> TaskRecord:
        async with self.app.state.database.session() as db:
            row = await db.scalar(select(TaskRecord).where(TaskRecord.task_id == task_id))
            now = utc_now()
            if row is None:
                row = TaskRecord(
                    task_id=task_id, thread_uuid=thread_uuid, workspace_uuid=workspace_uuid,
                    executor_node_id=self.local_id, requester_node_id=requester, status="running", rev=1,
                    turn_id=task_id, model_id=request.model_id, client_msg_uuid=request.client_msg_uuid,
                    created_at=now, started_at=now)
                db.add(row)
            else:
                if not can_transition(row.status, "running"):
                    raise InvalidTransition("The task has already finished.")
                row.status, row.rev, row.started_at, row.turn_id = "running", row.rev + 1, now, task_id
                row.payload = None
            await db.commit()
            return row

    async def _queue_remote(
        self, task_id: str, request: "_Submit", requester: str, executor: str, thread_uuid: str,
        workspace_uuid: str | None,
    ) -> TaskRecord:
        payload = json.dumps({
            "content": request.content, "model_id": request.model_id, "file_context": request.file_context,
            "tools_enabled": request.tools_enabled, "new_thread": request.new_thread,
        })
        async with self.app.state.database.session() as db:
            row = TaskRecord(
                task_id=task_id, thread_uuid=thread_uuid, workspace_uuid=workspace_uuid,
                executor_node_id=executor, requester_node_id=requester, status="queued", rev=0,
                turn_id=task_id, model_id=request.model_id, client_msg_uuid=request.client_msg_uuid,
                created_at=utc_now(), payload=payload)
            db.add(row)
            await db.commit()
            return row

    # --- delivery to a remote executor ---------------------------------------------
    async def _deliver(self, task_id: str) -> None:
        async with self.app.state.database.session() as db:
            row = await db.scalar(select(TaskRecord).where(TaskRecord.task_id == task_id))
        if row is None or row.status != "queued" or not row.payload or row.executor_node_id == self.local_id:
            return
        link = self.context.link(row.executor_node_id)
        marker = (link.node_id, link.created) if link is not None else None
        if link is None or self._delivered.get(task_id) == marker:
            return
        # The executor needs the workspace and thread before it can run the turn, so let
        # history reach it first. Proceed anyway after the timeout; the executor reports
        # a clear error if the data is still missing.
        if task_id in self._delivering:
            return  # another caller (link open or the sweeper) is already on it
        self._delivering.add(task_id)
        try:
            await self.context.wait_synced(row.executor_node_id)
            link = self.context.link(row.executor_node_id)
            if link is None or self._delivered.get(task_id) == (link.node_id, link.created):
                return
            marker = (link.node_id, link.created)
            body = json.loads(row.payload)
            frame = {
                "task_id": row.task_id, "thread_uuid": row.thread_uuid, "workspace_uuid": row.workspace_uuid,
                "client_msg_uuid": row.client_msg_uuid, "executor": row.executor_node_id, "forwarded": True,
                "requester_node_id": row.requester_node_id, "content": body.get("content"),
                "model_id": body.get("model_id"), "file_context": body.get("file_context"),
                "tools_enabled": body.get("tools_enabled", True), "new_thread": body.get("new_thread", False),
            }
            try:
                await link.send("control", Envelope("task.submit", frame, row.task_id))
            except Exception:
                _LOG.exception("hive.tasks.TaskManager._deliver: handled Exception; continuing with fallback")
                return
            self._delivered[task_id] = marker
        finally:
            self._delivering.discard(task_id)

    async def on_link(self, link: Any) -> None:
        """A peer link opened: flush queued work for it and re-establish subscriptions."""
        async with self.app.state.database.session() as db:
            ids = (await db.scalars(select(TaskRecord.task_id).where(
                TaskRecord.status == "queued", TaskRecord.executor_node_id == link.node_id,
                TaskRecord.deleted_at.is_(None)))).all()
        for task_id in ids:
            await self._deliver(task_id)
        if link.role == HIVE_PEER:
            for thread_uuid in list(self._upstream):
                with logged_suppress(Exception):
                    await link.send("control", Envelope("thread.subscribe", {"thread_uuid": thread_uuid}))

    def on_link_closed(self, node_id: str) -> None:
        for task_id, (owner, _created) in list(self._delivered.items()):
            if owner == node_id:
                self._delivered.pop(task_id, None)

    # --- local execution -------------------------------------------------------------
    def _spawn_run(self, row: TaskRecord, request: "_Submit", thread_uuid: str, workspace_uuid: str | None) -> None:
        task_id = row.task_id
        session = TaskSession(self.app, self, task_id, thread_uuid)
        turn_data: dict[str, Any] = {"content": request.content, "model_id": request.model_id,
                                     "file_context": request.file_context,
                                     "tools_enabled": request.tools_enabled}
        if workspace_uuid is not None:
            turn_data["workspace_uuid"] = workspace_uuid
        else:
            turn_data["thread_uuid"] = thread_uuid
        turn = spawn_logged(session._run_turn(
            task_id, turn_data, client_msg_uuid=request.client_msg_uuid,
            thread_uuid_hint=thread_uuid if workspace_uuid is not None else None))
        self.runs[task_id] = turn
        finisher = spawn_logged(self._finish(task_id, turn))
        self._finishers.add(finisher)
        finisher.add_done_callback(self._finishers.discard)

    async def _finish(self, task_id: str, turn: "asyncio.Future[tuple[str, str | None]]") -> None:
        outcome, error = "failed", "The task did not complete."
        try:
            outcome, error = await turn
        except asyncio.CancelledError:
            _LOG.debug("hive.tasks.TaskManager._finish: handled asyncio.CancelledError; continuing with fallback", exc_info=True)
            outcome, error = "cancelled", None
        except Exception as failure:
            _LOG.exception("hive.tasks.TaskManager._finish: handled Exception; continuing with fallback")
            outcome, error = "failed", str(failure) or failure.__class__.__name__
        finally:
            self.runs.pop(task_id, None)
        # On shutdown the task stays "running" so the next start marks it interrupted.
        if not (self._stopping and outcome == "cancelled"):
            final = {"done": "done", "cancelled": "cancelled"}.get(outcome, "failed")
            with logged_suppress(Exception):
                row = await self.set_status(task_id, final, error=error)
                if row is not None:
                    await self._emit_status(row)
        self.requesters.pop(task_id, None)

    async def set_status(
        self, task_id: str, status: str, *, error: str | None = None, as_creator: bool = False
    ) -> TaskRecord | None:
        """Move a task forward. Only the executor (or the creator, for expiry) may write."""
        async with self.app.state.database.session() as db:
            row = await db.scalar(select(TaskRecord).where(TaskRecord.task_id == task_id))
            if row is None:
                return None
            is_executor = row.executor_node_id == self.local_id
            if not is_executor and not (as_creator and row.origin_node_id in {self.local_id, None}):
                raise TaskError("Only the executor writes a task's status.")
            if row.status == status:
                return row
            if not can_transition(row.status, status):
                raise InvalidTransition(f"A {row.status} task cannot become {status}.")
            row.status, row.rev = status, row.rev + 1
            now = utc_now()
            if status == "running" and row.started_at is None:
                row.started_at = now
            if status in TERMINAL:
                row.finished_at = now
                row.error = error
            if status != "queued":
                row.payload = None
            await db.commit()
            return row

    # --- engine restart -------------------------------------------------------------------
    async def recover(self) -> int:
        """After a restart, work this node was executing did not finish: mark it interrupted."""
        count = 0
        async with self.app.state.database.session() as db:
            rows = (await db.scalars(select(TaskRecord).where(
                TaskRecord.executor_node_id.in_({self.local_id, LOCAL_NODE}),
                TaskRecord.status.in_(("running", "waiting_approval"))))).all()
            now = utc_now()
            for row in rows:
                row.status, row.rev, row.finished_at = "interrupted", row.rev + 1, now
                row.error, row.payload = "The engine restarted while this task was running.", None
                count += 1
            await db.commit()
        return count

    # --- expiry / redelivery -----------------------------------------------------------------
    async def _sweep_loop(self) -> None:
        while True:
            await asyncio.sleep(self.sweep_interval)
            with logged_suppress(Exception):
                await self.sweep()

    async def sweep(self) -> int:
        """Expire undelivered tasks past their TTL and retry delivery for the rest."""
        expired = 0
        cutoff = datetime.fromtimestamp(self._clock() - self.ttl_seconds, timezone.utc).replace(tzinfo=None)
        async with self.app.state.database.session() as db:
            rows = (await db.scalars(select(TaskRecord).where(
                TaskRecord.status == "queued", TaskRecord.executor_node_id != self.local_id,
                TaskRecord.deleted_at.is_(None)))).all()
        for row in rows:
            if row.origin_node_id not in {self.local_id, None}:
                continue  # only the accepting node expires its own queue
            if row.created_at.replace(tzinfo=None) < cutoff:
                updated = await self.set_status(row.task_id, "failed", error="expired", as_creator=True)
                if updated is not None:
                    expired += 1
                    await self._emit_status(updated)
                    self.relays.pop(row.task_id, None)
            else:
                await self._deliver(row.task_id)
        return expired

    # --- cancel ---------------------------------------------------------------------------------
    async def cancel(self, session: Any, task_id: str) -> None:
        async with self.app.state.database.session() as db:
            row = await db.scalar(select(TaskRecord).where(TaskRecord.task_id == task_id))
        if row is None:
            return
        principal = self.principal_of(session)
        owns = (
            principal.local
            or self.requesters.get(task_id) is session
            or (task_id in self.relays and self.relays[task_id].session is session)
            or principal.node_id == row.requester_node_id
        )
        if not owns:
            await _send(session, "task.error", {"error": "Not permitted to cancel this task.",
                                                "task_id": task_id}, task_id)
            return
        if row.status in TERMINAL:
            return
        if row.executor_node_id == self.local_id:
            run = self.runs.get(task_id)
            if run is not None:
                run.cancel()
            elif row.status == "queued":
                updated = await self.set_status(task_id, "cancelled")
                if updated is not None:
                    await self._emit_status(updated)
            return
        link = self.context.link(row.executor_node_id)
        if link is not None:
            with logged_suppress(Exception):
                await link.send("control", Envelope("task.cancel", {"task_id": task_id}, task_id))
        elif row.status == "queued":
            updated = await self.set_status(task_id, "cancelled", as_creator=True)
            if updated is not None:
                await self._emit_status(updated)
                self.relays.pop(task_id, None)

    # --- viewers ---------------------------------------------------------------------------------
    async def subscribe(self, session: Any, thread_uuid: Any) -> None:
        if not isinstance(thread_uuid, str) or not thread_uuid or len(thread_uuid) > 64:
            await _send(session, "task.error", {"error": "thread.subscribe requires thread_uuid."}, None)
            return
        threads = self._sessions_threads.setdefault(session, set())
        if thread_uuid not in threads:
            threads.add(thread_uuid)
            self.viewers.setdefault(thread_uuid, set()).add(session)
            if not _is_hive_peer_session(session):
                await self._upstream_change(thread_uuid, +1)
        await _send(session, "thread.subscribed", {"thread_uuid": thread_uuid}, None)

    async def unsubscribe(self, session: Any, thread_uuid: Any) -> None:
        if isinstance(thread_uuid, str):
            await self._drop_subscription(session, thread_uuid)

    async def _drop_subscription(self, session: Any, thread_uuid: str) -> None:
        threads = self._sessions_threads.get(session)
        if threads is None or thread_uuid not in threads:
            return
        threads.discard(thread_uuid)
        viewers = self.viewers.get(thread_uuid)
        if viewers is not None:
            viewers.discard(session)
            if not viewers:
                self.viewers.pop(thread_uuid, None)
        if not _is_hive_peer_session(session):
            await self._upstream_change(thread_uuid, -1)

    async def _upstream_change(self, thread_uuid: str, delta: int) -> None:
        count = self._upstream.get(thread_uuid, 0) + delta
        if count > 0:
            self._upstream[thread_uuid] = count
        else:
            self._upstream.pop(thread_uuid, None)
        first, last = delta > 0 and count == 1, delta < 0 and count <= 0
        if not (first or last):
            return
        frame_type = "thread.subscribe" if first else "thread.unsubscribe"
        for link in self.context.links().values():
            if getattr(link, "role", None) == HIVE_PEER:
                with logged_suppress(Exception):
                    await link.send("control", Envelope(frame_type, {"thread_uuid": thread_uuid}))

    def session_closed(self, session: Any) -> None:
        for thread_uuid in list(self._sessions_threads.get(session, ())):
            spawn_logged(self._drop_subscription(session, thread_uuid))
        self._sessions_threads.pop(session, None)
        for task_id, relay in list(self.relays.items()):
            if relay.session is session:
                self.relays.pop(task_id, None)
        for task_id, owner in list(self.requesters.items()):
            if owner is session:
                self.requesters.pop(task_id, None)

    # --- fan-out --------------------------------------------------------------------------------------
    def _audience(self, task_id: str, thread_uuid: str) -> list[Any]:
        seen: list[Any] = []
        candidates = [self.requesters.get(task_id)]
        relay = self.relays.get(task_id)
        if relay is not None:
            candidates.append(relay.session)
        candidates.extend(self.viewers.get(thread_uuid, ()))
        for session in candidates:
            if session is not None and all(session is not other for other in seen):
                seen.append(session)
        return seen

    async def fan_out(self, task_id: str, thread_uuid: str, frame: dict[str, Any]) -> None:
        frame_type, data = frame.get("type"), frame.get("data")
        if not isinstance(frame_type, str):
            return
        for session in self._audience(task_id, thread_uuid):
            await _send(session, frame_type, data, frame.get("id"))

    async def _emit_status(self, row: TaskRecord) -> None:
        payload = task_dict(row)
        for session in self._audience(row.task_id, row.thread_uuid):
            await _send(session, "task.status", payload, row.task_id)

    async def on_peer_frame(self, link: Any, envelope: Envelope) -> None:
        """Events from a hive peer about work it runs: relay to the requester and local viewers."""
        data = envelope.data if isinstance(envelope.data, dict) else {}
        targets: list[Any] = []
        relay = self.relays.get(envelope.id) if envelope.id else None
        if relay is not None and relay.executor == link.node_id:
            targets.append(relay.session)
        thread_uuid = data.get("thread_uuid")
        if isinstance(thread_uuid, str):
            for viewer in self.viewers.get(thread_uuid, ()):
                # Hive-peer viewers are served by the executor directly; relaying to
                # them again would loop events around the mesh.
                if not _is_hive_peer_session(viewer) and all(viewer is not t for t in targets):
                    targets.append(viewer)
        for session in targets:
            await _send(session, envelope.type, data, envelope.id)
        if envelope.type == "task.status" and data.get("status") in TERMINAL and envelope.id:
            self.relays.pop(envelope.id, None)

    # --- approvals ------------------------------------------------------------------------------------
    async def request_approval(self, task_id: str, thread_uuid: str, call: Any) -> bool:
        approval_id = uuid4().hex
        future: asyncio.Future[bool] = asyncio.get_running_loop().create_future()
        self.approvals[approval_id] = _Approval(task_id, thread_uuid, future)
        row = await self.set_status(task_id, "waiting_approval")
        if row is not None:
            await self._emit_status(row)
        try:
            await self.fan_out(task_id, thread_uuid, {"type": "tool.approval.request", "id": task_id, "data": {
                "approval_id": approval_id, "thread_uuid": thread_uuid, "task_id": task_id,
                "tool_name": call.tool_name, "arguments": call.args_as_dict(),
                "operation": classify_operation(call.tool_name)}})
            return await future
        finally:
            self.approvals.pop(approval_id, None)
            with logged_suppress(Exception):
                row = await self.set_status(task_id, "running")
                if row is not None:
                    await self._emit_status(row)

    async def handle_approval(self, session: Any, frame_id: str | None, approval_id: str, decision: str) -> bool:
        """First valid response wins. Returns ``False`` when the approval is unknown here."""
        approval = self.approvals.get(approval_id)
        if approval is None:
            relay = self.relays.get(frame_id) if frame_id else None
            if relay is None or relay.session is not session:
                return False
            link = self.context.link(relay.executor)
            if link is not None:
                with logged_suppress(Exception):
                    await link.send("control", Envelope(
                        "tool.approval.response", {"approval_id": approval_id, "decision": decision}, frame_id))
            return True
        if frame_id is not None and frame_id != approval.task_id:
            await session._error("Approval response does not belong to this chat turn.")
            return True
        if session not in self._audience(approval.task_id, approval.thread_uuid):
            await session._error("This node may not answer that approval.")
            return True
        if approval.future.done():
            await session._error("Approval request was not found or has already completed.")
            return True
        approved = decision.casefold() == "approve"
        approval.future.set_result(approved)
        principal = self.principal_of(session)
        resolved = {"type": "tool.approval.resolved", "id": approval.task_id, "data": {
            "approval_id": approval_id, "task_id": approval.task_id, "thread_uuid": approval.thread_uuid,
            "decision": "approve" if approved else "deny", "by": principal.node_id}}
        for other in self._audience(approval.task_id, approval.thread_uuid):
            if other is not session:
                await _send(other, resolved["type"], resolved["data"], approval.task_id)
        return True

    # --- queries -------------------------------------------------------------------------------------------
    async def list_tasks(
        self, *, status: str | None = None, thread_uuid: str | None = None, limit: int = 100
    ) -> list[dict[str, Any]]:
        query = select(TaskRecord).where(TaskRecord.deleted_at.is_(None))
        if status:
            query = query.where(TaskRecord.status == status)
        if thread_uuid:
            query = query.where(TaskRecord.thread_uuid == thread_uuid)
        async with self.app.state.database.session() as db:
            rows = (await db.scalars(query.order_by(TaskRecord.created_at.desc()).limit(max(1, min(limit, 500))))).all()
        return [task_dict(row) for row in rows]


@dataclass(frozen=True, slots=True)
class _Submit:
    content: str
    thread_uuid: str | None
    workspace_uuid: str | None
    new_thread: bool
    client_msg_uuid: str
    executor: str | None
    model_id: str | None
    file_context: dict[str, Any] | None
    tools_enabled: bool
    forwarded: bool
    requester_node_id: str | None
    task_id: str | None


def _short(value: Any, name: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value or len(value) > 64:
        raise TaskError(f"{name} must be a short string.")
    return value


def _parse_submit(data: dict[str, Any]) -> _Submit:
    content = data.get("content")
    if not isinstance(content, str) or not content.strip() or len(content) > MAX_CONTENT_CHARS:
        raise TaskError("task.submit requires non-empty content.")
    thread_uuid, workspace_uuid = _short(data.get("thread_uuid"), "thread_uuid"), _short(
        data.get("workspace_uuid"), "workspace_uuid")
    forwarded = data.get("forwarded") is True
    if not forwarded and (thread_uuid is None) == (workspace_uuid is None):
        raise TaskError("task.submit requires exactly one of thread_uuid or workspace_uuid.")
    if forwarded and thread_uuid is None:
        raise TaskError("A forwarded task must name its thread.")
    client_msg_uuid = _short(data.get("client_msg_uuid"), "client_msg_uuid") or uuid4().hex
    model_id = data.get("model_id")
    if model_id is not None and (not isinstance(model_id, str) or len(model_id) > 200):
        raise TaskError("model_id must be a string.")
    file_context = data.get("file_context")
    try:
        _parse_file_context(file_context)
    except ValueError as error:
        raise TaskError(str(error)) from error
    return _Submit(
        content=content, thread_uuid=thread_uuid, workspace_uuid=workspace_uuid,
        new_thread=workspace_uuid is not None, client_msg_uuid=client_msg_uuid,
        executor=_short(data.get("executor"), "executor"), model_id=model_id,
        file_context=file_context if isinstance(file_context, dict) else None,
        tools_enabled=data.get("tools_enabled", True) is not False, forwarded=forwarded,
        requester_node_id=_short(data.get("requester_node_id"), "requester_node_id") if forwarded else None,
        task_id=_short(data.get("task_id"), "task_id") if forwarded else None)


def _is_hive_peer_session(session: Any) -> bool:
    link = getattr(getattr(session, "socket", None), "link", None)
    return link is not None and getattr(link, "role", None) == HIVE_PEER


async def _send(session: Any, frame_type: str, data: Any, identifier: str | None) -> None:
    with logged_suppress(Exception):
        await session._send(frame_type, data, identifier)
