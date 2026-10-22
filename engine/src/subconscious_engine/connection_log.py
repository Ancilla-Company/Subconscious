"""Connection lifecycle log: every connect, disconnect and drop reaches engine.log.

Failures of connections (clients, peer links, signalling) must never be silent.
Records go to one dedicated logger that the file handler always keeps at INFO
(see ``logging_setup``), while the rest of the engine stays at WARNING in the
file. Use :func:`connection_event` for expected lifecycle steps and
:func:`connection_problem` for drops and failures (WARNING).

Stdlib-only; nothing here may raise into a connection.
"""
import logging
from typing import Any

CONNECTION_LOGGER = "subconscious_engine.connections"

_LOG = logging.getLogger(CONNECTION_LOGGER)
_LOG.setLevel(logging.INFO)
_FALLBACK = logging.getLogger(__name__)


def _format(event: str, fields: dict[str, Any]) -> str:
    parts = [event]
    for key, value in fields.items():
        if value is None or value == "":
            continue
        text = str(value).replace("\n", " ")
        parts.append(f"{key}={text!r}" if " " in text else f"{key}={text}")
    return " ".join(parts)


def connection_event(event: str, **fields: Any) -> None:
    """An expected lifecycle step (connected, closed normally)."""
    try:
        _LOG.info(_format(event, fields))
    except Exception:  # noqa: BLE001 - logging must never break a connection
        _FALLBACK.warning("Could not log connection event %s", event, exc_info=True)


def connection_problem(event: str, *, exc_info: bool = False, **fields: Any) -> None:
    """A drop or failure: always WARNING, so it is kept at every log level."""
    try:
        _LOG.warning(_format(event, fields), exc_info=exc_info)
    except Exception:  # noqa: BLE001
        _FALLBACK.warning("Could not log connection problem %s", event, exc_info=True)
