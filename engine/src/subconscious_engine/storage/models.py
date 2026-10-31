"""SQLAlchemy entities compatible with the .NET engine table names."""

from datetime import datetime, timezone
from uuid import uuid4

from sqlalchemy import (
    DDL,
    CheckConstraint,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    event,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def new_uuid() -> str:
    return str(uuid4())


class Base(DeclarativeBase):
    pass


class SyncColumns:
    """Hive sync bookkeeping shared by every synced entity (webrtc.md 7.2)."""

    origin_node_id: Mapped[str | None] = mapped_column(String)
    hlc: Mapped[str | None] = mapped_column(String)
    deleted_at: Mapped[datetime | None]


class Network(Base):
    __tablename__ = "networks"
    id: Mapped[int] = mapped_column(primary_key=True)
    uuid: Mapped[str] = mapped_column(String, unique=True)
    name: Mapped[str] = mapped_column(String)
    description: Mapped[str | None] = mapped_column(Text)
    default_workspace_uuid: Mapped[str | None] = mapped_column(String)
    passphrase: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = mapped_column(default=utc_now)
    workspaces: Mapped[list["Workspace"]] = relationship(back_populates="network", cascade="all, delete")


class Workspace(SyncColumns, Base):
    __tablename__ = "workspaces"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String)
    description: Mapped[str | None] = mapped_column(Text)
    network_id: Mapped[int] = mapped_column(ForeignKey("networks.id", ondelete="CASCADE"))
    uuid: Mapped[str] = mapped_column(String, unique=True)
    tools_config: Mapped[str | None] = mapped_column(Text)
    skills_config: Mapped[str | None] = mapped_column(Text)
    directories: Mapped[str | None] = mapped_column(Text)
    approval_config: Mapped[str | None] = mapped_column(Text)
    rag_config: Mapped[str | None] = mapped_column(Text)
    default_model_id: Mapped[str | None] = mapped_column(String)
    updated_at: Mapped[datetime] = mapped_column(default=utc_now)
    created_at: Mapped[datetime] = mapped_column(default=utc_now)
    network: Mapped[Network] = relationship(back_populates="workspaces")
    threads: Mapped[list["ConversationThread"]] = relationship(back_populates="workspace", cascade="all, delete")


class ConversationThread(SyncColumns, Base):
    __tablename__ = "threads"
    id: Mapped[int] = mapped_column(primary_key=True)
    uuid: Mapped[str] = mapped_column(String, unique=True)
    workspace_id: Mapped[int] = mapped_column(ForeignKey("workspaces.id", ondelete="CASCADE"))
    title: Mapped[str | None] = mapped_column(String)
    description: Mapped[str | None] = mapped_column(Text)
    default_model_id: Mapped[str | None] = mapped_column(String)
    tools_config: Mapped[str | None] = mapped_column(Text)
    skills_config: Mapped[str | None] = mapped_column(Text)
    approval_config: Mapped[str | None] = mapped_column(Text)
    updated_at: Mapped[datetime] = mapped_column(default=utc_now)
    created_at: Mapped[datetime] = mapped_column(default=utc_now)
    workspace: Mapped[Workspace] = relationship(back_populates="threads")
    messages: Mapped[list["Message"]] = relationship(back_populates="thread", cascade="all, delete")


class Message(SyncColumns, Base):
    __tablename__ = "messages"
    id: Mapped[int] = mapped_column(primary_key=True)
    uuid: Mapped[str] = mapped_column(String, unique=True)
    thread_id: Mapped[int] = mapped_column(ForeignKey("threads.id", ondelete="CASCADE"))
    role: Mapped[str] = mapped_column(String)
    content: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(default=utc_now)
    thread: Mapped[ConversationThread] = relationship(back_populates="messages")


class AppState(Base):
    __tablename__ = "app_state"
    __table_args__ = (UniqueConstraint("key", "tag", "client", name="uq_app_state_scope"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    key: Mapped[str] = mapped_column(String)
    value: Mapped[str] = mapped_column(Text)
    tag: Mapped[str | None] = mapped_column(String)
    client: Mapped[str | None] = mapped_column(String)


class ToolRegistryRecord(Base):
    __tablename__ = "tool_registry"
    id: Mapped[int] = mapped_column(primary_key=True)
    uuid: Mapped[str] = mapped_column(String, unique=True)
    name: Mapped[str] = mapped_column(String)
    alias: Mapped[str | None] = mapped_column(String)
    description: Mapped[str | None] = mapped_column(Text)
    tool_type: Mapped[str] = mapped_column(String, default="script")
    script_path: Mapped[str | None] = mapped_column(Text)
    script_language: Mapped[str | None] = mapped_column(String)
    endpoint_url: Mapped[str | None] = mapped_column(Text)
    auth_type: Mapped[str | None] = mapped_column(String)
    auth_env_var: Mapped[str | None] = mapped_column(String)
    # JSON {"command","args","env","cwd"} for mcp (stdio) and cli tools. ``env`` is NOT
    # secret: it is stored in plain text. Secrets belong in the encrypted api_key headers.
    config_json: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str] = mapped_column(String, default="active")
    created_at: Mapped[datetime] = mapped_column(default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(default=utc_now)


class SkillRecord(Base):
    """A reusable instruction set (a SKILL.md folder/file or stored text) the model can read on demand."""

    __tablename__ = "skills"
    id: Mapped[int] = mapped_column(primary_key=True)
    uuid: Mapped[str] = mapped_column(String, unique=True, default=new_uuid)
    name: Mapped[str] = mapped_column(String, unique=True)
    alias: Mapped[str | None] = mapped_column(String)
    description: Mapped[str | None] = mapped_column(Text)
    source_type: Mapped[str] = mapped_column(String, default="folder")
    source: Mapped[str | None] = mapped_column(Text)
    instructions: Mapped[str | None] = mapped_column(Text)
    enabled: Mapped[bool] = mapped_column(default=True)
    created_at: Mapped[datetime] = mapped_column(default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(default=utc_now)


class AgentRecord(Base):
    """A reusable assistant profile: instructions, model, tools and permissions.

    ``workspace_id`` NULL means the agent is account-wide; otherwise it belongs to that
    workspace. ``tools_config`` and ``approval_config`` use the thread/workspace formats and
    NULL means "inherit the workspace's". Local to this engine (not hive-synced).
    """

    __tablename__ = "agents"
    id: Mapped[int] = mapped_column(primary_key=True)
    uuid: Mapped[str] = mapped_column(String, unique=True, default=new_uuid)
    workspace_id: Mapped[int | None] = mapped_column(ForeignKey("workspaces.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String)
    description: Mapped[str | None] = mapped_column(Text)
    instructions: Mapped[str | None] = mapped_column(Text)
    default_model_id: Mapped[str | None] = mapped_column(String)
    tools_config: Mapped[str | None] = mapped_column(Text)
    approval_config: Mapped[str | None] = mapped_column(Text)
    enabled: Mapped[bool] = mapped_column(default=True)
    created_at: Mapped[datetime] = mapped_column(default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(default=utc_now)


class TodoItem(Base):
    __tablename__ = "todo_items"
    id: Mapped[int] = mapped_column(primary_key=True)
    uuid: Mapped[str] = mapped_column(String, unique=True, default=new_uuid)
    workspace_id: Mapped[int] = mapped_column(ForeignKey("workspaces.id", ondelete="CASCADE"))
    thread_id: Mapped[int | None] = mapped_column(ForeignKey("threads.id", ondelete="SET NULL"))
    title: Mapped[str] = mapped_column(String)
    notes: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str] = mapped_column(String, default="open")
    priority: Mapped[str] = mapped_column(String, default="normal")
    due_date: Mapped[datetime | None]
    created_at: Mapped[datetime] = mapped_column(default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(default=utc_now)


class WorkspaceMemory(Base):
    __tablename__ = "workspace_memory"
    id: Mapped[int] = mapped_column(primary_key=True)
    uuid: Mapped[str] = mapped_column(String, unique=True, default=new_uuid)
    workspace_id: Mapped[int] = mapped_column(ForeignKey("workspaces.id", ondelete="CASCADE"))
    key: Mapped[str] = mapped_column(String)
    value: Mapped[str] = mapped_column(Text)
    source_thread_id: Mapped[int | None] = mapped_column(ForeignKey("threads.id", ondelete="SET NULL"))
    created_at: Mapped[datetime] = mapped_column(default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(default=utc_now)


class Note(Base):
    __tablename__ = "notes"
    id: Mapped[int] = mapped_column(primary_key=True)
    uuid: Mapped[str] = mapped_column(String, unique=True, default=new_uuid)
    workspace_id: Mapped[int] = mapped_column(ForeignKey("workspaces.id", ondelete="CASCADE"))
    title: Mapped[str] = mapped_column(String)
    content: Mapped[str] = mapped_column(Text, default="")
    tags: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(default=utc_now)


class Contact(Base):
    __tablename__ = "contacts"
    id: Mapped[int] = mapped_column(primary_key=True)
    uuid: Mapped[str] = mapped_column(String, unique=True, default=new_uuid)
    workspace_id: Mapped[int] = mapped_column(ForeignKey("workspaces.id", ondelete="CASCADE"))
    name: Mapped[str] = mapped_column(String)
    email: Mapped[str | None] = mapped_column(String)
    phone: Mapped[str | None] = mapped_column(String)
    notes: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(default=utc_now)


# --- hive sync tables (webrtc.md 7.2) -------------------------------------------------


class SyncLog(Base):
    """Signed ops from every origin, so any node can forward them."""

    __tablename__ = "sync_log"
    origin_node_id: Mapped[str] = mapped_column(String, primary_key=True)
    origin_seq: Mapped[int] = mapped_column(Integer, primary_key=True)
    entity: Mapped[str] = mapped_column(String)
    entity_uuid: Mapped[str] = mapped_column(String)
    op: Mapped[str] = mapped_column(String)
    hlc: Mapped[str] = mapped_column(String)
    payload: Mapped[str] = mapped_column(Text)
    sig: Mapped[str] = mapped_column(String)
    __table_args__ = (Index("ix_sync_log_entity", "entity", "entity_uuid"),)


class SyncState(Base):
    """Single row (id=1): version vector, clock and the local op counter."""

    __tablename__ = "sync_state"
    id: Mapped[int] = mapped_column(primary_key=True)
    hive_id: Mapped[str | None] = mapped_column(String)
    node_id: Mapped[str | None] = mapped_column(String)
    last_hlc: Mapped[str | None] = mapped_column(String)
    per_origin_applied: Mapped[str] = mapped_column(Text, default="{}")
    local_seq: Mapped[int] = mapped_column(Integer, default=0)


class SyncPending(Base):
    """Ops whose parent entity has not arrived yet."""

    __tablename__ = "sync_pending"
    id: Mapped[int] = mapped_column(primary_key=True)
    origin_node_id: Mapped[str] = mapped_column(String)
    origin_seq: Mapped[int] = mapped_column(Integer)
    missing_entity: Mapped[str] = mapped_column(String)
    missing_uuid: Mapped[str] = mapped_column(String, index=True)
    op: Mapped[str] = mapped_column(Text)
    __table_args__ = (UniqueConstraint("origin_node_id", "origin_seq", name="uq_sync_pending_op"),)


class SyncFieldClock(Base):
    """Per-field last-writer-wins clock for entities merged field by field."""

    __tablename__ = "sync_field_clock"
    entity: Mapped[str] = mapped_column(String, primary_key=True)
    entity_uuid: Mapped[str] = mapped_column(String, primary_key=True)
    field: Mapped[str] = mapped_column(String, primary_key=True)
    hlc: Mapped[str] = mapped_column(String)
    origin_node_id: Mapped[str] = mapped_column(String)


class HiveMeta(Base):
    __tablename__ = "hive_meta"
    key: Mapped[str] = mapped_column(String, primary_key=True)
    value: Mapped[str] = mapped_column(Text)


class RemoteToolAudit(Base):
    """Local-only, append-only record of remote tool calls (webrtc.md section 8).

    Never synced and never holds raw arguments or results: only a SHA-256 of the
    canonical arguments.
    """

    __tablename__ = "remote_tool_audit"
    id: Mapped[int] = mapped_column(primary_key=True)
    ts: Mapped[datetime] = mapped_column(default=utc_now, index=True)
    direction: Mapped[str] = mapped_column(String)  # "in" (we ran it) or "out" (we asked a peer)
    peer_node_id: Mapped[str] = mapped_column(String)
    task_id: Mapped[str | None] = mapped_column(String)
    tool: Mapped[str] = mapped_column(String)
    args_sha256: Mapped[str] = mapped_column(String)
    outcome: Mapped[str] = mapped_column(String)
    duration_ms: Mapped[int] = mapped_column(Integer, default=0)
    __table_args__ = (CheckConstraint("direction IN ('in', 'out')", name="ck_remote_tool_audit_direction"),)


# Append-only: the database itself refuses to rewrite or delete audit rows.
for _verb in ("UPDATE", "DELETE"):
    event.listen(
        RemoteToolAudit.__table__,
        "after_create",
        DDL(
            f"CREATE TRIGGER IF NOT EXISTS remote_tool_audit_no_{_verb.lower()} "
            f"BEFORE {_verb} ON remote_tool_audit "
            "BEGIN SELECT RAISE(ABORT, 'remote_tool_audit is append-only'); END"
        ).execute_if(dialect="sqlite"),
    )


class TaskRecord(SyncColumns, Base):
    """A unit of agent work routed to one executor node (webrtc.md 7.4).

    ``payload`` is machine local (never synced): it holds the request body of a
    task that is queued at the accepting node until the executor is reachable.
    """

    __tablename__ = "tasks"
    id: Mapped[int] = mapped_column(primary_key=True)
    task_id: Mapped[str] = mapped_column(String, unique=True, default=new_uuid)
    thread_uuid: Mapped[str] = mapped_column(String, index=True)
    workspace_uuid: Mapped[str | None] = mapped_column(String)
    executor_node_id: Mapped[str] = mapped_column(String)
    requester_node_id: Mapped[str] = mapped_column(String)
    status: Mapped[str] = mapped_column(String, default="queued")
    rev: Mapped[int] = mapped_column(Integer, default=0)
    turn_id: Mapped[str | None] = mapped_column(String)
    model_id: Mapped[str | None] = mapped_column(String)
    client_msg_uuid: Mapped[str | None] = mapped_column(String)
    created_at: Mapped[datetime] = mapped_column(default=utc_now)
    started_at: Mapped[datetime | None]
    finished_at: Mapped[datetime | None]
    error: Mapped[str | None] = mapped_column(Text)
    payload: Mapped[str | None] = mapped_column(Text)
