import logging
import os
from pathlib import Path

from subconscious_engine import logging_setup as ls


def _record(name: str, msg: str, level: int = logging.INFO) -> logging.LogRecord:
    return logging.LogRecord(name, level, __file__, 1, msg, None, None)


def test_health_access_lines_filtered_but_others_kept() -> None:
    f = ls.HealthAccessFilter()
    assert not f.filter(_record("uvicorn.access", '127.0.0.1 - "GET /api/v1/health HTTP/1.1" 200'))
    assert f.filter(_record("uvicorn.access", '127.0.0.1 - "GET /api/v1/workspaces HTTP/1.1" 200'))
    assert f.filter(_record("other", "GET /api/v1/health"))


def test_file_handler_defaults_to_warning_and_rotation_limits(tmp_path: Path, monkeypatch) -> None:
    for name in (ls.FILE_LEVEL_ENVIRONMENT_VARIABLE, ls.MAX_BYTES_ENVIRONMENT_VARIABLE,
                 ls.BACKUP_COUNT_ENVIRONMENT_VARIABLE):
        monkeypatch.delenv(name, raising=False)
    handler, path, failure = ls._open_file_handler(tmp_path)
    assert failure is None and path is not None
    try:
        assert handler.level == logging.WARNING
        assert handler.maxBytes == 5 * 1024 * 1024
        assert handler.backupCount == 3
    finally:
        handler.close()


def test_environment_overrides(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv(ls.FILE_LEVEL_ENVIRONMENT_VARIABLE, "debug")
    monkeypatch.setenv(ls.MAX_BYTES_ENVIRONMENT_VARIABLE, "2048")
    monkeypatch.setenv(ls.BACKUP_COUNT_ENVIRONMENT_VARIABLE, "1")
    handler, _, _ = ls._open_file_handler(tmp_path)
    try:
        assert (handler.level, handler.maxBytes, handler.backupCount) == (logging.DEBUG, 2048, 1)
    finally:
        handler.close()


def test_rotation_caps_files(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setenv(ls.MAX_BYTES_ENVIRONMENT_VARIABLE, "1024")
    monkeypatch.setenv(ls.BACKUP_COUNT_ENVIRONMENT_VARIABLE, "2")
    handler, path, _ = ls._open_file_handler(tmp_path)
    logger = logging.getLogger("rotation-test")
    logger.propagate = False
    logger.addHandler(handler)
    try:
        for _ in range(200):
            logger.warning("x" * 100)
        logger.info("ignored info")
    finally:
        logger.removeHandler(handler)
        handler.close()
    names = sorted(p.name for p in tmp_path.iterdir())
    assert names == ["engine.log", "engine.log.1", "engine.log.2"]
    assert "ignored info" not in "".join(p.read_text() for p in tmp_path.iterdir())
