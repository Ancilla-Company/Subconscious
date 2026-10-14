"""Approval-gated filesystem tools with no workspace-root sandbox."""

from __future__ import annotations

import asyncio
import os
from pathlib import Path
import shutil
from collections.abc import Sequence
from typing import Any, Callable

from subconscious_engine.tools.document_files import SUPPORTED, read_document, write_document

ToolFactory = Callable[[Any], Any]
ToolEntry = tuple[str, str, str, ToolFactory]


def _path(value: str) -> Path:
    if not value:
        raise ValueError("A filesystem path is required.")
    return Path(value).expanduser()


def _summary(path: Path) -> dict[str, Any]:
    return {
        "path": str(path),
        "name": path.name,
        "isDirectory": path.is_dir(),
        "isFile": path.is_file(),
        "isSymlink": path.is_symlink(),
    }


class OutsideRootsError(ValueError):
    """A path resolved outside the folders a remote caller may touch."""


def scoped_resolver(roots: Callable[[], Sequence[str]]) -> Callable[[str], Path]:
    """Build a path resolver that only accepts paths inside ``roots``.

    The path is resolved to its real location first (``..`` collapsed, symlinks and
    junctions followed, drive/case normalised on Windows), then compared against
    the resolved roots. Relative paths are taken relative to the first root. Roots
    are re-read on every call so configuration changes apply immediately.
    """

    def resolve(value: str) -> Path:
        if not isinstance(value, str) or not value or "\x00" in value:
            raise ValueError("A filesystem path is required.")
        current = [Path(root).resolve() for root in roots()]
        if not current:
            raise OutsideRootsError("No folders are shared for remote filesystem access.")
        if os.name == "nt":
            # Device paths (\\?\, \\.\) and NTFS alternate data streams bypass naive prefix checks.
            if value.startswith(("\\\\?\\", "\\\\.\\", "//?/", "//./")):
                raise OutsideRootsError("Path is outside the shared folders.")
            if ":" in (value[2:] if len(value) > 1 and value[1] == ":" else value):
                raise OutsideRootsError("Path is outside the shared folders.")
        candidate = Path(value)
        if not candidate.is_absolute():
            candidate = current[0] / candidate
        real = candidate.resolve()
        folded = os.path.normcase(str(real))
        for root in current:
            base = os.path.normcase(str(root))
            if folded == base or folded.startswith(base.rstrip("\\/") + os.sep):
                return real
        raise OutsideRootsError("Path is outside the shared folders.")

    return resolve


def filesystem_tool_entries(resolve: Callable[[str], Path] = _path) -> list[ToolEntry]:
    """Tool definitions. ``resolve`` maps a user supplied path to a ``Path``.

    The default accepts any path (local use, approval gated). The remote variant
    passes ``scoped_resolver`` and also stops directory copies from following links.
    """
    scoped = resolve is not _path
    def list_filesystem_directory(_: Any) -> Any:
        async def list_directory(path: str) -> dict[str, Any]:
            directory = resolve(path)
            if not directory.is_dir():
                raise ValueError(f"Not a directory: {directory}")
            entries = await asyncio.to_thread(lambda: [_summary(item) for item in directory.iterdir()])
            return {"path": str(directory), "entries": sorted(entries, key=lambda item: item["name"].casefold())}
        return list_directory

    def read_filesystem_file(_: Any) -> Any:
        async def read_file(path: str, encoding: str = "utf-8") -> dict[str, Any]:
            file = resolve(path)
            if not file.is_file():
                return {"status": "error", "path": str(file),
                        "error": "The requested path is not a file."}
            try:
                if file.suffix.casefold() in SUPPORTED:
                    return {"status": "success", **await asyncio.to_thread(read_document, file)}
                content = await asyncio.to_thread(file.read_text, encoding=encoding)
            except (UnicodeError, LookupError) as error:
                return {
                    "status": "error",
                    "path": str(file),
                    "error": (
                        f"The file cannot be read as {encoding} text and may be binary. "
                        "Supported binary documents are PDF, DOCX, XLSX, and PPTX. "
                        f"Details: {error}"
                    ),
                }
            except Exception as error:
                return {"status": "error", "path": str(file), "error": str(error)}
            return {"status": "success", "path": str(file), "format": "text",
                    "encoding": encoding, "content": content}
        return read_file

    def write_filesystem_file(_: Any) -> Any:
        async def write_file(path: str, content: Any, create_parents: bool = False,
                             encoding: str = "utf-8") -> dict[str, Any]:
            file = resolve(path)
            try:
                if file.suffix.casefold() in SUPPORTED:
                    return await asyncio.to_thread(
                        write_document, file, content, create_parents
                    )
                if not isinstance(content, str):
                    return {"status": "error", "path": str(file),
                            "error": "Text file content must be a string."}
                def write() -> None:
                    if create_parents:
                        file.parent.mkdir(parents=True, exist_ok=True)
                    file.write_text(content, encoding=encoding)
                await asyncio.to_thread(write)
            except Exception as error:
                return {"status": "error", "path": str(file), "error": str(error)}
            return {"status": "written", "path": str(file), "format": "text",
                    "characters": len(content)}
        return write_file

    def create_filesystem_file(_: Any) -> Any:
        async def create_file(path: str, content: str = "", create_parents: bool = False,
                              encoding: str = "utf-8") -> dict[str, Any]:
            file = resolve(path)
            def create() -> None:
                if create_parents:
                    file.parent.mkdir(parents=True, exist_ok=True)
                with file.open("x", encoding=encoding) as stream:
                    stream.write(content)
            await asyncio.to_thread(create)
            return {"status": "created", "path": str(file), "characters": len(content)}
        return create_file

    def create_filesystem_directory(_: Any) -> Any:
        async def create_directory(path: str, create_parents: bool = False) -> dict[str, Any]:
            directory = resolve(path)
            await asyncio.to_thread(directory.mkdir, parents=create_parents, exist_ok=False)
            return {"status": "created", **_summary(directory)}
        return create_directory

    def delete_filesystem_path(_: Any) -> Any:
        async def delete_path(path: str, recursive: bool = False) -> dict[str, str]:
            target = resolve(path)
            def delete() -> None:
                if target.is_symlink() or target.is_file():
                    target.unlink()
                elif target.is_dir():
                    shutil.rmtree(target) if recursive else target.rmdir()
                else:
                    raise FileNotFoundError(target)
            await asyncio.to_thread(delete)
            return {"status": "deleted", "path": str(target)}
        return delete_path

    def move_filesystem_path(_: Any) -> Any:
        async def move_path(source: str, destination: str, create_parents: bool = False) -> dict[str, str]:
            origin, target = resolve(source), resolve(destination)
            def move() -> None:
                if create_parents:
                    target.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(origin), str(target))
            await asyncio.to_thread(move)
            return {"status": "moved", "source": str(origin), "destination": str(target)}
        return move_path

    def copy_filesystem_path(_: Any) -> Any:
        async def copy_path(source: str, destination: str, create_parents: bool = False) -> dict[str, str]:
            origin, target = resolve(source), resolve(destination)
            def copy() -> None:
                if create_parents:
                    target.parent.mkdir(parents=True, exist_ok=True)
                if origin.is_dir():
                    # Scoped copies keep links as links so a link inside a shared folder
                    # cannot pull outside content into it.
                    shutil.copytree(origin, target, symlinks=scoped)
                else:
                    shutil.copy2(origin, target)
            await asyncio.to_thread(copy)
            return {"status": "copied", "source": str(origin), "destination": str(target)}
        return copy_path

    return [
        ("filesystem", "list_filesystem_directory", "List any directory path; not limited to workspace folders.", list_filesystem_directory),
        ("filesystem", "read_filesystem_file", "Read a file at any path. Supports UTF-8 text files with any extension, plus PDF (.pdf), Word (.docx), Excel (.xlsx), and PowerPoint (.pptx). PDF/Office files return structured extracted text, pages, paragraphs, tables, sheets, cells, or slides; scanned PDFs require OCR and may contain no extractable text. Other binary formats are unsupported.", read_filesystem_file),
        ("filesystem", "write_filesystem_file", "Create or overwrite a file at any path. Supports UTF-8 text files with any extension, plus generated PDF (.pdf), Word (.docx), Excel (.xlsx), and PowerPoint (.pptx) documents. Document content may be plain text or the structured result from read_filesystem_file; advanced source formatting and embedded media are not preserved.", write_filesystem_file),
        ("filesystem", "create_filesystem_file", "Create a new text file at any path.", create_filesystem_file),
        ("filesystem", "create_filesystem_directory", "Create a directory at any path.", create_filesystem_directory),
        ("filesystem", "delete_filesystem_path", "Delete a file, link, or directory at any path.", delete_filesystem_path),
        ("filesystem", "move_filesystem_path", "Move a file or directory between any paths.", move_filesystem_path),
        ("filesystem", "copy_filesystem_path", "Copy a file or directory between any paths.", copy_filesystem_path),
    ]
