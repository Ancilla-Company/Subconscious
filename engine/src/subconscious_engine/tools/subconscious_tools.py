"""Narrow, unattended tools available only to the subconscious graph."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import tempfile
from typing import Any

from pydantic_ai import Tool

from subconscious_engine.telemetry import TelemetryStore


_SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$")


class SubconsciousToolset:
    def __init__(self, data_directory: Path, telemetry: TelemetryStore) -> None:
        self.root = data_directory / "context"
        self.telemetry = telemetry

    def _asset(self, kind: str, name: str) -> Path:
        if not _SAFE_NAME.fullmatch(name):
            raise ValueError("Asset names may contain only letters, digits, dot, dash, and underscore.")
        directories = {"user": self.root, "skill": self.root / "skills", "prompt": self.root / "prompt-overrides"}
        if kind not in directories:
            raise ValueError("kind must be user, skill, or prompt")
        suffix = "" if kind == "user" else ".skill" if kind == "skill" else ".md"
        filename = "USER.md" if kind == "user" else name if name.endswith(suffix) else name + suffix
        return directories[kind] / filename

    @staticmethod
    def _atomic_write(path: Path, content: str) -> dict[str, Any]:
        if len(content.encode("utf-8")) > 1_000_000:
            raise ValueError("Context assets are limited to 1 MB.")
        path.parent.mkdir(parents=True, exist_ok=True)
        handle, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        try:
            with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        return {"status": "updated", "asset": str(path.name), "characters": len(content)}

    def tools(self) -> list[Tool[Any]]:
        async def read_execution_telemetry(run_ids: list[str]) -> list[dict[str, Any]]:
            """Read only the foreground telemetry runs selected by the trigger filter."""
            return await self.telemetry.read_runs(run_ids[:20])

        def read_context_asset(kind: str, name: str = "USER.md") -> dict[str, str]:
            """Read USER.md, a declarative skill, or a prompt override."""
            path = self._asset(kind, name)
            return {"asset": path.name, "content": path.read_text(encoding="utf-8") if path.is_file() else ""}

        def write_user_context(content: str) -> dict[str, Any]:
            """Atomically replace USER.md with evidence-backed durable user context."""
            return self._atomic_write(self._asset("user", "USER.md"), content)

        def write_skill(name: str, definition_json: str) -> dict[str, Any]:
            """Validate and atomically write a declarative .skill JSON file."""
            value = json.loads(definition_json)
            if not isinstance(value, dict) or not isinstance(value.get("name"), str):
                raise ValueError("A skill must be a JSON object with a string name.")
            normalized = json.dumps(value, ensure_ascii=False, indent=2) + "\n"
            return self._atomic_write(self._asset("skill", name), normalized)

        def write_prompt_override(name: str, content: str) -> dict[str, Any]:
            """Atomically write a named system-prompt override."""
            if not content.strip():
                raise ValueError("Prompt overrides cannot be empty.")
            return self._atomic_write(self._asset("prompt", name), content)

        definitions = [
            (read_execution_telemetry, "read_execution_telemetry"),
            (read_context_asset, "read_context_asset"),
            (write_user_context, "write_user_context"),
            (write_skill, "write_skill"),
            (write_prompt_override, "write_prompt_override"),
        ]
        return [Tool(function, name=name) for function, name in definitions]
