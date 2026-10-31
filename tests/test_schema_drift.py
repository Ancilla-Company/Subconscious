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
    assert sorted(_drift(path)) == [
        "agents (table missing)", "app_state.client", "skills (table missing)", "tool_registry.config_json"]

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
        assert migrations.migrate(connection) == [3, 4, 5]
    with engine.begin() as connection:
        assert migrations.migrate(connection) == []
    engine.dispose()


def test_migration_four_adds_tool_registry_config_json_to_a_version_three_database(tmp_path: Path) -> None:
    path = tmp_path / "subconscious.db"
    _legacy_db(path)
    connection = sqlite3.connect(path)
    try:
        connection.execute("INSERT INTO schema_migrations VALUES (3, 'app_state_client_scope', 'x')")
        connection.execute(
            "INSERT INTO tool_registry (id, uuid, name, tool_type, status, created_at, updated_at) "
            "VALUES (1, 'tool-1', 'legacy', 'script', 'active', '2024-01-01 00:00:00', '2024-01-01 00:00:00')"
        )
        connection.commit()
        assert "config_json" not in [r[1] for r in connection.execute("PRAGMA table_info(tool_registry)")]
    finally:
        connection.close()
    engine = create_engine(f"sqlite:///{path}")
    with engine.begin() as connection:
        assert migrations.migrate(connection) == [4, 5]
        assert "config_json" in migrations._columns(connection, "tool_registry")
        assert connection.execute(text("SELECT name, config_json FROM tool_registry")).all() == [("legacy", None)]
        assert migrations.LATEST_VERSION == 5
        assert "agents" in migrations.inspect(connection).get_table_names()
        assert "skills" in migrations.inspect(connection).get_table_names()
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
        assert sorted(migrations.log_schema_drift(connection)) == [
            "agents (table missing)", "app_state.client", "skills (table missing)", "tool_registry.config_json"]
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
