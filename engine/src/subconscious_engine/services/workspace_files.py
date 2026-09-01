"""Scope-checked UTF-8 workspace file access."""

from __future__ import annotations

import asyncio
import builtins
import json
import os
from pathlib import Path

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from subconscious_engine.api.extra_schemas import (
    WorkspaceFileContentDto,
    WorkspaceFileEntryDto,
    WorkspaceFilePreviewDto,
)
from subconscious_engine.storage.models import Workspace


class WorkspaceFileError(RuntimeError):
    def __init__(self, status_code: int, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code


class WorkspaceFileService:
    MAX_BYTES = 1_000_000
    EXTENSIONS = {".c", ".cc", ".cpp", ".cs", ".csx", ".css", ".fs", ".fsx", ".go",
                  ".h", ".hpp", ".html", ".htm", ".java", ".js", ".jsx", ".json",
                  ".md", ".markdown", ".php", ".ps1", ".py", ".rb", ".rs", ".sh",
                  ".sql", ".toml", ".ts", ".tsx", ".txt", ".xml", ".xaml", ".yml", ".yaml"}
    IMAGE_MEDIA_TYPES = {
        ".bmp": "image/bmp",
        ".gif": "image/gif",
        ".jpeg": "image/jpeg",
        ".jpg": "image/jpeg",
        ".png": "image/png",
        ".svg": "image/svg+xml",
        ".webp": "image/webp",
    }

    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def root(self, workspace_uuid: str, root_index: int) -> Path:
        raw = await self.session.scalar(select(Workspace.directories).where(Workspace.uuid == workspace_uuid))
        if raw is None:
            raise WorkspaceFileError(404, "The requested workspace does not exist.")
        try:
            roots = json.loads(raw) if raw else []
        except json.JSONDecodeError as error:
            raise WorkspaceFileError(400, "Workspace directories must be a JSON array of absolute paths.") from error
        if not isinstance(roots, list) or not 0 <= root_index < len(roots):
            raise WorkspaceFileError(400, "rootIndex does not select a configured workspace root.")
        configured = roots[root_index]
        if not isinstance(configured, str) or not configured.strip():
            raise WorkspaceFileError(400, "The selected workspace root is not an absolute path.")
        root = Path(configured).expanduser()
        if not root.is_absolute():
            raise WorkspaceFileError(400, "The selected workspace root is not an absolute path.")
        self._ensure_existing_directory(root)
        if self._is_reparse(root):
            raise WorkspaceFileError(403, "The selected workspace root is a reparse point.")
        return root.resolve()

    async def list(self, workspace_uuid: str, root_index: int, relative_path: str | None) -> list[WorkspaceFileEntryDto]:
        root = await self.root(workspace_uuid, root_index)
        return await asyncio.to_thread(self._list_sync, root, relative_path)

    async def read(self, workspace_uuid: str, root_index: int, relative_path: str) -> WorkspaceFileContentDto:
        root = await self.root(workspace_uuid, root_index)
        return await asyncio.to_thread(self._read_sync, root, relative_path)

    async def preview(self, workspace_uuid: str, root_index: int, relative_path: str) -> WorkspaceFilePreviewDto:
        root = await self.root(workspace_uuid, root_index)
        return await asyncio.to_thread(self._preview_sync, root, relative_path)

    async def create(self, workspace_uuid: str, root_index: int, relative_path: str, content: str | None) -> WorkspaceFileContentDto:
        encoded = self._encode(content)
        root = await self.root(workspace_uuid, root_index)
        return await asyncio.to_thread(self._create_sync, root, relative_path, content or "", encoded)

    async def write(self, workspace_uuid: str, root_index: int, relative_path: str, content: str | None) -> WorkspaceFileContentDto:
        encoded = self._encode(content)
        root = await self.root(workspace_uuid, root_index)
        return await asyncio.to_thread(self._write_sync, root, relative_path, content or "", encoded)

    async def create_directory(self, workspace_uuid: str, root_index: int, relative_path: str) -> WorkspaceFileEntryDto:
        root = await self.root(workspace_uuid, root_index)
        return await asyncio.to_thread(self._create_directory_sync, root, relative_path)

    def _list_sync(self, root: Path, relative_path: str | None) -> builtins.list[WorkspaceFileEntryDto]:
        directory = self._existing(root, relative_path, allow_root=True)
        self._ensure_existing_directory(directory)
        directory = self._existing(root, relative_path, allow_root=True)
        entries = [WorkspaceFileEntryDto(name=item.name,
                   relative_path=item.relative_to(root).as_posix(), is_directory=item.is_dir())
                   for item in directory.iterdir() if not self._is_reparse(item)]
        return sorted(entries, key=lambda item: (not item.is_directory, item.name.casefold()))

    def _read_sync(self, root: Path, relative_path: str) -> WorkspaceFileContentDto:
        file = self._existing_file(root, relative_path)
        if file.stat().st_size > self.MAX_BYTES:
            raise WorkspaceFileError(400, "The requested file exceeds the 1 MB limit.")
        raw = self._existing_file(root, relative_path).read_bytes()
        if len(raw) > self.MAX_BYTES:
            raise WorkspaceFileError(400, "The requested file exceeds the 1 MB limit.")
        try:
            return WorkspaceFileContentDto(content=raw.removeprefix(b"\xef\xbb\xbf").decode("utf-8"))
        except UnicodeDecodeError as error:
            raise WorkspaceFileError(400, "The requested file is not valid UTF-8 text.") from error

    def _preview_sync(self, root: Path, relative_path: str) -> WorkspaceFilePreviewDto:
        file = self._existing_regular_file(root, relative_path)
        media_type = self.IMAGE_MEDIA_TYPES.get(file.suffix.casefold())
        if media_type is None:
            raise WorkspaceFileError(400, "The requested file is not a supported image.")
        return WorkspaceFilePreviewDto(local_path=str(file), media_type=media_type)

    def _create_sync(self, root: Path, relative_path: str, content: str, encoded: bytes) -> WorkspaceFileContentDto:
        file = self._new_target(root, relative_path, file_target=True)
        try:
            with file.open("xb") as stream:
                stream.write(encoded)
                stream.flush()
                os.fsync(stream.fileno())
        except FileExistsError as error:
            raise WorkspaceFileError(409, "A file or directory already exists at the requested path.") from error
        return WorkspaceFileContentDto(content=content)

    def _write_sync(self, root: Path, relative_path: str, content: str, encoded: bytes) -> WorkspaceFileContentDto:
        file = self._existing_file(root, relative_path)
        file = self._existing_file(root, relative_path)
        with file.open("r+b") as stream:
            stream.seek(0)
            stream.write(encoded)
            stream.truncate()
            stream.flush()
            os.fsync(stream.fileno())
        return WorkspaceFileContentDto(content=content)

    def _create_directory_sync(self, root: Path, relative_path: str) -> WorkspaceFileEntryDto:
        directory = self._new_target(root, relative_path.rstrip("/\\"), file_target=False)
        try:
            directory.mkdir()
        except FileExistsError as error:
            raise WorkspaceFileError(409, "A file or directory already exists at the requested path.") from error
        return WorkspaceFileEntryDto(name=directory.name, relative_path=directory.relative_to(root).as_posix(), is_directory=True)

    def _existing_file(self, root: Path, relative_path: str) -> Path:
        file = self._existing_regular_file(root, relative_path)
        self._ensure_extension(file)
        return file

    def _existing_regular_file(self, root: Path, relative_path: str) -> Path:
        file = self._existing(root, relative_path, allow_root=False)
        if not file.is_file():
            raise WorkspaceFileError(400, "The content path must identify a file, not a directory.")
        return file

    def _existing(self, root: Path, relative_path: str | None, allow_root: bool) -> Path:
        target = root.joinpath(*self._parts(relative_path, allow_root))
        self._ensure_within(root, target)
        current = root
        for part in target.relative_to(root).parts:
            current /= part
            if not current.exists():
                raise WorkspaceFileError(404, "The requested workspace path does not exist.")
            if self._is_reparse(current):
                raise WorkspaceFileError(403, "The requested path contains a reparse point.")
        return target

    def _new_target(self, root: Path, relative_path: str, file_target: bool) -> Path:
        parts = self._parts(relative_path, allow_root=False)
        target = root.joinpath(*parts)
        self._ensure_within(root, target)
        parent = self._existing(root, "/".join(parts[:-1]) or None, allow_root=True)
        self._ensure_existing_directory(parent)
        if target.exists() or target.is_symlink():
            raise WorkspaceFileError(409, "A file or directory already exists at the requested path.")
        if file_target:
            self._ensure_extension(target)
        return target

    @staticmethod
    def _parts(relative_path: str | None, allow_root: bool) -> tuple[str, ...]:
        if relative_path is None and allow_root:
            return ()
        if not relative_path:
            raise WorkspaceFileError(400, "A workspace-relative path is required.")
        normalized = relative_path.replace("\\", "/")
        parts = tuple(normalized.split("/"))
        if normalized.startswith("/") or ":" in normalized or any(part in {"", ".", ".."} for part in parts):
            raise WorkspaceFileError(400, "The path must be workspace-relative without traversal segments.")
        return parts

    @classmethod
    def _encode(cls, content: str | None) -> bytes:
        if content is None:
            raise WorkspaceFileError(400, "Content is required.")
        try:
            encoded = content.encode("utf-8", errors="strict")
        except UnicodeEncodeError as error:
            raise WorkspaceFileError(400, "Content is not valid UTF-8 text.") from error
        if len(encoded) > cls.MAX_BYTES:
            raise WorkspaceFileError(400, "Content exceeds the 1 MB limit.")
        return encoded

    @classmethod
    def _ensure_extension(cls, path: Path) -> None:
        if path.suffix.casefold() not in cls.EXTENSIONS:
            raise WorkspaceFileError(400, "The requested file is not a supported text or source file.")

    @staticmethod
    def _ensure_within(root: Path, target: Path) -> None:
        try:
            if os.path.commonpath((str(root), str(target))) != str(root):
                raise WorkspaceFileError(403, "The requested path is outside the configured workspace root.")
        except ValueError as error:
            raise WorkspaceFileError(403, "The requested path is outside the configured workspace root.") from error

    @staticmethod
    def _is_reparse(path: Path) -> bool:
        is_junction = getattr(path, "is_junction", None)
        return path.is_symlink() or bool(is_junction and is_junction())

    @staticmethod
    def _ensure_existing_directory(path: Path) -> None:
        if not path.exists():
            raise WorkspaceFileError(404, "The requested workspace path does not exist.")
        if not path.is_dir():
            raise WorkspaceFileError(400, "The requested path must identify a directory.")
