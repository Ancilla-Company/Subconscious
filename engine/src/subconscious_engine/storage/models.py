"""SQLAlchemy entities compatible with the .NET engine table names."""

from datetime import datetime, timezone

from sqlalchemy import ForeignKey, String, Text, UniqueConstraint
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class Base(DeclarativeBase):
    pass


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


class Workspace(Base):
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


class ConversationThread(Base):
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


class Message(Base):
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
    status: Mapped[str] = mapped_column(String, default="active")
    created_at: Mapped[datetime] = mapped_column(default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(default=utc_now)


class TodoItem(Base):
    __tablename__ = "todo_items"
    id: Mapped[int] = mapped_column(primary_key=True)
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
    workspace_id: Mapped[int] = mapped_column(ForeignKey("workspaces.id", ondelete="CASCADE"))
    key: Mapped[str] = mapped_column(String)
    value: Mapped[str] = mapped_column(Text)
    source_thread_id: Mapped[int | None] = mapped_column(ForeignKey("threads.id", ondelete="SET NULL"))
    created_at: Mapped[datetime] = mapped_column(default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(default=utc_now)


class Note(Base):
    __tablename__ = "notes"
    id: Mapped[int] = mapped_column(primary_key=True)
    workspace_id: Mapped[int] = mapped_column(ForeignKey("workspaces.id", ondelete="CASCADE"))
    title: Mapped[str] = mapped_column(String)
    content: Mapped[str] = mapped_column(Text, default="")
    tags: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(default=utc_now)


class Contact(Base):
    __tablename__ = "contacts"
    id: Mapped[int] = mapped_column(primary_key=True)
    workspace_id: Mapped[int] = mapped_column(ForeignKey("workspaces.id", ondelete="CASCADE"))
    name: Mapped[str] = mapped_column(String)
    email: Mapped[str | None] = mapped_column(String)
    phone: Mapped[str | None] = mapped_column(String)
    notes: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(default=utc_now)
