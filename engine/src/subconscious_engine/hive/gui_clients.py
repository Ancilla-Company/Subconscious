"""Persisted ``client_id -> thin node id`` mapping for GUI clients folded under this engine."""

from __future__ import annotations

import json
import logging
from pathlib import Path

_LOG = logging.getLogger(__name__)


class GuiClientStore:
    def __init__(self, path: Path | None) -> None:
        self._path = path
        self.mapping: dict[str, str] = {}
        self._load()

    def _load(self) -> None:
        if self._path is None or not self._path.exists():
            return
        try:
            raw = json.loads(self._path.read_text(encoding="utf-8"))
            self.mapping = {
                k: v
                for k, v in raw.get("clients", {}).items()
                if isinstance(k, str) and isinstance(v, str)
            }
        except (OSError, ValueError, AttributeError):
            _LOG.warning("GUI client store could not be read; starting empty.", exc_info=True)

    def save(self) -> None:
        if self._path is None:
            return
        self._path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self._path.with_suffix(".tmp")
        temporary.write_text(json.dumps({"clients": self.mapping}), encoding="utf-8")
        temporary.replace(self._path)
