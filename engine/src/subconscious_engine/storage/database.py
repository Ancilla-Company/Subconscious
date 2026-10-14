"""Async SQLite engine and session lifecycle."""

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

from sqlalchemy import event
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import Session

from . import migrations


class Database:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self.last_backup: Path | None = None
        self.engine = create_async_engine(f"sqlite+aiosqlite:///{path}")
        # A private Session subclass lets the hive attach flush hooks to this
        # database only (listeners on a subclass do not touch other databases).
        self.session_class: type[Session] = type("EngineSession", (Session,), {})
        self.session_factory = async_sessionmaker(
            self.engine, expire_on_commit=False, sync_session_class=self.session_class
        )

        @event.listens_for(self.engine.sync_engine, "connect")
        def enable_foreign_keys(connection: object, _: object) -> None:
            cursor = connection.cursor()  # type: ignore[attr-defined]
            cursor.execute("PRAGMA foreign_keys=ON")
            cursor.close()

    async def initialize(self) -> None:
        """Create a fresh schema, or back up and migrate an existing database."""
        self.last_backup = None
        async with self.engine.connect() as connection:
            fresh = await connection.run_sync(migrations.is_fresh)
            todo = [] if fresh else await connection.run_sync(lambda c: migrations.pending(c))
            await connection.rollback()
        if todo:
            await self.engine.dispose()  # no pooled handle may hold the file during the copy
            self.last_backup = await asyncio.to_thread(migrations.backup_database, self.path)
        async with self.engine.begin() as connection:
            if fresh:
                await connection.run_sync(migrations.stamp_fresh)
            else:
                await connection.run_sync(migrations.migrate)

    @asynccontextmanager
    async def session(self) -> AsyncIterator[AsyncSession]:
        async with self.session_factory() as session:
            yield session

    async def close(self) -> None:
        await self.engine.dispose()
