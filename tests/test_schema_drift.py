"""Legacy databases must reach the current model schema on startup."""
import asyncio
import logging
import sqlite3
from pathlib import Path

from sqlalchemy import create_engine, text

from subconscious_engine.services.settings import SettingsService
from subconscious_engine.storage import migrations
from subconscious_engine.storage.database import Database

SCHEMA_V2 = Path(__file__).parent / "fixtures" / "schema_v2.sql"  # frozen: never regenerate from models
LEGACY_APP_STATE = (
    'CREATE TABLE app_state (id INTEGER NOT NULL, "key" VARCHAR NOT NULL, '
    "value VARCHAR NOT NULL, tag VARCHAR, PRIMARY KEY (id));"
)


def _legacy_db(path: Path) -> None:
    """Frozen schema as of migration 2 (legacy app_state), stamped at 1 and 2."""
    connection = sqlite3.connect(path)
    try:
        connection.executescript(SCHEMA_V2.read_text(encoding="utf8") + LEGACY_APP_STATE)
        connection.execute("INSERT INTO app_state (id, key, value, tag) VALUES (5, 'mode', 'light', 'system')")
        connection.execute("INSERT INTO app_state (id, key, value, tag) VALUES (9, 'colour', 'default', 'system')")
        connection.execute(
            "CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TEXT NOT NULL)"
        )
        connection.execute("INSERT INTO schema_migrations VALUES (1, 'hive_sync', 'x'), (2, 'remote_tool_audit', 'x')")
        connection.commit()
    finally:
        connection.close()

def _drift(path: Path) -> list[str]:
    engine = create_engine(f"sqlite:///{path}")
    with engine.connect() as connection:
        result = migrations.schema_drift(connection)
    engine.dispose()
    return result


def test_legacy_database_is_upgraded_on_startup(tmp_path: Path) -> None:
    path = tmp_path / "subconscious.db"
    _legacy_db(path)
    assert _drift(path) == ["app_state.client"]

    async def run() -> tuple[Path | None, list]:
        database = Database(path)
        await database.initialize()
        async with database.session() as session:
            rows = await SettingsService(session).list(None, None, "flutter")
        backup = database.last_backup
        await database.initialize()  # second run: nothing pending, no new backup
        assert database.last_backup is None
        await database.close()
        return backup, rows

    backup, rows = asyncio.run(run())
    assert backup is not None and backup.exists()
    assert _drift(path) == []
    connection = sqlite3.connect(path)
    try:
        stored = connection.execute("SELECT id, key, value, tag, client FROM app_state ORDER BY id").fetchall()
        versions = [r[0] for r in connection.execute("SELECT version FROM schema_migrations ORDER BY version")]
    finally:
        connection.close()
    assert stored == [(5, "mode", "light", "system", None), (9, "colour", "default", "system", None)]
    assert versions == [m[0] for m in migrations.MIGRATIONS]
    assert rows == []  # legacy rows have client NULL, so the flutter-scoped query is empty

def test_migrate_twice_is_noop(tmp_path: Path) -> None:
    path = tmp_path / "subconscious.db"
    _legacy_db(path)
    engine = create_engine(f"sqlite:///{path}")
    with engine.begin() as connection:
        assert migrations.migrate(connection) == [3]
    with engine.begin() as connection:
        assert migrations.migrate(connection) == []
    engine.dispose()


def test_oldest_schema_migrates_to_model(tmp_path: Path) -> None:
    """Guard: a model column without a migration fails here."""
    path = tmp_path / "subconscious.db"
    _legacy_db(path)
    engine = create_engine(f"sqlite:///{path}")
    with engine.begin() as connection:
        migrations.migrate(connection)
        assert migrations.schema_drift(connection) == []
    engine.dispose()


def test_drift_is_logged_not_raised(tmp_path: Path, caplog) -> None:
    path = tmp_path / "subconscious.db"
    _legacy_db(path)
    engine = create_engine(f"sqlite:///{path}")
    with caplog.at_level(logging.ERROR, logger="uvicorn.error"), engine.connect() as connection:
        assert migrations.log_schema_drift(connection) == ["app_state.client"]
    engine.dispose()
    assert "app_state.client" in caplog.text


def test_flutter_scoped_row_is_readable_after_migration(tmp_path: Path) -> None:
    path = tmp_path / "subconscious.db"
    _legacy_db(path)

    async def run() -> list:
        database = Database(path)
        await database.initialize()
        async with database.session() as session:
            await session.execute(
                text("INSERT INTO app_state (key, value, tag, client) VALUES ('theme', 'dark', 'ui', 'flutter')")
            )
            await session.commit()
            rows = await SettingsService(session).list(None, None, "flutter")
        await database.close()
        return rows

    rows = asyncio.run(run())
    assert [(r.key, r.value) for r in rows] == [("theme", "dark")]


def test_schema_check_failure_is_logged_not_raised(monkeypatch, caplog) -> None:
    def boom(_connection):
        raise RuntimeError("pragma failed")

    monkeypatch.setattr(migrations, "schema_drift", boom)
    with caplog.at_level(logging.ERROR, logger="uvicorn.error"):
        assert migrations.log_schema_drift(None) == []
    assert "self-check failed" in caplog.text
