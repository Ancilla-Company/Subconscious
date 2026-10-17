import logging
import logging.handlers
import sys
import threading

import pytest

from subconscious_engine import logging_setup
from subconscious_engine.logging_setup import configure_engine_logging


@pytest.fixture(autouse=True)
def restore_logging():
    root = logging.getLogger()
    handlers = list(root.handlers)
    level = root.level
    hook, thread_hook = sys.excepthook, threading.excepthook
    unraisable = sys.unraisablehook
    hooks_installed = logging_setup._hooks_installed
    log_path = logging_setup._log_path
    for h in list(root.handlers):
        if getattr(h, logging_setup._HANDLER_MARKER, False):
            root.removeHandler(h)
    logging_setup._hooks_installed = False
    yield
    for h in list(root.handlers):
        if h not in handlers:
            root.removeHandler(h)
            h.close()
    root.setLevel(level)
    sys.excepthook, threading.excepthook = hook, thread_hook
    sys.unraisablehook = unraisable
    logging_setup._hooks_installed = hooks_installed
    logging_setup._log_path = log_path
    logging.captureWarnings(False)


def _file_handlers():
    return [
        h
        for h in logging.getLogger().handlers
        if isinstance(h, logging.handlers.RotatingFileHandler)
        and getattr(h, logging_setup._HANDLER_MARKER, False)
    ]


def test_creates_rotating_log_file_with_startup_line(tmp_path):
    path = configure_engine_logging(tmp_path)
    assert path == tmp_path / "logs" / "engine.log"
    handler = _file_handlers()[0]
    assert handler.maxBytes > 0 and handler.backupCount > 0
    handler.flush()
    text = path.read_text(encoding="utf-8")
    assert "logging started" in text and str(tmp_path) in text


def test_is_idempotent(tmp_path):
    configure_engine_logging(tmp_path)
    configure_engine_logging(tmp_path)
    assert len(_file_handlers()) == 1


def test_uncaught_thread_exception_is_logged_with_traceback(tmp_path):
    path = configure_engine_logging(tmp_path)

    def fail():
        raise RuntimeError("boom-thread")

    thread = threading.Thread(target=fail)
    thread.start()
    thread.join()
    _file_handlers()[0].flush()
    text = path.read_text(encoding="utf-8")
    assert "boom-thread" in text and "Traceback" in text


def test_never_raises_when_data_directory_unusable(tmp_path):
    blocker = tmp_path / "file"
    blocker.write_text("x")
    configure_engine_logging(blocker)  # falls back to temp/stderr, must not raise


def test_works_with_stderr_and_stdout_none(tmp_path, monkeypatch):
    monkeypatch.setattr(sys, "stderr", None)
    monkeypatch.setattr(sys, "stdout", None)
    path = configure_engine_logging(tmp_path)
    logging.getLogger("t").error("with-no-stdio", exc_info=(ValueError, ValueError("x"), None))
    _file_handlers()[0].flush()
    assert "with-no-stdio" in path.read_text(encoding="utf-8")
    assert not [h for h in logging.getLogger().handlers
                if type(h) is logging.StreamHandler and getattr(h, logging_setup._HANDLER_MARKER, False)]


def test_excepthook_logs_traceback(tmp_path):
    path = configure_engine_logging(tmp_path)
    try:
        raise RuntimeError("boom-main")
    except RuntimeError:
        logging_setup._excepthook(*sys.exc_info())
    _file_handlers()[0].flush()
    text = path.read_text(encoding="utf-8")
    assert "boom-main" in text and "Traceback" in text


def test_asyncio_handler_and_spawn_logged_log_failures(tmp_path):
    import asyncio

    path = configure_engine_logging(tmp_path)

    async def fail():
        raise RuntimeError("boom-task")

    async def scenario():
        logging_setup.install_asyncio_exception_handler()
        task = logging_setup.spawn_logged(fail(), name="failing-task")
        await asyncio.sleep(0.05)
        assert task.done()
        asyncio.get_running_loop().call_exception_handler(
            {"message": "loop-level", "exception": RuntimeError("boom-loop")})

    logging_setup.run_logged(scenario())
    _file_handlers()[0].flush()
    text = path.read_text(encoding="utf-8")
    assert "failing-task failed" in text and "boom-task" in text
    assert "loop-level" in text and "boom-loop" in text


def test_logged_suppress_logs_what_it_swallows(tmp_path):
    path = configure_engine_logging(tmp_path)
    with logging_setup.logged_suppress(ValueError, what="parsing"):
        raise ValueError("swallowed-value")
    _file_handlers()[0].flush()
    text = path.read_text(encoding="utf-8")
    assert "swallowed-value" in text and "parsing" in text
