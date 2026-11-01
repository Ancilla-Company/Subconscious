"""Scope-checked UTF-8 workspace file access."""

from __future__ import annotations

import asyncio
import builtins
from collections.abc import Callable
import contextlib
from dataclasses import dataclass
import hashlib
from io import BytesIO
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import threading
import time
import zipfile

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from subconscious_engine.api.extra_schemas import (
    WorkspaceFileContentDto,
    WorkspaceFileEntryDto,
    WorkspaceFileVersionDto,
)
from subconscious_engine.storage.models import Workspace
import logging
_LOG = logging.getLogger(__name__)

_UTF8_BOM = b"\xef\xbb\xbf"
# Atomic writes stage their bytes in a sibling file with this suffix. It is
# hidden from listings and search so a save never shows up as a stray file.
TEMP_SUFFIX = ".subconscious-tmp"
# Writes to the same path are serialized so the version check and the replace
# below cannot interleave with another save handled by this process.
_WRITE_LOCKS = tuple(threading.Lock() for _ in range(64))


@dataclass(frozen=True, slots=True)
class WorkspaceFilePreview:
    content: bytes
    media_type: str
    kind: str
    filename: str


class WorkspaceFileError(RuntimeError):
    def __init__(
        self,
        status_code: int,
        message: str,
        code: str | None = None,
        details: dict[str, object] | None = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.details = details or {}


def content_version(raw: bytes) -> str:
    """Return the version token for the exact bytes stored on disk."""
    return hashlib.sha256(raw).hexdigest()


class WorkspaceFileService:
    MAX_BYTES = 1_000_000
    SEARCH_MAX_RESULTS = 50
    SEARCH_MAX_FILES = 25_000
    SEARCH_SKIPS = {
        ".git", ".hg", ".svn", ".subconscious", ".dart_tool", "node_modules",
        "build", "dist", "bin", "obj", "__pycache__", ".venv", "venv",
    }
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

    async def write(
        self,
        workspace_uuid: str,
        root_index: int,
        relative_path: str,
        content: str | None,
        expected_version: str | None = None,
    ) -> WorkspaceFileContentDto:
        encoded = self._encode(content)
        root = await self.root(workspace_uuid, root_index)
        return await asyncio.to_thread(
            self._write_sync, root, relative_path, content or "", encoded, expected_version
        )

    async def version(self, workspace_uuid: str, root_index: int,
                      relative_path: str) -> WorkspaceFileVersionDto:
        root = await self.root(workspace_uuid, root_index)
        return await asyncio.to_thread(self._version_sync, root, relative_path)

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
        new_name: str | None = None,
    ) -> WorkspaceFileEntryDto:
        if source_root_index != destination_root_index:
            raise WorkspaceFileError(400, "Moving between workspace roots is not supported.")
        root = await self.root(workspace_uuid, source_root_index)
        return await asyncio.to_thread(
            self._move_sync, root, source_path, destination_path, new_name
        )

    async def copy(
        self,
        workspace_uuid: str,
        source_root_index: int,
        source_path: str,
        destination_root_index: int,
        destination_path: str,
    ) -> WorkspaceFileEntryDto:
        source_root = await self.root(workspace_uuid, source_root_index)
        destination_root = await self.root(workspace_uuid, destination_root_index)
        return await asyncio.to_thread(
            self._copy_sync, source_root, source_path, destination_root, destination_path
        )

    async def delete(self, workspace_uuid: str, root_index: int, relative_path: str) -> None:
        root = await self.root(workspace_uuid, root_index)
        await asyncio.to_thread(self._delete_sync, root, relative_path)

    def _list_sync(self, root: Path, relative_path: str | None) -> builtins.list[WorkspaceFileEntryDto]:
        directory = self._existing(root, relative_path, allow_root=True)
        self._ensure_existing_directory(directory)
        directory = self._existing(root, relative_path, allow_root=True)
        entries = [WorkspaceFileEntryDto(name=item.name,
                   relative_path=item.relative_to(root).as_posix(), is_directory=item.is_dir())
                   for item in directory.iterdir()
                   if not self._is_reparse(item) and not item.name.endswith(TEMP_SUFFIX)]
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
                if name.endswith(TEMP_SUFFIX):
                    continue
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
            return WorkspaceFileContentDto(
                content=raw.removeprefix(_UTF8_BOM).decode("utf-8"),
                version=content_version(raw),
            )
        except UnicodeDecodeError as error:
            raise WorkspaceFileError(400, "The requested file is not valid UTF-8 text.") from error

    def _version_sync(self, root: Path, relative_path: str) -> WorkspaceFileVersionDto:
        file = self._existing_file(root, relative_path)
        if file.stat().st_size > self.MAX_BYTES:
            raise WorkspaceFileError(400, "The requested file exceeds the 1 MB limit.")
        raw = file.read_bytes()
        if len(raw) > self.MAX_BYTES:
            raise WorkspaceFileError(400, "The requested file exceeds the 1 MB limit.")
        return WorkspaceFileVersionDto(version=content_version(raw), size=len(raw))

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
        return WorkspaceFileContentDto(content=content, version=content_version(encoded))

    def _write_sync(
        self,
        root: Path,
        relative_path: str,
        content: str,
        encoded: bytes,
        expected_version: str | None = None,
    ) -> WorkspaceFileContentDto:
        """Replace a file atomically, optionally guarded by a content version.

        The new bytes are staged in a sibling file, flushed to disk and renamed
        over the target, so a crash or a failed write leaves the previous
        contents intact instead of a truncated file. A byte-order mark on the
        existing file is kept, because it is a property of the file rather than
        of the text the user edits.
        """
        file = self._existing_file(root, relative_path)
        if not os.access(file, os.W_OK):
            raise WorkspaceFileError(403, "The file is read-only.")
        with self._write_lock(file):
            if expected_version is not None:
                current = self._disk_version(file)
                if current != expected_version:
                    raise WorkspaceFileError(
                        409,
                        "The file changed on disk after it was opened.",
                        code="version_conflict",
                        details={"currentVersion": current},
                    )
            with file.open("rb") as existing:
                payload = _UTF8_BOM + encoded if existing.read(3) == _UTF8_BOM else encoded
            if len(payload) > self.MAX_BYTES:
                raise WorkspaceFileError(400, "Content exceeds the 1 MB limit.")
            descriptor, staged_name = tempfile.mkstemp(
                prefix=f".{file.name}.", suffix=TEMP_SUFFIX, dir=file.parent
            )
            staged = Path(staged_name)
            try:
                with os.fdopen(descriptor, "wb") as stream:
                    stream.write(payload)
                    stream.flush()
                    os.fsync(stream.fileno())
                try:
                    shutil.copymode(file, staged)
                except OSError:
                    _LOG.warning("services.workspace_files.WorkspaceFileService._write_sync: handled OSError; continuing with fallback", exc_info=True)
                    pass
                self._replace_with_retry(staged, file)
            finally:
                try:
                    staged.unlink(missing_ok=True)
                except OSError:
                    _LOG.warning("services.workspace_files.WorkspaceFileService._write_sync: handled OSError; continuing with fallback", exc_info=True)
                    pass
        return WorkspaceFileContentDto(content=content, version=content_version(payload))

    def _disk_version(self, file: Path) -> str | None:
        """Version of the file on disk, or None when it is too large to have been read."""
        if file.stat().st_size > self.MAX_BYTES:
            return None
        return content_version(file.read_bytes())

    @staticmethod
    def _write_lock(path: Path) -> threading.Lock:
        return _WRITE_LOCKS[hash(os.path.normcase(str(path))) % len(_WRITE_LOCKS)]

    @staticmethod
    def _replace_with_retry(source: Path, target: Path) -> None:
        # Windows refuses to replace a file another program holds open (search
        # indexers, sync clients, antivirus). Those holds are normally brief.
        delay = 0.02
        for attempt in range(6):
            try:
                os.replace(source, target)
                return
            except PermissionError as error:
                if attempt == 5:
                    raise WorkspaceFileError(
                        423, "The file is in use by another program. Try saving again."
                    ) from error
                time.sleep(delay)
                delay *= 2

    def _create_directory_sync(self, root: Path, relative_path: str) -> WorkspaceFileEntryDto:
        directory = self._new_target(root, relative_path.rstrip("/\\"), file_target=False)
        try:
            directory.mkdir()
        except FileExistsError as error:
            raise WorkspaceFileError(409, "A file or directory already exists at the requested path.") from error
        return WorkspaceFileEntryDto(name=directory.name, relative_path=directory.relative_to(root).as_posix(), is_directory=True)

    def _move_sync(
        self, root: Path, source_path: str, destination_path: str, new_name: str | None = None
    ) -> WorkspaceFileEntryDto:
        source = self._existing(root, source_path, allow_root=False)
        destination = self._existing(root, destination_path or None, allow_root=True)
        self._ensure_existing_directory(destination)
        name = source.name
        if new_name is not None:
            name = new_name.strip()
            if (not name or name in (".", "..") or any(c in name for c in '/\\:*?"<>|')
                    or name.endswith((" ", ".")) or name.endswith(TEMP_SUFFIX)):
                raise WorkspaceFileError(400, "That is not a valid file or folder name.")
        target = destination / name
        self._ensure_within(root, target)
        if target == source and name == source.name:
            raise WorkspaceFileError(
                400,
                "The source is already in the destination directory." if new_name is None
                else "The new name is the same as the current name.",
            )
        if source.is_dir():
            try:
                target.relative_to(source)
            except ValueError:
                _LOG.warning("services.workspace_files.WorkspaceFileService._move_sync: handled ValueError; continuing with fallback", exc_info=True)
                pass
            else:
                raise WorkspaceFileError(
                    400, "A directory cannot be moved into itself or one of its children."
                )
        # A change of letter case alone names the same entry on Windows; that is a rename.
        same_entry = os.path.normcase(str(target)) == os.path.normcase(str(source))
        if not same_entry and (target.exists() or target.is_symlink()):
            raise WorkspaceFileError(409, "A file or directory already exists at the destination.")
        os.replace(source, target)
        return WorkspaceFileEntryDto(
            name=target.name,
            relative_path=target.relative_to(root).as_posix(),
            is_directory=target.is_dir(),
        )

    def _copy_sync(
        self,
        source_root: Path,
        source_path: str,
        destination_root: Path,
        destination_path: str,
    ) -> WorkspaceFileEntryDto:
        """Copy a regular file or reparse-free directory between two workspace roots.

        Copy never follows or preserves symlinks/junctions: a directory with one
        is rejected before bytes are copied. This prevents a workspace copy from
        reading or creating a route outside its configured root. A name already
        taken at the destination does not block the copy: it gets a " Copy"
        (then " Copy 2", " Copy 3", ...) suffix instead, the way desktop file
        managers resolve a paste conflict.
        """
        source = self._existing(source_root, source_path, allow_root=False)
        destination = self._existing(destination_root, destination_path or None, allow_root=True)
        self._ensure_existing_directory(destination)
        self._reject_managed_path(source_root, source)
        self._reject_managed_path(destination_root, destination)
        probe = destination / source.name
        self._ensure_within(destination_root, probe)
        if source.is_dir():
            try:
                probe.relative_to(source)
            except ValueError:
                _LOG.warning("services.workspace_files.WorkspaceFileService._copy_sync: handled ValueError; continuing with copy", exc_info=True)
            else:
                raise WorkspaceFileError(
                    400, "A directory cannot be copied into itself or one of its children."
                )
            self._reject_reparse_entries(source_root, source)
        target = self._resolve_copy_target(destination, source.name, source.is_dir())
        self._ensure_within(destination_root, target)
        if source.is_dir():
            try:
                shutil.copytree(source, target, symlinks=False, copy_function=shutil.copy2)
            except Exception:
                # A failed recursive copy can leave a partial tree. It is our
                # just-created target and still inside the checked root.
                if target.exists() and not self._is_reparse(target):
                    with contextlib.suppress(OSError):
                        shutil.rmtree(target)
                raise
        else:
            if self._is_reparse(source):
                raise WorkspaceFileError(403, "The requested path contains a reparse point.")
            shutil.copy2(source, target, follow_symlinks=False)
        return WorkspaceFileEntryDto(
            name=target.name,
            relative_path=target.relative_to(destination_root).as_posix(),
            is_directory=source.is_dir(),
        )

    @staticmethod
    def _resolve_copy_target(destination: Path, name: str, is_directory: bool) -> Path:
        """The destination path for a copy, suffixed to dodge an existing name.

        A plain name clash becomes "name Copy", then "name Copy 2", "name Copy
        3", and so on. Files keep their extension on the suffixed name
        ("report Copy.txt"); directories and extension-less files do not split
        on a dot.
        """
        candidate = destination / name
        if not candidate.exists() and not candidate.is_symlink():
            return candidate
        if is_directory:
            stem, extension = name, ""
        else:
            as_path = Path(name)
            stem, extension = as_path.stem, as_path.suffix
        attempt = 1
        while True:
            suffix = " Copy" if attempt == 1 else f" Copy {attempt}"
            candidate = destination / f"{stem}{suffix}{extension}"
            if not candidate.exists() and not candidate.is_symlink():
                return candidate
            attempt += 1

    def _reject_reparse_entries(self, root: Path, source: Path) -> None:
        """Reject all links below a recursive-copy source before copying."""
        for directory, dirnames, filenames in os.walk(source, followlinks=False):
            current = Path(directory)
            self._ensure_within(root, current)
            for name in [*dirnames, *filenames]:
                entry = current / name
                self._ensure_within(root, entry)
                if self._is_reparse(entry):
                    raise WorkspaceFileError(
                        403, "The requested path contains a reparse point."
                    )

    @staticmethod
    def _reject_managed_path(root: Path, target: Path) -> None:
        if target.relative_to(root).parts and target.relative_to(root).parts[0].casefold() == ".subconscious":
            raise WorkspaceFileError(403, "The .subconscious folder is managed by Subconscious.")

    def _delete_sync(self, root: Path, relative_path: str) -> None:
        """Delete a file, or a directory with everything in it.

        The root itself, traversal, reparse points and missing paths are refused
        by ``_existing``. The ``.subconscious`` folder holds the engine's own
        index and is refused too. ``rmtree`` removes links found inside the
        directory without following them, so nothing outside the root is touched.
        """
        target = self._existing(root, relative_path, allow_root=False)
        if target.relative_to(root).parts[0].casefold() == ".subconscious":
            raise WorkspaceFileError(403, "The .subconscious folder is managed by Subconscious.")
        if not target.is_dir():
            self._clear_read_only(target)
            target.unlink()
            return

        def retry_read_only(function: Callable[..., object], path: str, _error: object) -> None:
            # Windows refuses to delete read-only files; clear the flag once and retry.
            self._clear_read_only(Path(path))
            function(path)

        if sys.version_info >= (3, 12):
            shutil.rmtree(target, onexc=retry_read_only)
        else:  # pragma: no cover - the engine runs on 3.12 today
            shutil.rmtree(target, onerror=retry_read_only)

    @staticmethod
    def _clear_read_only(path: Path) -> None:
        try:
            mode = path.stat(follow_symlinks=False).st_mode
            if not mode & stat.S_IWRITE:
                os.chmod(path, mode | stat.S_IWRITE)
        except OSError:
            _LOG.warning("services.workspace_files._clear_read_only: could not clear %s", path, exc_info=True)

    def _existing_file(self, root: Path, relative_path: str) -> Path:
        # No extension allowlist: any regular file can be opened as text. The
        # UTF-8 decode in _read_sync/_write_sync/_version_sync is what tells a
        # plain-text file (even an unusual one, like ".kiroignore", which has
        # no extension at all) apart from one that genuinely is not text.
        return self._existing_regular_file(root, relative_path)

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
