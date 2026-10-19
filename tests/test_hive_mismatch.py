"""Hive id guard: matching, different, legacy/unset and backup-then-reset."""

import asyncio
import sqlite3

from subconscious_engine.hive.errors import HiveError
from subconscious_engine.hive.service import (
    HIVE_MISMATCH_DETAIL,
    HiveService,
    _backup_sqlite,
)
from subconscious_engine.hive.sync.engine import SyncEngine
from subconscious_engine.storage import Database


def run(coro):
    return asyncio.run(coro)


async def _engine(tmp_path):
    database = Database(tmp_path / "subconscious.db")
    await database.initialize()
    return database, SyncEngine(database)


def test_matching_hive_is_accepted(tmp_path):
    async def scenario():
        database, engine = await _engine(tmp_path)
        assert await engine.check_hive("h1")
        assert await engine.check_hive("h1")
        assert engine.hive_id == "h1" and engine.blocked is None
        await database.close()

    run(scenario())


def test_different_hive_is_blocked_not_overwritten(tmp_path):
    async def scenario():
        database, engine = await _engine(tmp_path)
        assert await engine.check_hive("h1")
        assert not await engine.check_hive("h2")
        assert engine.blocked == "hive_mismatch"
        assert await engine.get_meta("hive_id") == "h1"
        await database.close()

    run(scenario())


def test_unset_server_hive_id_never_binds_or_mismatches(tmp_path):
    async def scenario():
        database, engine = await _engine(tmp_path)
        assert await engine.check_hive("")
        assert await engine.get_meta("hive_id") is None
        assert await engine.check_hive("h1")
        assert await engine.check_hive("")
        assert engine.hive_id == "h1" and engine.blocked is None
        await database.close()

    run(scenario())


def test_backup_then_reset_keeps_a_copy_and_clears_the_hive_id(tmp_path):
    async def scenario():
        database, engine = await _engine(tmp_path)
        await engine.check_hive("h1")

        class State:
            sync_engine = engine

        class App:
            state = State()

        service = HiveService.__new__(HiveService)
        service.app = App()
        service._data_directory = tmp_path
        service._lock = asyncio.Lock()
        service._user = None
        service._stop_locked = _noop
        backup = await HiveService.reset_local_hive_data(service)
        assert backup.exists() and backup.name.startswith("subconscious.db.bak-")
        copy = sqlite3.connect(backup)
        try:
            row = copy.execute("select value from hive_meta where key='hive_id'").fetchone()
        finally:
            copy.close()
        assert row == ("h1",)
        assert await engine.get_meta("hive_id") is None
        assert (tmp_path / "subconscious.db").exists()
        await database.close()

    run(scenario())


async def _noop() -> None:
    return None


def test_reset_without_engine_raises_and_detail_is_actionable(tmp_path):
    service = HiveService.__new__(HiveService)
    service.app = None
    service._data_directory = tmp_path
    try:
        run(HiveService.reset_local_hive_data(service))
    except HiveError as error:
        assert error.status_code == 503
    else:
        raise AssertionError("expected HiveError")
    assert "different hive" in HIVE_MISMATCH_DETAIL and "Reset local hive data" in HIVE_MISMATCH_DETAIL
    assert callable(_backup_sqlite)
