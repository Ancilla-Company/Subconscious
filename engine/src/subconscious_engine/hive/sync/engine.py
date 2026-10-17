"""Storage side of hive sync: change log writer, signed apply path, snapshots.

Transport independent. ``record`` runs inside SQLAlchemy's ``before_flush`` so a
local op and the row change commit (or roll back) together. ``apply`` verifies
and merges ops from any origin idempotently, parking ops whose parent is missing.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any

from sqlalchemy import delete, event, func, inspect as sa_inspect, select, text, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import Session

from subconscious_engine.storage.database import Database
from subconscious_engine.storage.models import (
    ConversationThread,
    HiveMeta,
    Message,
    Network,
    SyncFieldClock,
    SyncLog,
    SyncPending,
    SyncState,
    TaskRecord,
    Workspace,
    new_uuid,
)

from ..authz import HIVE_PEER, role_for_kind
from ..identity import NodeIdentity
from .hlc import ClockSkewError, HybridClock, InvalidStamp, order_key, parse_stamp
from .ops import (
    SHARED_FIELDS,
    TASK_FIELDS,
    OpError,
    SyncOp,
    canonical_payload,
    sign_op,
    verify_op,
)
_LOG = logging.getLogger(__name__)

_LOGGER = logging.getLogger("uvicorn.error")
SCHEMA_VERSION = 1
DEFAULT_TOMBSTONE_DAYS = 30
TASK_STATES = frozenset(
    {"queued", "running", "waiting_approval", "done", "failed", "cancelled", "interrupted"}
)
TERMINAL_STATES = frozenset({"done", "failed", "cancelled", "interrupted"})
MESSAGE_ROLES = frozenset({"user", "assistant", "system", "tool"})
_TRACKED = (Workspace, ConversationThread, Message, TaskRecord)
_ENTITY_OF: dict[type, str] = {
    Workspace: "workspace", ConversationThread: "thread", Message: "message", TaskRecord: "task",
}
_MODEL_OF: dict[str, Any] = {
    "workspace": Workspace, "thread": ConversationThread, "message": Message, "task": TaskRecord,
}
_MISSING = object()
_DATETIME_FIELDS = frozenset({"created_at", "started_at", "finished_at", "deleted_at"})

OpListener = Callable[[list[SyncOp]], None]


def entity_uuid(obj: Any) -> str:
    return obj.task_id if isinstance(obj, TaskRecord) else obj.uuid


def to_naive_utc(value: datetime) -> datetime:
    if value.tzinfo is not None:
        value = value.astimezone(timezone.utc).replace(tzinfo=None)
    return value


def iso(value: datetime | None) -> str | None:
    if value is None:
        return None
    return to_naive_utc(value).replace(tzinfo=timezone.utc).isoformat()


def parse_datetime(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        return to_naive_utc(datetime.fromisoformat(value))
    except ValueError:
        _LOG.warning("hive.sync.engine.parse_datetime: handled ValueError; continuing with fallback", exc_info=True)
        return None


def hlc_datetime(hlc: str) -> datetime:
    milliseconds, _ = parse_stamp(hlc)
    return datetime.fromtimestamp(milliseconds / 1000, timezone.utc).replace(tzinfo=None)


@dataclass(slots=True)
class ApplyReport:
    accepted: list[SyncOp] = field(default_factory=list)
    duplicates: int = 0
    parked: int = 0
    rejected: list[tuple[SyncOp | None, str]] = field(default_factory=list)


class SyncEngine:
    def __init__(
        self,
        database: Database,
        *,
        clock: HybridClock | None = None,
        tombstone_days: int = DEFAULT_TOMBSTONE_DAYS,
        wall_clock: Callable[[], float] = time.time,
    ) -> None:
        self.database = database
        self.clock = clock or HybridClock()
        self.tombstone_days = tombstone_days
        self._wall = wall_clock
        self.identity: NodeIdentity | None = None
        self.hive_id: str | None = None
        self.blocked: str | None = None
        self.resolve_origin: Callable[[str], Any] = lambda _node_id: None
        self._listeners: list[OpListener] = []
        self._apply_lock = asyncio.Lock()
        session_class = database.session_class
        event.listen(session_class, "before_flush", self._before_flush)
        event.listen(session_class, "after_commit", self._after_commit)
        event.listen(session_class, "after_rollback", self._after_rollback)
        event.listen(session_class, "after_soft_rollback", self._after_rollback)

    # --- configuration ----------------------------------------------------
    @property
    def recording(self) -> bool:
        return self.identity is not None and self.blocked is None

    @property
    def local_node_id(self) -> str | None:
        return self.identity.node_id if self.identity else None

    def subscribe(self, listener: OpListener) -> Callable[[], None]:
        self._listeners.append(listener)

        def unsubscribe() -> None:
            if listener in self._listeners:
                self._listeners.remove(listener)

        return unsubscribe

    def _notify(self, ops: list[SyncOp]) -> None:
        for listener in list(self._listeners):
            try:
                listener(ops)
            except Exception:
                _LOGGER.warning("A sync listener failed.", exc_info=True)

    # --- local recording (SQLAlchemy hooks) -------------------------------
    def _before_flush(self, session: Session, _context: Any, _instances: Any) -> None:
        if session.info.get("sync_apply"):
            return
        new = [obj for obj in session.new if isinstance(obj, _TRACKED)]
        dirty = [obj for obj in session.dirty if isinstance(obj, _TRACKED) and session.is_modified(obj)]
        if not new and not dirty:
            return
        recording = self.recording
        new.sort(key=lambda obj: (to_naive_utc(obj.created_at) if obj.created_at else datetime.min))
        for obj in new:
            entity = _ENTITY_OF[type(obj)]
            # Column defaults only apply at INSERT time; the signed payload needs them now.
            if obj.created_at is None:
                obj.created_at = datetime.now(timezone.utc)
            if isinstance(obj, TaskRecord):
                obj.task_id = obj.task_id or new_uuid()
                obj.status = obj.status or "queued"
                obj.rev = obj.rev or 0
            hlc = self.clock.tick()
            obj.hlc = hlc
            if not recording:
                continue
            if obj.origin_node_id is None:
                obj.origin_node_id = self.local_node_id
            payload = self._create_payload(session, obj, entity)
            self._emit(session, entity, entity_uuid(obj), "create", hlc, payload)
            self._set_clocks(session, entity, entity_uuid(obj), _clock_fields(entity, payload), hlc)
        for obj in dirty:
            entity = _ENTITY_OF[type(obj)]
            deleted = _newly_deleted(obj)
            if isinstance(obj, Message):
                changed: dict[str, Any] = {}
            elif isinstance(obj, TaskRecord):
                changed = _changed_values(obj, TASK_FIELDS)
            else:
                changed = _changed_values(obj, SHARED_FIELDS[entity])
            if not changed and not deleted:
                continue
            hlc = self.clock.tick()
            obj.hlc = hlc
            if not recording:
                continue
            if obj.origin_node_id is None:
                obj.origin_node_id = self.local_node_id
            if deleted:
                payload = {"deleted_at": iso(obj.deleted_at)}
                self._emit(session, entity, entity_uuid(obj), "delete", hlc, payload)
                continue
            if isinstance(obj, TaskRecord):
                payload = self._create_payload(session, obj, entity)
                self._emit(session, entity, entity_uuid(obj), "update", hlc, payload)
                self._set_clocks(session, entity, entity_uuid(obj), ["_row"], hlc)
            else:
                payload = {key: value for key, value in changed.items()}
                self._emit(session, entity, entity_uuid(obj), "update", hlc, payload)
                self._set_clocks(session, entity, entity_uuid(obj), list(payload), hlc)

    def _create_payload(self, session: Session, obj: Any, entity: str) -> dict[str, Any]:
        if entity == "workspace":
            return {"name": obj.name, "description": obj.description, "created_at": iso(obj.created_at)}
        if entity == "thread":
            workspace = _loaded(session, Workspace, obj, "workspace", "workspace_id")
            return {
                "workspace_uuid": workspace.uuid if workspace is not None else None,
                "title": obj.title, "description": obj.description,
                "default_model_id": obj.default_model_id, "created_at": iso(obj.created_at),
            }
        if entity == "message":
            thread = _loaded(session, ConversationThread, obj, "thread", "thread_id")
            return {
                "thread_uuid": thread.uuid if thread is not None else None,
                "role": obj.role, "content": obj.content, "created_at": iso(obj.created_at),
            }
        payload: dict[str, Any] = {}
        for name in TASK_FIELDS:
            value = getattr(obj, name)
            payload[name] = iso(value) if name in _DATETIME_FIELDS else value
        return payload

    def _next_seq(self, session: Session, hlc: str) -> int:
        session.execute(
            text("UPDATE sync_state SET local_seq = local_seq + 1, last_hlc = :hlc WHERE id = 1"),
            {"hlc": hlc},
        )
        value = session.execute(text("SELECT local_seq FROM sync_state WHERE id = 1")).scalar()
        if value is None:  # databases created before the migration ran
            session.execute(text(
                "INSERT INTO sync_state (id, per_origin_applied, local_seq, last_hlc) "
                "VALUES (1, '{}', 1, :hlc)"), {"hlc": hlc})
            return 1
        return int(value)

    def _emit(
        self, session: Session, entity: str, uuid: str, op: str, hlc: str, payload: dict[str, Any]
    ) -> SyncOp:
        assert self.identity is not None
        seq = self._next_seq(session, hlc)
        signed = sign_op(self.identity, seq, entity, uuid, op, hlc, payload)
        session.add(SyncLog(
            origin_node_id=signed.origin, origin_seq=signed.seq, entity=entity, entity_uuid=uuid,
            op=op, hlc=hlc, payload=canonical_payload(payload), sig=signed.sig,
        ))
        session.info.setdefault("sync_new_ops", []).append(signed)
        return signed

    def _set_clocks(
        self, session: Session, entity: str, uuid: str, fields: Iterable[str], hlc: str
    ) -> None:
        for name in fields:
            session.execute(
                text(
                    "INSERT OR REPLACE INTO sync_field_clock (entity, entity_uuid, field, hlc, origin_node_id) "
                    "VALUES (:e, :u, :f, :h, :o)"
                ),
                {"e": entity, "u": uuid, "f": name, "h": hlc, "o": self.local_node_id or ""},
            )

    def _after_commit(self, session: Session) -> None:
        ops = session.info.pop("sync_new_ops", None)
        if ops:
            self._notify(list(ops))

    def _after_rollback(self, session: Session, *_: Any) -> None:
        session.info.pop("sync_new_ops", None)

    # --- state helpers ----------------------------------------------------
    async def _state(self, session: AsyncSession) -> SyncState:
        state = await session.get(SyncState, 1)
        if state is None:
            state = SyncState(id=1, per_origin_applied="{}", local_seq=0)
            session.add(state)
            await session.flush()
        return state

    async def version_vector(self) -> dict[str, int]:
        async with self.database.session() as session:
            return await self._vv(session)

    async def _vv(self, session: AsyncSession) -> dict[str, int]:
        state = await self._state(session)
        vv = {k: int(v) for k, v in json.loads(state.per_origin_applied or "{}").items()}
        node = state.node_id or self.local_node_id
        if node and state.local_seq:
            vv[node] = max(vv.get(node, 0), int(state.local_seq))
        return vv

    async def get_meta(self, key: str) -> str | None:
        async with self.database.session() as session:
            row = await session.get(HiveMeta, key)
            return row.value if row else None

    async def set_meta(self, key: str, value: str) -> None:
        async with self.database.session() as session:
            session.info["sync_apply"] = True
            row = await session.get(HiveMeta, key)
            if row is None:
                session.add(HiveMeta(key=key, value=value))
            else:
                row.value = value
            await session.commit()

    async def floor(self) -> dict[str, int]:
        raw = await self.get_meta("sync_floor")
        return {k: int(v) for k, v in json.loads(raw).items()} if raw else {}

    # --- identity / hive guard -------------------------------------------
    async def check_hive(self, hive_id: str) -> bool:
        """Bind to ``hive_id`` or refuse when this database belongs to another hive."""
        stored = await self.get_meta("hive_id")
        if stored is None:
            await self.set_meta("hive_id", hive_id)
        elif stored != hive_id:
            self.blocked = "hive_mismatch"
            self.hive_id = None
            return False
        if self.blocked == "hive_mismatch":
            self.blocked = None
        self.hive_id = hive_id
        return True

    async def attach_identity(self, identity: NodeIdentity) -> None:
        """Start recording as ``identity`` and adopt rows created before it existed."""
        async with self.database.session() as session:
            state = await self._state(session)
            if state.node_id and state.node_id != identity.node_id:
                self.blocked = "node_mismatch"
                self.identity = None
                return
            state.node_id = identity.node_id
            if state.last_hlc:
                self.clock = HybridClock(last=state.last_hlc)
            await session.commit()
        self.identity = identity
        await self._backfill()

    def detach_identity(self) -> None:
        self.identity = None

    async def _backfill(self) -> None:
        """Emit create ops (and tombstones) for rows that predate the identity."""
        assert self.identity is not None
        created: list[SyncOp] = []
        async with self.database.session() as session:
            session.info["sync_apply"] = True
            for entity in ("workspace", "thread", "message", "task"):
                model = _MODEL_OF[entity]
                rows = (await session.scalars(
                    select(model).where(model.origin_node_id.is_(None)).order_by(model.hlc, model.id)
                )).all()
                for row in rows:
                    hlc = row.hlc or self.clock.tick()
                    row.origin_node_id = self.identity.node_id
                    row.hlc = hlc
                    payload = await self._async_payload(session, row, entity)
                    if payload is None:
                        continue
                    created.append(await self._log_local(session, entity, entity_uuid(row), "create", hlc, payload))
                    if row.deleted_at is not None:
                        created.append(await self._log_local(
                            session, entity, entity_uuid(row), "delete", self.clock.tick(),
                            {"deleted_at": iso(row.deleted_at)}))
            await session.commit()
        if created:
            self._notify(created)

    async def _async_payload(self, session: AsyncSession, row: Any, entity: str) -> dict[str, Any] | None:
        if entity == "thread":
            workspace = await session.get(Workspace, row.workspace_id)
            if workspace is None:
                return None
            return {"workspace_uuid": workspace.uuid, "title": row.title, "description": row.description,
                    "default_model_id": row.default_model_id, "created_at": iso(row.created_at)}
        if entity == "message":
            thread = await session.get(ConversationThread, row.thread_id)
            if thread is None:
                return None
            return {"thread_uuid": thread.uuid, "role": row.role, "content": row.content,
                    "created_at": iso(row.created_at)}
        if entity == "workspace":
            return {"name": row.name, "description": row.description, "created_at": iso(row.created_at)}
        return {name: (iso(getattr(row, name)) if name in _DATETIME_FIELDS else getattr(row, name))
                for name in TASK_FIELDS}

    async def _log_local(
        self, session: AsyncSession, entity: str, uuid: str, op: str, hlc: str, payload: dict[str, Any]
    ) -> SyncOp:
        assert self.identity is not None
        state = await self._state(session)
        state.local_seq += 1
        state.last_hlc = hlc
        signed = sign_op(self.identity, state.local_seq, entity, uuid, op, hlc, payload)
        session.add(SyncLog(
            origin_node_id=signed.origin, origin_seq=signed.seq, entity=entity, entity_uuid=uuid,
            op=op, hlc=hlc, payload=canonical_payload(payload), sig=signed.sig))
        names = ["_row"] if entity == "task" else _clock_fields(entity, payload)
        for name in names:
            await session.merge(SyncFieldClock(
                entity=entity, entity_uuid=uuid, field=name, hlc=hlc, origin_node_id=signed.origin))
        return signed

    # --- reading ops ------------------------------------------------------
    @staticmethod
    def _row_to_op(row: SyncLog) -> SyncOp:
        return SyncOp(row.origin_node_id, row.origin_seq, row.entity, row.entity_uuid, row.op,
                      row.hlc, json.loads(row.payload), row.sig)

    async def read_ops(
        self,
        after: dict[str, int],
        *,
        max_ops: int = 200,
        max_bytes: int = 256 * 1024,
        origin_ok: Callable[[str], bool] | None = None,
    ) -> list[SyncOp]:
        """Next bounded batch of logged ops beyond the ``after`` vector (all origins)."""
        out: list[SyncOp] = []
        size = 0
        async with self.database.session() as session:
            origins = (await session.scalars(
                select(SyncLog.origin_node_id).distinct().order_by(SyncLog.origin_node_id))).all()
            for origin in origins:
                if origin_ok is not None and not origin_ok(origin):
                    continue
                rows = (await session.scalars(
                    select(SyncLog).where(SyncLog.origin_node_id == origin,
                                          SyncLog.origin_seq > after.get(origin, 0))
                    .order_by(SyncLog.origin_seq).limit(max_ops - len(out)))).all()
                for row in rows:
                    op = self._row_to_op(row)
                    length = len(json.dumps(op.to_wire(), ensure_ascii=False))
                    if out and size + length > max_bytes:
                        return out
                    out.append(op)
                    size += length
                if len(out) >= max_ops:
                    break
        return out

    async def needs_snapshot(self, remote_vv: dict[str, int]) -> bool:
        floor = await self.floor()
        return any(remote_vv.get(origin, 0) < seq for origin, seq in floor.items())

    async def export_live(self) -> dict[str, list[str]]:
        live: dict[str, list[str]] = {}
        async with self.database.session() as session:
            for entity, model in _MODEL_OF.items():
                column = model.task_id if entity == "task" else model.uuid
                live[entity] = list((await session.scalars(
                    select(column).where(model.deleted_at.is_(None)))).all())
        return live

    # --- apply ------------------------------------------------------------
    def _check_origin(self, op: SyncOp) -> str | None:
        """Return a rejection reason, or ``None`` when ``op`` is authentic."""
        node = self.resolve_origin(op.origin)
        if node is None:
            return "origin_not_active"
        if role_for_kind(getattr(node, "kind", "")) != HIVE_PEER:
            return "origin_not_engine"
        if not verify_op(op, node.public_key):
            return "bad_signature"
        return None

    async def apply(self, ops: Iterable[SyncOp]) -> ApplyReport:
        report = ApplyReport()
        if self.blocked is not None:
            report.rejected.extend((op, self.blocked) for op in ops)
            return report
        async with self._apply_lock:
            async with self.database.session() as session:
                session.info["sync_apply"] = True
                try:
                    for op in ops:
                        await self._apply_one(session, op, report)
                    await session.commit()
                except Exception:
                    await session.rollback()
                    raise
        if report.accepted:
            self._notify_remote(report.accepted)
        return report

    def _notify_remote(self, ops: list[SyncOp]) -> None:
        for listener in list(getattr(self, "_remote_listeners", [])):
            try:
                listener(ops)
            except Exception:
                _LOGGER.warning("A sync listener failed.", exc_info=True)

    def subscribe_applied(self, listener: OpListener) -> Callable[[], None]:
        """Listen for ops accepted from remote nodes (used for live UI refresh)."""
        listeners = self.__dict__.setdefault("_remote_listeners", [])
        listeners.append(listener)
        return lambda: listeners.remove(listener) if listener in listeners else None

    async def _apply_one(self, session: AsyncSession, op: SyncOp, report: ApplyReport) -> None:
        if op.origin == self.local_node_id:
            if await session.get(SyncLog, (op.origin, op.seq)) is None:
                report.rejected.append((op, "forged_origin"))  # we never issued it
            else:
                report.duplicates += 1
            return
        if await session.get(SyncLog, (op.origin, op.seq)) is not None:
            report.duplicates += 1
            return
        reason = self._check_origin(op)
        if reason is not None:
            report.rejected.append((op, reason))
            return
        try:
            self.clock.observe(op.hlc)
        except (ClockSkewError, InvalidStamp):
            _LOG.warning("hive.sync.engine.SyncEngine._apply_one: handled (ClockSkewError, InvalidStamp); continuing with fallback", exc_info=True)
            report.rejected.append((op, "clock_skew"))
            return
        session.add(SyncLog(
            origin_node_id=op.origin, origin_seq=op.seq, entity=op.entity, entity_uuid=op.uuid,
            op=op.op, hlc=op.hlc, payload=canonical_payload(op.payload), sig=op.sig))
        await session.flush()
        try:
            missing = await self._apply_entity(session, op)
        except OpError as error:
            _LOG.warning("hive.sync.engine.SyncEngine._apply_one: handled OpError; continuing with fallback", exc_info=True)
            report.rejected.append((op, str(error)))
            await self._advance(session, op.origin)
            return
        if missing is not None:
            session.add(SyncPending(
                origin_node_id=op.origin, origin_seq=op.seq, missing_entity=missing[0],
                missing_uuid=missing[1], op=json.dumps(op.to_wire())))
            report.parked += 1
        else:
            await self._release_pending(session, op, report)
        report.accepted.append(op)
        await self._advance(session, op.origin)

    async def _advance(self, session: AsyncSession, origin: str) -> None:
        state = await self._state(session)
        vv = json.loads(state.per_origin_applied or "{}")
        applied = int(vv.get(origin, 0))
        while await session.get(SyncLog, (origin, applied + 1)) is not None:
            applied += 1
        vv[origin] = applied
        state.per_origin_applied = json.dumps(vv, sort_keys=True)

    async def _release_pending(self, session: AsyncSession, op: SyncOp, report: ApplyReport) -> None:
        if op.op == "delete":
            return
        rows = (await session.scalars(
            select(SyncPending).where(SyncPending.missing_uuid == op.uuid,
                                      SyncPending.missing_entity == op.entity)
            .order_by(SyncPending.origin_node_id, SyncPending.origin_seq))).all()
        for row in rows:
            parked = SyncOp.from_wire(json.loads(row.op))
            await session.delete(row)
            await session.flush()
            missing = await self._apply_entity(session, parked)
            if missing is not None:
                session.add(SyncPending(
                    origin_node_id=parked.origin, origin_seq=parked.seq, missing_entity=missing[0],
                    missing_uuid=missing[1], op=row.op))
            else:
                await self._release_pending(session, parked, report)

    async def _apply_entity(self, session: AsyncSession, op: SyncOp) -> tuple[str, str] | None:
        """Merge one verified op. Returns ``(entity, uuid)`` of a missing parent."""
        if op.entity == "workspace":
            return await self._apply_workspace(session, op)
        if op.entity == "thread":
            return await self._apply_thread(session, op)
        if op.entity == "message":
            return await self._apply_message(session, op)
        return await self._apply_task(session, op)

    # --- field level merge -------------------------------------------------
    async def _merge_fields(
        self, session: AsyncSession, op: SyncOp, row: Any, names: Iterable[str]
    ) -> None:
        for name in names:
            if name not in op.payload:
                continue
            clock = await session.get(SyncFieldClock, (op.entity, op.uuid, name))
            if clock is not None and order_key(op.hlc, op.origin) <= order_key(clock.hlc, clock.origin_node_id):
                continue
            value = op.payload[name]
            if value is not None and not isinstance(value, str):
                raise OpError(f"Field {name} must be text.")
            setattr(row, name, value)
            if clock is None:
                session.add(SyncFieldClock(entity=op.entity, entity_uuid=op.uuid, field=name,
                                           hlc=op.hlc, origin_node_id=op.origin))
            else:
                clock.hlc, clock.origin_node_id = op.hlc, op.origin
        if row.hlc is None or order_key(op.hlc, op.origin) > order_key(row.hlc, row.origin_node_id):
            row.hlc = op.hlc
        row.updated_at = max(to_naive_utc(row.updated_at), hlc_datetime(op.hlc)) if row.updated_at else hlc_datetime(op.hlc)

    @staticmethod
    async def _find(session: AsyncSession, model: Any, uuid: str) -> Any:
        column = model.task_id if model is TaskRecord else model.uuid
        return await session.scalar(select(model).where(column == uuid))

    async def _apply_workspace(self, session: AsyncSession, op: SyncOp) -> tuple[str, str] | None:
        row = await self._find(session, Workspace, op.uuid)
        if op.op == "delete":
            if row is None:
                return ("workspace", op.uuid)
            await self._tombstone_workspace(session, row, op)
            return None
        if row is None:
            if op.op != "create" or not isinstance(op.payload.get("name"), str):
                return ("workspace", op.uuid)
            network = await session.scalar(select(Network).order_by(Network.id))
            if network is None:
                network = Network(uuid=new_uuid(), name="default", description="Default network")
                session.add(network)
                await session.flush()
            created = parse_datetime(op.payload.get("created_at")) or hlc_datetime(op.hlc)
            row = Workspace(uuid=op.uuid, name="", network_id=network.id, created_at=created,
                            updated_at=created, origin_node_id=op.origin, hlc=op.hlc)
            session.add(row)
            await session.flush()
        await self._merge_fields(session, op, row, SHARED_FIELDS["workspace"])
        return None

    async def _tombstone_workspace(self, session: AsyncSession, row: Workspace, op: SyncOp) -> None:
        stamp = parse_datetime(op.payload.get("deleted_at")) or hlc_datetime(op.hlc)
        if row.deleted_at is None:
            row.deleted_at = stamp
        await session.execute(
            update(ConversationThread)
            .where(ConversationThread.workspace_id == row.id, ConversationThread.deleted_at.is_(None))
            .values(deleted_at=stamp))

    async def _apply_thread(self, session: AsyncSession, op: SyncOp) -> tuple[str, str] | None:
        row = await self._find(session, ConversationThread, op.uuid)
        if op.op == "delete":
            if row is None:
                return ("thread", op.uuid)
            if row.deleted_at is None:
                row.deleted_at = parse_datetime(op.payload.get("deleted_at")) or hlc_datetime(op.hlc)
            return None
        if row is None:
            if op.op != "create":
                return ("thread", op.uuid)
            parent_uuid = op.payload.get("workspace_uuid")
            if not isinstance(parent_uuid, str):
                raise OpError("Thread create needs workspace_uuid.")
            workspace = await self._find(session, Workspace, parent_uuid)
            if workspace is None:
                return ("workspace", parent_uuid)
            created = parse_datetime(op.payload.get("created_at")) or hlc_datetime(op.hlc)
            row = ConversationThread(
                uuid=op.uuid, workspace_id=workspace.id, created_at=created, updated_at=created,
                origin_node_id=op.origin, hlc=op.hlc, deleted_at=workspace.deleted_at)
            session.add(row)
            await session.flush()
        await self._merge_fields(session, op, row, SHARED_FIELDS["thread"])
        return None

    async def _apply_message(self, session: AsyncSession, op: SyncOp) -> tuple[str, str] | None:
        row = await self._find(session, Message, op.uuid)
        if op.op == "delete":
            if row is None:
                return ("message", op.uuid)
            if row.deleted_at is None:
                row.deleted_at = parse_datetime(op.payload.get("deleted_at")) or hlc_datetime(op.hlc)
            return None
        if row is not None or op.op != "create":
            return None  # messages are insert-once and immutable
        parent_uuid = op.payload.get("thread_uuid")
        role, content = op.payload.get("role"), op.payload.get("content")
        if not isinstance(parent_uuid, str) or role not in MESSAGE_ROLES or not isinstance(content, str):
            raise OpError("Malformed message.")
        thread = await self._find(session, ConversationThread, parent_uuid)
        if thread is None:
            return ("thread", parent_uuid)
        created = parse_datetime(op.payload.get("created_at")) or hlc_datetime(op.hlc)
        session.add(Message(
            uuid=op.uuid, thread_id=thread.id, role=role, content=content, created_at=created,
            origin_node_id=op.origin, hlc=op.hlc, deleted_at=thread.deleted_at))
        if thread.updated_at is None or to_naive_utc(thread.updated_at) < created:
            thread.updated_at = created
        await session.flush()
        return None

    async def _apply_task(self, session: AsyncSession, op: SyncOp) -> tuple[str, str] | None:
        row = await self._find(session, TaskRecord, op.uuid)
        payload = op.payload
        if op.op == "delete":
            if row is None:
                return ("task", op.uuid)
            if row.deleted_at is None:
                row.deleted_at = parse_datetime(payload.get("deleted_at")) or hlc_datetime(op.hlc)
            return None
        if row is None and op.op != "create":
            return ("task", op.uuid)  # only the creating op may introduce a task
        status = payload.get("status")
        if status not in TASK_STATES:
            raise OpError("Unknown task status.")
        for required in ("thread_uuid", "executor_node_id", "requester_node_id"):
            if not isinstance(payload.get(required), str) or not payload[required]:
                raise OpError("Malformed task.")
        rev = payload.get("rev")
        if not isinstance(rev, int) or isinstance(rev, bool) or rev < 0:
            raise OpError("Malformed task revision.")
        if row is None:
            row = TaskRecord(task_id=op.uuid, origin_node_id=op.origin, hlc=op.hlc,
                             thread_uuid=payload["thread_uuid"], executor_node_id=payload["executor_node_id"],
                             requester_node_id=payload["requester_node_id"], status="queued", rev=-1)
            session.add(row)
            await session.flush()
        elif op.op != "create":
            # After creation only the executor (and the creating node, for expiry) writes.
            if op.origin not in {row.executor_node_id, row.origin_node_id}:
                raise OpError("Task written by a node that is neither executor nor creator.")
        clock = await session.get(SyncFieldClock, ("task", op.uuid, "_row"))
        incoming = (status in TERMINAL_STATES, rev, op.hlc, op.origin)
        if clock is not None and incoming <= (row.status in TERMINAL_STATES, row.rev, clock.hlc, clock.origin_node_id):
            return None
        for name in TASK_FIELDS:
            if name not in payload or name in {"executor_node_id", "requester_node_id", "thread_uuid"} and row.rev >= 0:
                continue
            value = parse_datetime(payload[name]) if name in _DATETIME_FIELDS else payload[name]
            if name in _DATETIME_FIELDS and payload[name] is not None and value is None:
                raise OpError("Malformed task time.")
            if name == "created_at" and value is None:
                continue
            setattr(row, name, value)
        if row.status != "queued":
            row.payload = None  # the request body is only needed until the executor takes over
        if clock is None:
            session.add(SyncFieldClock(entity="task", entity_uuid=op.uuid, field="_row", hlc=op.hlc,
                                       origin_node_id=op.origin))
        else:
            clock.hlc, clock.origin_node_id = op.hlc, op.origin
        row.hlc = op.hlc
        return None

    # --- snapshot application ---------------------------------------------
    async def finish_snapshot(self, vv: dict[str, int], live: dict[str, list[str]]) -> int:
        """After a snapshot's ops are applied: tombstone entities the sender no longer holds.

        An entity is only removed when its creating op is covered by the snapshot's
        version vector (so the sender had seen it) and the sender lists it as absent.
        """
        removed = 0
        now = to_naive_utc(datetime.now(timezone.utc))
        async with self.database.session() as session:
            session.info["sync_apply"] = True
            for entity, model in _MODEL_OF.items():
                keep = set(live.get(entity, []))
                column = model.task_id if entity == "task" else model.uuid
                rows = (await session.scalars(select(model).where(model.deleted_at.is_(None)))).all()
                for row in rows:
                    uuid = getattr(row, column.key)
                    if uuid in keep:
                        continue
                    created = await session.scalar(
                        select(SyncLog).where(SyncLog.entity == entity, SyncLog.entity_uuid == uuid,
                                              SyncLog.op == "create"))
                    if created is None or created.origin_seq > vv.get(created.origin_node_id, 0):
                        continue
                    row.deleted_at = now
                    removed += 1
            state = await self._state(session)
            applied = json.loads(state.per_origin_applied or "{}")
            for origin, seq in vv.items():
                if origin != self.local_node_id and seq > int(applied.get(origin, 0)):
                    applied[origin] = seq
            state.per_origin_applied = json.dumps(applied, sort_keys=True)
            await session.commit()
        return removed

    # --- retention --------------------------------------------------------
    async def purge_tombstones(self, now: float | None = None) -> int:
        """Hard-delete tombstones past retention and record the log floor."""
        cutoff = datetime.fromtimestamp((now or self._wall()) - self.tombstone_days * 86400,
                                        timezone.utc).replace(tzinfo=None)
        purged = 0
        floor = await self.floor()
        async with self.database.session() as session:
            session.info["sync_apply"] = True
            doomed: dict[str, set[str]] = {"workspace": set(), "thread": set(), "message": set(), "task": set()}
            for entity, model in _MODEL_OF.items():
                column = model.task_id if entity == "task" else model.uuid
                doomed[entity].update((await session.scalars(
                    select(column).where(model.deleted_at.is_not(None), model.deleted_at < cutoff))).all())
            # children of purged parents go with them
            if doomed["workspace"]:
                ids = (await session.scalars(select(Workspace.id).where(Workspace.uuid.in_(doomed["workspace"])))).all()
                doomed["thread"].update((await session.scalars(
                    select(ConversationThread.uuid).where(ConversationThread.workspace_id.in_(ids)))).all())
            if doomed["thread"]:
                ids = (await session.scalars(select(ConversationThread.id).where(
                    ConversationThread.uuid.in_(doomed["thread"])))).all()
                doomed["message"].update((await session.scalars(
                    select(Message.uuid).where(Message.thread_id.in_(ids)))).all())
                doomed["task"].update((await session.scalars(
                    select(TaskRecord.task_id).where(TaskRecord.thread_uuid.in_(doomed["thread"])))).all())
            for entity, uuids in doomed.items():
                if not uuids:
                    continue
                model = _MODEL_OF[entity]
                for chunk in _chunks(sorted(uuids), 400):
                    rows = (await session.execute(select(SyncLog.origin_node_id, func.max(SyncLog.origin_seq))
                            .where(SyncLog.entity == entity, SyncLog.entity_uuid.in_(chunk))
                            .group_by(SyncLog.origin_node_id))).all()
                    for origin, top in rows:
                        floor[origin] = max(floor.get(origin, 0), int(top))
                    await session.execute(delete(SyncLog).where(SyncLog.entity == entity, SyncLog.entity_uuid.in_(chunk)))
                    await session.execute(delete(SyncFieldClock).where(
                        SyncFieldClock.entity == entity, SyncFieldClock.entity_uuid.in_(chunk)))
                    await session.execute(delete(SyncPending).where(
                        SyncPending.missing_entity == entity, SyncPending.missing_uuid.in_(chunk)))
                    column = model.task_id if entity == "task" else model.uuid
                    await session.execute(delete(model).where(column.in_(chunk)))
                purged += len(uuids)
            await session.commit()
        if purged:
            await self.set_meta("sync_floor", json.dumps(floor, sort_keys=True))
        return purged

    # --- reset / status ---------------------------------------------------
    async def reset_local(self) -> None:
        """Forget all hive bookkeeping while keeping the user's own threads and files."""
        async with self.database.session() as session:
            session.info["sync_apply"] = True
            for model in (SyncLog, SyncPending, SyncFieldClock, TaskRecord, HiveMeta):
                await session.execute(delete(model))
            for model in (Message, ConversationThread, Workspace):
                await session.execute(delete(model).where(model.deleted_at.is_not(None)))
                await session.execute(update(model).values(origin_node_id=None))
            await session.execute(update(SyncState).values(
                hive_id=None, node_id=None, last_hlc=None, per_origin_applied="{}", local_seq=0))
            await session.commit()
        self.hive_id = None
        self.blocked = None

    async def status(self) -> dict[str, Any]:
        async with self.database.session() as session:
            vv = await self._vv(session)
            pending = await session.scalar(select(func.count()).select_from(SyncPending)) or 0
            logged = await session.scalar(select(func.count()).select_from(SyncLog)) or 0
        return {
            "state": self.blocked or ("recording" if self.recording else "idle"),
            "hive_id": self.hive_id,
            "node_id": self.local_node_id,
            "schema_version": SCHEMA_VERSION,
            "version_vector": vv,
            "pending_ops": int(pending),
            "logged_ops": int(logged),
            "clock": self.clock.last,
        }


# --- module helpers -----------------------------------------------------------


def _chunks(items: list[str], size: int) -> Iterable[list[str]]:
    for start in range(0, len(items), size):
        yield items[start:start + size]


def _clock_fields(entity: str, payload: dict[str, Any]) -> list[str]:
    if entity == "task":
        return ["_row"]
    return [name for name in SHARED_FIELDS[entity] if name in payload]


def _loaded(session: Session, model: Any, obj: Any, relation: str, key: str) -> Any:
    related = obj.__dict__.get(relation)
    if related is not None:
        return related
    identifier = getattr(obj, key)
    return session.get(model, identifier) if identifier is not None else None


def _changed_values(obj: Any, names: Iterable[str]) -> dict[str, Any]:
    state = sa_inspect(obj)
    out: dict[str, Any] = {}
    for name in names:
        history = state.attrs[name].history
        if not history.added:
            continue
        new = history.added[0]
        old = history.deleted[0] if history.deleted else _MISSING
        if new != old:
            out[name] = new
    return out


def _newly_deleted(obj: Any) -> bool:
    history = sa_inspect(obj).attrs.deleted_at.history
    if not history.added or history.added[0] is None:
        return False
    return not history.deleted or history.deleted[0] is None


def default_retention() -> timedelta:
    return timedelta(days=DEFAULT_TOMBSTONE_DAYS)
