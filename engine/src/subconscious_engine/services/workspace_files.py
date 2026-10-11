"""Scope-checked UTF-8 workspace file access."""

from __future__ import annotations

import asyncio
import builtins
from dataclasses import dataclass
from io import BytesIO
import json
import os
from pathlib import Path
import zipfile

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from subconscious_engine.api.extra_schemas import (
    WorkspaceFileContentDto,
    WorkspaceFileEntryDto,
)
from subconscious_engine.storage.models import Workspace


@dataclass(frozen=True, slots=True)
class WorkspaceFilePreview:
    content: bytes
    media_type: str
    kind: str
    filename: str


class WorkspaceFileError(RuntimeError):
    def __init__(self, status_code: int, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code


class WorkspaceFileService:
    MAX_BYTES = 1_000_000
    SEARCH_MAX_RESULTS = 50
    SEARCH_MAX_FILES = 25_000
    SEARCH_SKIPS = {
        ".git", ".hg", ".svn", ".subconscious", ".dart_tool", "node_modules",
        "build", "dist", "bin", "obj", "__pycache__", ".venv", "venv",
    }
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
    PDF_MEDIA_TYPE = "application/pdf"
    DOCX_MEDIA_TYPE = (
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )
    IMAGE_MAX_BYTES = 20 * 1024 * 1024
    PDF_MAX_BYTES = 50 * 1024 * 1024
    DOCX_MAX_BYTES = 25 * 1024 * 1024
    DOCX_MAX_MEMBERS = 2_048
    DOCX_MAX_UNCOMPRESSED_BYTES = 100 * 1024 * 1024
    DOCX_MAX_MEMBER_BYTES = 25 * 1024 * 1024
    DOCX_MAX_COMPRESSION_RATIO = 100

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

    async def search(self, workspace_uuid: str, query: str,
                     limit: int = 20) -> list[dict[str, object]]:
        raw = await self.session.scalar(
            select(Workspace.directories).where(Workspace.uuid == workspace_uuid)
        )
        if raw is None:
            raise WorkspaceFileError(404, "The requested workspace does not exist.")
        try:
            configured = json.loads(raw) if raw else []
        except json.JSONDecodeError as error:
            raise WorkspaceFileError(
                400, "Workspace directories must be a JSON array of absolute paths."
            ) from error
        if not isinstance(configured, list):
            raise WorkspaceFileError(
                400, "Workspace directories must be a JSON array of absolute paths."
            )
        bounded_limit = min(max(limit, 1), self.SEARCH_MAX_RESULTS)
        matches: list[dict[str, object]] = []
        for root_index in range(len(configured)):
            root = await self.root(workspace_uuid, root_index)
            matches.extend(await asyncio.to_thread(
                self._search_sync, root, root_index, query, bounded_limit
            ))
        folded = query.strip().casefold()
        matches.sort(key=lambda item: (
            0 if str(item["name"]).casefold().startswith(folded) else 1,
            len(str(item["relativePath"])),
            str(item["relativePath"]).casefold(),
            int(item["rootIndex"]),
        ))
        return matches[:bounded_limit]

    async def read(self, workspace_uuid: str, root_index: int, relative_path: str) -> WorkspaceFileContentDto:
        root = await self.root(workspace_uuid, root_index)
        return await asyncio.to_thread(self._read_sync, root, relative_path)

    async def preview(self, workspace_uuid: str, root_index: int,
                      relative_path: str) -> WorkspaceFilePreview:
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

    async def move(
        self,
        workspace_uuid: str,
        source_root_index: int,
        source_path: str,
        destination_root_index: int,
        destination_path: str,
    ) -> WorkspaceFileEntryDto:
        if source_root_index != destination_root_index:
            raise WorkspaceFileError(400, "Moving between workspace roots is not supported.")
        root = await self.root(workspace_uuid, source_root_index)
        return await asyncio.to_thread(
            self._move_sync, root, source_path, destination_path
        )

    def _list_sync(self, root: Path, relative_path: str | None) -> builtins.list[WorkspaceFileEntryDto]:
        directory = self._existing(root, relative_path, allow_root=True)
        self._ensure_existing_directory(directory)
        directory = self._existing(root, relative_path, allow_root=True)
        entries = [WorkspaceFileEntryDto(name=item.name,
                   relative_path=item.relative_to(root).as_posix(), is_directory=item.is_dir())
                   for item in directory.iterdir() if not self._is_reparse(item)]
        return sorted(entries, key=lambda item: (not item.is_directory, item.name.casefold()))

    def _search_sync(self, root: Path, root_index: int, query: str,
                     limit: int) -> list[dict[str, object]]:
        folded = query.strip().casefold()
        matches: list[dict[str, object]] = []
        visited = 0
        for directory, dirnames, filenames in os.walk(root, followlinks=False):
            base = Path(directory)
            dirnames[:] = [
                name for name in dirnames
                if name.casefold() not in self.SEARCH_SKIPS
                and not self._is_reparse(base / name)
            ]
            for name in filenames:
                visited += 1
                if visited > self.SEARCH_MAX_FILES:
                    return matches
                file = base / name
                if self._is_reparse(file):
                    continue
                relative = file.relative_to(root).as_posix()
                if folded and folded not in relative.casefold():
                    continue
                matches.append({
                    "rootIndex": root_index,
                    "name": name,
                    "relativePath": relative,
                })
                if len(matches) >= limit:
                    return matches
        return matches

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

    def _preview_sync(self, root: Path, relative_path: str) -> WorkspaceFilePreview:
        file = self._existing_regular_file(root, relative_path)
        extension = file.suffix.casefold()
        media_type = self.IMAGE_MEDIA_TYPES.get(extension)
        if media_type is not None:
            kind, limit = "image", self.IMAGE_MAX_BYTES
        elif extension == ".pdf":
            kind, media_type, limit = "pdf", self.PDF_MEDIA_TYPE, self.PDF_MAX_BYTES
        elif extension == ".docx":
            kind, media_type, limit = "docx", self.DOCX_MEDIA_TYPE, self.DOCX_MAX_BYTES
        else:
            raise WorkspaceFileError(
                400, "The requested file is not a supported image, PDF, or DOCX file."
            )
        if file.stat().st_size > limit:
            raise WorkspaceFileError(400, f"The requested {kind} preview is too large.")
        raw = self._existing_regular_file(root, relative_path).read_bytes()
        if len(raw) > limit:
            raise WorkspaceFileError(400, f"The requested {kind} preview is too large.")
        if kind == "image":
            self._validate_image(extension, raw)
        elif kind == "pdf":
            if not raw.startswith(b"%PDF-"):
                raise WorkspaceFileError(400, "The requested file is not a valid PDF.")
        else:
            self._validate_docx(raw)
        return WorkspaceFilePreview(raw, media_type, kind, file.name)

    @classmethod
    def _validate_image(cls, extension: str, raw: bytes) -> None:
        valid = {
            ".bmp": raw.startswith(b"BM"),
            ".gif": raw.startswith((b"GIF87a", b"GIF89a")),
            ".jpeg": raw.startswith(b"\xff\xd8\xff"),
            ".jpg": raw.startswith(b"\xff\xd8\xff"),
            ".png": raw.startswith(b"\x89PNG\r\n\x1a\n"),
            ".webp": len(raw) >= 12
            and raw.startswith(b"RIFF") and raw[8:12] == b"WEBP",
        }
        if extension == ".svg":
            try:
                text = raw.removeprefix(b"\xef\xbb\xbf").decode("utf-8")
            except UnicodeDecodeError as error:
                raise WorkspaceFileError(400, "The requested SVG is not valid UTF-8.") from error
            folded = text.lstrip().casefold()
            valid[extension] = "<svg" in folded[:1_024]
            if any(value in folded for value in (
                "<!doctype", "<!entity", "<script", "<foreignobject",
                "javascript:", "http://", "https://", "file://",
            )):
                valid[extension] = False
        if not valid.get(extension, False):
            raise WorkspaceFileError(400, "The requested image signature is invalid.")

    @classmethod
    def _validate_docx(cls, raw: bytes) -> None:
        if not raw.startswith(b"PK\x03\x04"):
            raise WorkspaceFileError(400, "The requested file is not a valid DOCX archive.")
        try:
            with zipfile.ZipFile(BytesIO(raw)) as archive:
                members = archive.infolist()
                if len(members) > cls.DOCX_MAX_MEMBERS:
                    raise WorkspaceFileError(400, "The DOCX archive has too many entries.")
                names = {member.filename.replace("\\", "/") for member in members}
                if not {"[Content_Types].xml", "word/document.xml"}.issubset(names) \
                        or "xl/workbook.xml" in names \
                        or "ppt/presentation.xml" in names:
                    raise WorkspaceFileError(400, "The requested archive is not a DOCX file.")
                total = 0
                for member in members:
                    if member.flag_bits & 0x1:
                        raise WorkspaceFileError(400, "Encrypted DOCX archives are unsupported.")
                    if member.compress_type not in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}:
                        raise WorkspaceFileError(400, "The DOCX uses unsupported compression.")
                    if member.file_size > cls.DOCX_MAX_MEMBER_BYTES:
                        raise WorkspaceFileError(400, "A DOCX archive entry is too large.")
                    if member.file_size and (
                        member.file_size / max(1, member.compress_size)
                        > cls.DOCX_MAX_COMPRESSION_RATIO
                    ):
                        raise WorkspaceFileError(400, "The DOCX compression ratio is unsafe.")
                    total += member.file_size
                    if total > cls.DOCX_MAX_UNCOMPRESSED_BYTES:
                        raise WorkspaceFileError(400, "The DOCX expands beyond the safe limit.")
        except (zipfile.BadZipFile, zipfile.LargeZipFile) as error:
            raise WorkspaceFileError(400, "The requested DOCX archive is invalid.") from error

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

    def _move_sync(
        self, root: Path, source_path: str, destination_path: str
    ) -> WorkspaceFileEntryDto:
        source = self._existing(root, source_path, allow_root=False)
        destination = self._existing(root, destination_path or None, allow_root=True)
        self._ensure_existing_directory(destination)
        target = destination / source.name
        self._ensure_within(root, target)
        if target == source:
            raise WorkspaceFileError(400, "The source is already in the destination directory.")
        if source.is_dir():
            try:
                target.relative_to(source)
            except ValueError:
                pass
            else:
                raise WorkspaceFileError(
                    400, "A directory cannot be moved into itself or one of its children."
                )
        if target.exists() or target.is_symlink():
            raise WorkspaceFileError(409, "A file or directory already exists at the destination.")
        os.replace(source, target)
        return WorkspaceFileEntryDto(
            name=target.name,
            relative_path=target.relative_to(root).as_posix(),
            is_directory=target.is_dir(),
        )

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
