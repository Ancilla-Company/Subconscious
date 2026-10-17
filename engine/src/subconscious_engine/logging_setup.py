"""Production logging for the engine: one rotating engine.log plus safety nets.

Stdlib-only on purpose: every entry point imports this first, before anything
that could fail. Nothing in here may raise.
"""
import asyncio
import logging
import logging.handlers
import os
import platform
import sys
import tempfile
import threading
from collections.abc import Callable, Coroutine
from pathlib import Path
from typing import Any

LOG_FILE_NAME = "engine.log"
LOG_DIRECTORY_NAME = "logs"
MAX_BYTES = 5 * 1024 * 1024
BACKUP_COUNT = 5
LEVEL_ENVIRONMENT_VARIABLE = "SUBCONSCIOUS_LOG_LEVEL"
_FORMAT = (
    "%(asctime)s.%(msecs)03d %(levelname)-8s %(name)s "
    "[pid=%(process)d tid=%(thread)d %(threadName)s] %(message)s"
)
_DATE_FORMAT = "%Y-%m-%d %H:%M:%S"
_HANDLER_MARKER = "_subconscious_engine_handler"
_NETWORK_LOGGERS = (
    "uvicorn", "uvicorn.error", "uvicorn.access", "fastapi", "starlette", "httpx",
    "httpcore", "temporalio", "ray", "aiohttp", "websockets", "asyncio",
)
_lock = threading.RLock()
_log_path: Path | None = None
_previous_excepthook = sys.excepthook
_hooks_installed = False
_log = logging.getLogger(__name__)


def default_data_directory(dev: bool = False) -> Path:
    """The engine's data directory (same helper that locates runtime.json)."""
    from .config import EngineConfig

    return EngineConfig(dev=dev).resolved_data_directory


def current_log_path() -> Path | None:
    return _log_path


def _resolve_level(dev: bool, level: int | str | None) -> int:
    requested = level if level is not None else os.environ.get(LEVEL_ENVIRONMENT_VARIABLE)
    if isinstance(requested, int):
        return requested
    if isinstance(requested, str) and requested.strip():
        value = logging.getLevelName(requested.strip().upper())
        if isinstance(value, int):
            return value
    return logging.DEBUG if dev else logging.INFO


def _stderr_is_stream() -> bool:
    stream = sys.stderr
    return stream is not None and hasattr(stream, "write")


def _open_file_handler(directory: Path) -> tuple[logging.Handler | None, Path | None, str | None]:
    try:
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / LOG_FILE_NAME
        handler = logging.handlers.RotatingFileHandler(
            path, maxBytes=MAX_BYTES, backupCount=BACKUP_COUNT, encoding="utf-8", delay=False
        )
        return handler, path, None
    except Exception as error:  # noqa: BLE001 - reported through the returned note
        return None, None, f"{type(error).__name__}: {error}"


def configure_engine_logging(
    data_directory: Path | None = None,
    *,
    dev: bool = False,
    level: int | str | None = None,
    component: str = "engine",
) -> Path | None:
    """Idempotently route all logging to <data_dir>/logs/engine.log. Never raises."""
    global _log_path
    try:
        with _lock:
            root = logging.getLogger()
            log_level = _resolve_level(dev, level)
            existing = [h for h in root.handlers if getattr(h, _HANDLER_MARKER, False)]
            if existing and data_directory is not None and _log_path is not None \
                    and _log_path != data_directory / LOG_DIRECTORY_NAME / LOG_FILE_NAME \
                    and _log_path.parent != Path(tempfile.gettempdir()) / "subconscious-logs":
                # A later caller knows the real data directory (e.g. --data-dir): move the file.
                for old in existing:
                    root.removeHandler(old)
                    old.close()
                existing = []
            if existing:
                root.setLevel(log_level)
                install_global_hooks()
                return _log_path
            notes: list[str] = []
            try:
                directory = (data_directory or default_data_directory(dev)) / LOG_DIRECTORY_NAME
            except Exception as error:  # noqa: BLE001
                notes.append(f"could not resolve data directory ({type(error).__name__}: {error})")
                directory = Path(tempfile.gettempdir()) / "subconscious-logs"
            handler, path, failure = _open_file_handler(directory)
            if handler is None:
                notes.append(f"could not open {directory / LOG_FILE_NAME} ({failure})")
                fallback = Path(tempfile.gettempdir()) / "subconscious-logs"
                handler, path, failure = _open_file_handler(fallback)
                if handler is None:
                    notes.append(f"could not open temp log file ({failure}); using stderr only")
            formatter = logging.Formatter(_FORMAT, _DATE_FORMAT)
            handlers: list[logging.Handler] = []
            if handler is not None:
                handlers.append(handler)
            if _stderr_is_stream() or handler is None:
                if sys.stderr is not None:
                    handlers.append(logging.StreamHandler(sys.stderr))
            for item in handlers:
                item.setFormatter(formatter)
                item.setLevel(logging.NOTSET)
                setattr(item, _HANDLER_MARKER, True)
                root.addHandler(item)
            root.setLevel(log_level)
            _configure_library_loggers(log_level)
            logging.captureWarnings(True)
            _log_path = path
            install_global_hooks()
            _log_startup(component, path, data_directory, dev, log_level, notes)
            return path
    except Exception as error:  # noqa: BLE001 - logging setup must never raise
        _report_failure(f"logging setup failed: {type(error).__name__}: {error}")
        return None


def _configure_library_loggers(level: int) -> None:
    for name in _NETWORK_LOGGERS:
        library = logging.getLogger(name)
        for existing in list(library.handlers):
            library.removeHandler(existing)
        library.propagate = True
        library.disabled = False
        if name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
            library.setLevel(min(level, logging.INFO))
        elif level <= logging.DEBUG and name != "asyncio":
            library.setLevel(logging.INFO)


def _log_startup(
    component: str, path: Path | None, data_directory: Path | None, dev: bool,
    level: int, notes: list[str],
) -> None:
    try:
        from . import __version__
    except Exception:  # noqa: BLE001
        __version__ = "unknown"
    for note in notes:
        _log.warning("Logging fallback: %s", note)
    _log.info(
        "%s logging started: log_file=%s data_dir=%s version=%s frozen=%s executable=%s "
        "python=%s platform=%s dev=%s level=%s pid=%s stderr_attached=%s",
        component, path, data_directory, __version__, bool(getattr(sys, "frozen", False)),
        sys.executable, platform.python_version(), platform.platform(), dev,
        logging.getLevelName(level), os.getpid(), _stderr_is_stream(),
    )


def _report_failure(message: str) -> None:
    stream = sys.stderr
    if stream is None:
        return
    try:
        stream.write(message + "\n")
    except Exception:  # noqa: BLE001 - nowhere left to report
        return


def install_global_hooks() -> None:
    """Log uncaught exceptions from the main thread, threads and unraisable hooks."""
    global _hooks_installed, _previous_excepthook
    with _lock:
        if _hooks_installed:
            return
        _hooks_installed = True
        _previous_excepthook = sys.excepthook
        sys.excepthook = _excepthook
        threading.excepthook = _threading_excepthook
        sys.unraisablehook = _unraisablehook


def _excepthook(exc_type: type[BaseException], exc: BaseException, tb: Any) -> None:
    if issubclass(exc_type, KeyboardInterrupt):
        logging.getLogger("subconscious_engine.main").info("Interrupted by user")
    else:
        logging.getLogger("subconscious_engine.main").critical(
            "Uncaught exception", exc_info=(exc_type, exc, tb)
        )
    try:
        _previous_excepthook(exc_type, exc, tb)
    except Exception:  # noqa: BLE001
        logging.getLogger("subconscious_engine.main").exception("Default excepthook failed")


def _threading_excepthook(args: Any) -> None:
    if args.exc_type is SystemExit:
        return
    name = args.thread.name if args.thread is not None else "unknown"
    logging.getLogger("subconscious_engine.thread").critical(
        "Uncaught exception in thread %s", name,
        exc_info=(args.exc_type, args.exc_value, args.exc_traceback),
    )


def _unraisablehook(args: Any) -> None:
    logging.getLogger("subconscious_engine.unraisable").error(
        "Unraisable exception: %s (object=%r)", args.err_msg, args.object,
        exc_info=(args.exc_type, args.exc_value, args.exc_traceback),
    )


def asyncio_exception_handler(loop: asyncio.AbstractEventLoop, context: dict[str, Any]) -> None:
    """Loop exception handler that logs the full traceback."""
    exception = context.get("exception")
    message = context.get("message", "Unhandled asyncio error")
    logger = logging.getLogger("subconscious_engine.asyncio")
    if isinstance(exception, BaseException):
        logger.error("%s (context=%r)", message, {k: v for k, v in context.items() if k != "exception"},
                     exc_info=(type(exception), exception, exception.__traceback__))
    else:
        logger.error("%s (context=%r)", message, context)


def install_asyncio_exception_handler(loop: asyncio.AbstractEventLoop | None = None) -> None:
    """Install the logging handler on `loop` (default: the running loop). Never raises."""
    try:
        target = loop or asyncio.get_running_loop()
        target.set_exception_handler(asyncio_exception_handler)
    except Exception:  # noqa: BLE001
        _log.exception("Could not install the asyncio exception handler")


def run_logged(coro: Coroutine[Any, Any, Any]) -> Any:
    """asyncio.run() with the logging exception handler installed on the new loop."""
    async def runner() -> Any:
        install_asyncio_exception_handler()
        return await coro

    return asyncio.run(runner())


def _log_task_result(task: "asyncio.Future[Any]", name: str) -> None:
    if task.cancelled():
        logging.getLogger("subconscious_engine.tasks").debug("Task %s was cancelled", name)
        return
    error = task.exception()
    if error is not None:
        logging.getLogger("subconscious_engine.tasks").error(
            "Background task %s failed", name, exc_info=(type(error), error, error.__traceback__)
        )


def spawn_logged(coro: Any, name: str | None = None) -> "asyncio.Future[Any]":
    """Schedule `coro` like create_task/ensure_future and log any exception it raises."""
    task = asyncio.ensure_future(coro)
    label = name or getattr(coro, "__qualname__", None) or repr(coro)
    if name is not None and isinstance(task, asyncio.Task):
        task.set_name(name)
    task.add_done_callback(lambda finished: _log_task_result(finished, label))
    return task


def log_gather_results(results: Any, what: str) -> None:
    """Log every exception returned by asyncio.gather(..., return_exceptions=True)."""
    for item in results:
        if isinstance(item, BaseException) and not isinstance(item, asyncio.CancelledError):
            logging.getLogger("subconscious_engine.tasks").error(
                "%s failed", what, exc_info=(type(item), item, item.__traceback__)
            )


def logged_thread_target(target: Callable[..., Any], name: str = "") -> Callable[..., Any]:
    """Wrap a Thread target so exceptions are logged with a traceback, then re-raised."""
    def runner(*args: Any, **kwargs: Any) -> Any:
        try:
            return target(*args, **kwargs)
        except BaseException:
            logging.getLogger("subconscious_engine.thread").exception(
                "Thread target %s failed", name or getattr(target, "__qualname__", target)
            )
            raise

    return runner


class logged_suppress:
    """Drop-in replacement for contextlib.suppress that logs what it swallowed."""

    def __init__(self, *exceptions: type[BaseException], what: str = "") -> None:
        self._exceptions = exceptions or (Exception,)
        self._what = what

    def __enter__(self) -> None:
        return None

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> bool:
        if exc_type is None or not issubclass(exc_type, self._exceptions):
            return False
        logger = logging.getLogger("subconscious_engine.suppressed")
        benign = issubclass(exc_type, (asyncio.CancelledError, KeyboardInterrupt, FileNotFoundError,
                                       BrokenPipeError, ConnectionResetError, asyncio.QueueEmpty,
                                       asyncio.QueueFull))
        level = logging.DEBUG if benign else logging.WARNING
        logger.log(level, "Suppressed %s%s; continuing with fallback", exc_type.__name__,
                   f" while {self._what}" if self._what else "", exc_info=(exc_type, exc, tb))
        return True
