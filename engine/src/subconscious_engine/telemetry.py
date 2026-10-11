"""Pydantic execution telemetry models and an async SQLite event store."""

from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum
import json
from pathlib import Path
from typing import Any, Literal

import aiosqlite
from pydantic import BaseModel, Field


class RunStatus(str, Enum):
    SUCCESS = "SUCCESS"
    FAILED = "FAILED"
    ABORTED = "ABORTED"


class NodeTrace(BaseModel):
    node_id: str
    prompt_tokens: int = Field(default=0, ge=0)
    completion_tokens: int = Field(default=0, ge=0)
    latency_ms: float = Field(default=0, ge=0)
    system_prompt_snapshot: str = ""


class ToolInvocation(BaseModel):
    tool_name: str
    arguments: dict[str, Any] = Field(default_factory=dict)
    execution_status: Literal["SUCCESS", "FAILED", "DENIED", "ABORTED"] = "SUCCESS"
    error_stack_trace: str | None = None
    retry_count: int = Field(default=0, ge=0)


class AssertionResult(BaseModel):
    name: str
    exit_code: int | None = None
    outcome: str | None = None
    user_feedback: Literal["positive", "negative"] | None = None
    human_override_diff: str | None = None


class FrictionSignal(BaseModel):
    kind: Literal["interrupt", "rejected_tool", "modified_payload", "other"]
    details: str | None = None
    timestamp: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


class ExecutionTelemetry(BaseModel):
    run_id: str
    graph_id: str
    timestamp: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    total_duration_ms: float = Field(default=0, ge=0)
    final_status: RunStatus
    error: str | None = None
    node_traces: list[NodeTrace] = Field(default_factory=list)
    tool_invocations: list[ToolInvocation] = Field(default_factory=list)
    assertions: list[AssertionResult] = Field(default_factory=list)
    friction_signals: list[FrictionSignal] = Field(default_factory=list)


_SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS runs (
  run_id TEXT PRIMARY KEY, graph_id TEXT NOT NULL, timestamp TEXT NOT NULL,
  total_duration_ms REAL NOT NULL, final_status TEXT NOT NULL, error TEXT,
  reflection_claimed_at TEXT, reflected_at TEXT
);
CREATE TABLE IF NOT EXISTS node_traces (
  id INTEGER PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  node_id TEXT NOT NULL, prompt_tokens INTEGER NOT NULL, completion_tokens INTEGER NOT NULL,
  latency_ms REAL NOT NULL, system_prompt_snapshot TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tool_invocations (
  id INTEGER PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  tool_name TEXT NOT NULL, arguments_json TEXT NOT NULL, execution_status TEXT NOT NULL,
  error_stack_trace TEXT, retry_count INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS assertion_results (
  id INTEGER PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  name TEXT NOT NULL, exit_code INTEGER, outcome TEXT, user_feedback TEXT,
  human_override_diff TEXT
);
CREATE TABLE IF NOT EXISTS friction_signals (
  id INTEGER PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  kind TEXT NOT NULL, details TEXT, timestamp TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_runs_status ON runs(final_status, reflected_at);
CREATE INDEX IF NOT EXISTS ix_tools_retry ON tool_invocations(run_id, retry_count);
CREATE INDEX IF NOT EXISTS ix_friction_run ON friction_signals(run_id);
"""


class TelemetryStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)

    async def _connect(self) -> aiosqlite.Connection:
        connection = await aiosqlite.connect(self.path)
        await connection.execute("PRAGMA foreign_keys=ON")
        await connection.execute("PRAGMA busy_timeout=5000")
        return connection

    async def initialize(self) -> None:
        connection = await self._connect()
        try:
            await connection.executescript(_SCHEMA)
            await connection.commit()
        finally:
            await connection.close()

    async def close(self) -> None:
        """Connections are operation-scoped; present for lifecycle symmetry."""

    async def record(self, run: ExecutionTelemetry) -> None:
        connection = await self._connect()
        try:
            await connection.execute("BEGIN")
            await connection.execute(
                "INSERT INTO runs(run_id,graph_id,timestamp,total_duration_ms,final_status,error) VALUES(?,?,?,?,?,?)",
                (run.run_id, run.graph_id, run.timestamp.isoformat(), run.total_duration_ms,
                 run.final_status.value, run.error),
            )
            await connection.executemany(
                "INSERT INTO node_traces(run_id,node_id,prompt_tokens,completion_tokens,latency_ms,system_prompt_snapshot) VALUES(?,?,?,?,?,?)",
                [(run.run_id, item.node_id, item.prompt_tokens, item.completion_tokens,
                  item.latency_ms, item.system_prompt_snapshot) for item in run.node_traces],
            )
            await connection.executemany(
                "INSERT INTO tool_invocations(run_id,tool_name,arguments_json,execution_status,error_stack_trace,retry_count) VALUES(?,?,?,?,?,?)",
                [(run.run_id, item.tool_name, json.dumps(item.arguments, default=str),
                  item.execution_status, item.error_stack_trace, item.retry_count)
                 for item in run.tool_invocations],
            )
            await connection.executemany(
                "INSERT INTO assertion_results(run_id,name,exit_code,outcome,user_feedback,human_override_diff) VALUES(?,?,?,?,?,?)",
                [(run.run_id, item.name, item.exit_code, item.outcome,
                  item.user_feedback, item.human_override_diff) for item in run.assertions],
            )
            await connection.executemany(
                "INSERT INTO friction_signals(run_id,kind,details,timestamp) VALUES(?,?,?,?)",
                [(run.run_id, item.kind, item.details, item.timestamp.isoformat())
                 for item in run.friction_signals],
            )
            await connection.commit()
        except BaseException:
            await connection.rollback()
            raise
        finally:
            await connection.close()

    async def add_friction(self, run_id: str, signal: FrictionSignal) -> None:
        connection = await self._connect()
        try:
            await connection.execute(
                "INSERT INTO friction_signals(run_id,kind,details,timestamp) VALUES(?,?,?,?)",
                (run_id, signal.kind, signal.details, signal.timestamp.isoformat()),
            )
            await connection.commit()
        finally:
            await connection.close()

    async def needs_reflection(self, run_id: str) -> bool:
        connection = await self._connect()
        try:
            cursor = await connection.execute(
                """SELECT EXISTS(
                  SELECT 1 FROM runs r WHERE r.run_id=? AND (
                    r.final_status='FAILED'
                    OR EXISTS(SELECT 1 FROM tool_invocations t WHERE t.run_id=r.run_id AND t.retry_count>2)
                    OR EXISTS(SELECT 1 FROM friction_signals f WHERE f.run_id=r.run_id)
                  )
                )""",
                (run_id,),
            )
            row = await cursor.fetchone()
            return bool(row and row[0])
        finally:
            await connection.close()

    async def claim_reflection_candidates(self, limit: int = 20) -> list[str]:
        """Atomically claim eligible traces, preventing duplicate background work."""
        connection = await self._connect()
        now = datetime.now(timezone.utc).isoformat()
        try:
            await connection.execute("BEGIN IMMEDIATE")
            cursor = await connection.execute(
                """SELECT r.run_id FROM runs r
                WHERE r.reflected_at IS NULL AND r.reflection_claimed_at IS NULL AND (
                  r.final_status='FAILED'
                  OR EXISTS(SELECT 1 FROM tool_invocations t WHERE t.run_id=r.run_id AND t.retry_count>2)
                  OR EXISTS(SELECT 1 FROM friction_signals f WHERE f.run_id=r.run_id)
                ) ORDER BY r.timestamp LIMIT ?""",
                (limit,),
            )
            ids = [str(row[0]) for row in await cursor.fetchall()]
            if ids:
                placeholders = ",".join("?" for _ in ids)
                await connection.execute(
                    f"UPDATE runs SET reflection_claimed_at=? WHERE run_id IN ({placeholders})",
                    (now, *ids),
                )
            await connection.commit()
            return ids
        except BaseException:
            await connection.rollback()
            raise
        finally:
            await connection.close()

    async def complete_reflection(self, run_ids: list[str], succeeded: bool) -> None:
        if not run_ids:
            return
        connection = await self._connect()
        try:
            placeholders = ",".join("?" for _ in run_ids)
            if succeeded:
                await connection.execute(
                    f"UPDATE runs SET reflected_at=?, reflection_claimed_at=NULL WHERE run_id IN ({placeholders})",
                    (datetime.now(timezone.utc).isoformat(), *run_ids),
                )
            else:
                await connection.execute(
                    f"UPDATE runs SET reflection_claimed_at=NULL WHERE run_id IN ({placeholders})",
                    run_ids,
                )
            await connection.commit()
        finally:
            await connection.close()

    async def read_runs(self, run_ids: list[str]) -> list[dict[str, Any]]:
        """Return bounded reflection input without exposing arbitrary SQL."""
        if not run_ids:
            return []
        connection = await self._connect()
        connection.row_factory = aiosqlite.Row
        try:
            placeholders = ",".join("?" for _ in run_ids)
            cursor = await connection.execute(
                f"SELECT run_id,graph_id,timestamp,total_duration_ms,final_status,error FROM runs WHERE run_id IN ({placeholders})",
                run_ids,
            )
            result: list[dict[str, Any]] = []
            for row in await cursor.fetchall():
                item = dict(row)
                tools = await connection.execute(
                    "SELECT tool_name,arguments_json,execution_status,error_stack_trace,retry_count FROM tool_invocations WHERE run_id=?",
                    (item["run_id"],),
                )
                item["tool_invocations"] = [dict(value) for value in await tools.fetchall()]
                nodes = await connection.execute(
                    "SELECT node_id,prompt_tokens,completion_tokens,latency_ms,system_prompt_snapshot FROM node_traces WHERE run_id=?",
                    (item["run_id"],),
                )
                item["node_traces"] = [dict(value) for value in await nodes.fetchall()]
                assertions = await connection.execute(
                    "SELECT name,exit_code,outcome,user_feedback,human_override_diff FROM assertion_results WHERE run_id=?",
                    (item["run_id"],),
                )
                item["assertions"] = [dict(value) for value in await assertions.fetchall()]
                friction = await connection.execute(
                    "SELECT kind,details,timestamp FROM friction_signals WHERE run_id=?",
                    (item["run_id"],),
                )
                item["friction_signals"] = [dict(value) for value in await friction.fetchall()]
                result.append(item)
            return result
        finally:
            await connection.close()
