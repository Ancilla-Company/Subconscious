"""Numbered, idempotent schema migrations for the engine database.

Fresh databases are built by ``create_all`` and stamped as current. Existing
user databases are backed up (SQLite online backup) before any pending
migration runs. Every migration inspects the live schema first, so re-running
one (for example after an interrupted upgrade) is safe.
"""

from __future__ import annotations

import json
import logging
import sqlite3
from collections.abc import Callable
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from sqlalchemy import Connection, inspect, text

from .models import Base

_LOGGER = logging.getLogger("uvicorn.error")
MIGRATIONS_TABLE = "schema_migrations"
_ANCHOR_TABLE = "threads"  # present in every database the engine has ever created

Migration = Callable[[Connection], None]


def _columns(connection: Connection, table: str) -> set[str]:
    return {row[1] for row in connection.execute(text(f'PRAGMA table_info("{table}")'))}


def _add_column(connection: Connection, table: str, column: str, ddl: str) -> None:
    if column not in _columns(connection, table):
        connection.execute(text(f'ALTER TABLE "{table}" ADD COLUMN {column} {ddl}'))


def hlc_from_datetime(value: object, counter: int = 0) -> str:
    """Sortable clock text from a stored timestamp (used for pre-sync rows)."""
    moment: datetime | None = None
    if isinstance(value, datetime):
        moment = value
    elif isinstance(value, str):
        try:
            moment = datetime.fromisoformat(value)
        except ValueError:
            moment = None
    if moment is None:
        moment = datetime.fromtimestamp(0, timezone.utc)
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return f"{int(moment.timestamp() * 1000):013d}.{counter:05d}"


def _migration_1_hive_sync(connection: Connection) -> None:
    for table in ("workspaces", "threads", "messages"):
        _add_column(connection, table, "origin_node_id", "TEXT")
        _add_column(connection, table, "hlc", "TEXT")
        _add_column(connection, table, "deleted_at", "DATETIME")
    for table in ("notes", "contacts", "workspace_memory", "todo_items"):
        _add_column(connection, table, "uuid", "TEXT")
        rows = connection.execute(text(f'SELECT id FROM "{table}" WHERE uuid IS NULL OR uuid = \'\'')).all()
        if rows:
            connection.execute(
                text(f'UPDATE "{table}" SET uuid = :uuid WHERE id = :id'),
                [{"uuid": str(uuid4()), "id": row[0]} for row in rows],
            )
        connection.execute(text(f'CREATE UNIQUE INDEX IF NOT EXISTS ix_{table}_uuid ON "{table}" (uuid)'))
    for name in ("sync_log", "sync_state", "sync_pending", "sync_field_clock", "hive_meta", "tasks"):
        Base.metadata.tables[name].create(connection, checkfirst=True)
    # Existing rows: origin stays NULL until a node identity exists; the clock is
    # derived from the row's own timestamps so ordering matches what users saw.
    for table, column in (("workspaces", "updated_at"), ("threads", "updated_at"), ("messages", "created_at")):
        rows = connection.execute(
            text(f'SELECT id, {column} FROM "{table}" WHERE hlc IS NULL')
        ).all()
        if rows:
            connection.execute(
                text(f'UPDATE "{table}" SET hlc = :hlc WHERE id = :id'),
                [{"hlc": hlc_from_datetime(row[1]), "id": row[0]} for row in rows],
            )
    connection.execute(
        text(
            "INSERT OR IGNORE INTO sync_state (id, per_origin_applied, local_seq) "
            "VALUES (1, :empty, 0)"
        ),
        {"empty": json.dumps({})},
    )


def _migration_2_remote_tool_audit(connection: Connection) -> None:
    """Local-only audit table for remote tool calls (webrtc.md section 8); never synced."""
    Base.metadata.tables["remote_tool_audit"].create(connection, checkfirst=True)
    # ``checkfirst`` skips the after_create hook for a table that already exists, so make
    # sure the append-only triggers are there either way.
    for verb in ("UPDATE", "DELETE"):
        connection.execute(text(
            f"CREATE TRIGGER IF NOT EXISTS remote_tool_audit_no_{verb.lower()} "
            f"BEFORE {verb} ON remote_tool_audit "
            "BEGIN SELECT RAISE(ABORT, 'remote_tool_audit is append-only'); END"
        ))


MIGRATIONS: tuple[tuple[int, str, Migration], ...] = (
    (1, "hive_sync", _migration_1_hive_sync),
    (2, "remote_tool_audit", _migration_2_remote_tool_audit),
)
LATEST_VERSION = MIGRATIONS[-1][0]


def _ensure_table(connection: Connection) -> None:
    connection.execute(
        text(
            f"CREATE TABLE IF NOT EXISTS {MIGRATIONS_TABLE} ("
            "version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TEXT NOT NULL)"
        )
    )


def applied_versions(connection: Connection) -> set[int]:
    if MIGRATIONS_TABLE not in inspect(connection).get_table_names():
        return set()
    return {row[0] for row in connection.execute(text(f"SELECT version FROM {MIGRATIONS_TABLE}"))}


def _record(connection: Connection, version: int, name: str) -> None:
    connection.execute(
        text(
            f"INSERT OR IGNORE INTO {MIGRATIONS_TABLE} (version, name, applied_at) "
            "VALUES (:version, :name, :at)"
        ),
        {"version": version, "name": name, "at": datetime.now(timezone.utc).isoformat()},
    )


def is_fresh(connection: Connection) -> bool:
    return _ANCHOR_TABLE not in inspect(connection).get_table_names()


def pending(connection: Connection) -> list[tuple[int, str, Migration]]:
    done = applied_versions(connection)
    return [item for item in MIGRATIONS if item[0] not in done]


def stamp_fresh(connection: Connection) -> None:
    """Create the full current schema and mark every migration as applied."""
    Base.metadata.create_all(connection)
    _ensure_table(connection)
    connection.execute(
        text("INSERT OR IGNORE INTO sync_state (id, per_origin_applied, local_seq) VALUES (1, '{}', 0)")
    )
    for version, name, _ in MIGRATIONS:
        _record(connection, version, name)


def migrate(connection: Connection) -> list[int]:
    """Apply pending migrations in order; returns the versions applied."""
    _ensure_table(connection)
    applied: list[int] = []
    for version, name, step in pending(connection):
        step(connection)
        _record(connection, version, name)
        applied.append(version)
    Base.metadata.create_all(connection)  # any table a future model adds
    return applied


def backup_database(path: Path) -> Path | None:
    """Copy ``path`` next to itself with SQLite's online backup API."""
    if not path.exists() or path.stat().st_size == 0:
        return None
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%f")
    target = path.with_name(f"{path.name}.bak-{stamp}")
    source = sqlite3.connect(str(path))
    try:
        destination = sqlite3.connect(str(target))
        try:
            source.backup(destination)
        finally:
            destination.close()
    finally:
        source.close()
    _LOGGER.info("Backed up the engine database before migrating.")
    return target
