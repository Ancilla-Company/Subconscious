"""A file-backed keyring used by the live engines so they never touch the developer's real keyring.

Selected with ``PYTHON_KEYRING_BACKEND=live_keyring.FileKeyring`` (the launcher adds this folder to
``PYTHONPATH`` of the engine subprocess) and ``SC_LIVE_KEYRING_FILE=<path>``. Unlike keyring's null
backend it really stores values, so the engine's refresh token and node identity survive within a run.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

from keyring.backend import KeyringBackend
from keyring.errors import PasswordDeleteError


class FileKeyring(KeyringBackend):
    priority = 1  # type: ignore[assignment]

    def _path(self) -> Path:
        return Path(os.environ["SC_LIVE_KEYRING_FILE"])

    def _load(self) -> dict[str, str]:
        try:
            return json.loads(self._path().read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}

    def _save(self, data: dict[str, str]) -> None:
        path = self._path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data), encoding="utf-8")

    @staticmethod
    def _key(service: str, username: str) -> str:
        return f"{service}\n{username}"

    def get_password(self, service: str, username: str) -> str | None:
        return self._load().get(self._key(service, username))

    def set_password(self, service: str, username: str, password: str) -> None:
        data = self._load()
        data[self._key(service, username)] = password
        self._save(data)

    def delete_password(self, service: str, username: str) -> None:
        data = self._load()
        if data.pop(self._key(service, username), None) is None:
            raise PasswordDeleteError("not found")
        self._save(data)
