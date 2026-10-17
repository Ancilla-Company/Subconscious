"""Atomic runtime discovery file support."""

import json
import os
from pathlib import Path
from uuid import uuid4

from pydantic import BaseModel
import logging
_LOG = logging.getLogger(__name__)


class RuntimeInfo(BaseModel):
    host: str
    port: int
    token: str
    pid: int
    version: str
    node_id: str | None = None


class RuntimeInfoReader:
    @classmethod
    def read(cls, data_directory: Path) -> RuntimeInfo | None:
        source = RuntimeInfoWriter.path_for(data_directory)
        try:
            return RuntimeInfo.model_validate_json(source.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            _LOG.warning("runtime.RuntimeInfoReader.read: handled (OSError, ValueError); continuing with fallback", exc_info=True)
            return None


class RuntimeInfoWriter:
    file_name = "runtime.json"

    @classmethod
    def path_for(cls, data_directory: Path) -> Path:
        return data_directory / cls.file_name

    @classmethod
    def write(cls, data_directory: Path, info: RuntimeInfo) -> None:
        data_directory.mkdir(parents=True, exist_ok=True)
        destination = cls.path_for(data_directory)
        temporary = data_directory / f".{cls.file_name}.{os.getpid()}.{uuid4().hex}.tmp"
        try:
            temporary.write_text(info.model_dump_json(indent=2), encoding="utf-8")
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)

    @classmethod
    def delete(cls, data_directory: Path, expected_pid: int | None = None) -> None:
        if expected_pid is not None:
            current = RuntimeInfoReader.read(data_directory)
            if current is not None and current.pid != expected_pid:
                return
        try:
            cls.path_for(data_directory).unlink(missing_ok=True)
        except OSError:
            _LOG.warning("runtime.RuntimeInfoWriter.delete: handled OSError; continuing with fallback", exc_info=True)
            pass
