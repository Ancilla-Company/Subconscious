"""Asynchronous-facing workspace file indexing."""

from __future__ import annotations

import asyncio
import hashlib
import logging
import os
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from .embeddings import Embedder, HashingEmbedder
from .sidecar import SIDECAR_DIRNAME, SidecarStore

_LOGGER = logging.getLogger(__name__)
_MAX_CHARACTERS: Final = 500_000
_CHUNK_CHARACTERS: Final = 1_500
_CHUNK_TOKENS: Final = 500
_SENSITIVE_EXTENSIONS: Final = frozenset({
    ".pem", ".key", ".p12", ".pfx", ".jks", ".keystore", ".kdbx",
})
_SENSITIVE_FILENAMES: Final = frozenset({
    ".env", ".git-credentials", ".netrc", "_netrc", ".npmrc", ".pypirc",
    "auth.json", "credentials", "credentials.json", "service-account.json",
})
_SENSITIVE_NAME: Final = re.compile(
    r"(?:secret|credential|private[-_. ]?key|api[-_. ]?key|service[-_. ]?account)",
    re.IGNORECASE,
)
_SSH_PRIVATE_NAME: Final = re.compile(
    r"^(?:id_(?:rsa|dsa|ecdsa|ed25519)(?:_sk)?|identity|"
    r"ssh_host_(?:rsa|dsa|ecdsa|ed25519)_key)$", re.IGNORECASE,
)
_DEFAULT_SKIPS: Final = frozenset(
    {
        SIDECAR_DIRNAME,
        ".git",
        ".hg",
        ".svn",
        ".idea",
        ".vscode",
        ".venv",
        "venv",
        "__pycache__",
        "node_modules",
        ".mypy_cache",
        ".pytest_cache",
        ".hypothesis",
        "bin",
        "obj",
        "build",
        "dist",
    }
)


@dataclass(frozen=True, slots=True)
class IndexSummary:
    indexed: int
    unchanged: int
    skipped: int
    errors: int
    removed: int


class WorkspaceIndexer:
    """Index text files under one workspace root into its sidecar."""

    def __init__(
        self,
        root: str | Path,
        embedder: Embedder | None = None,
        store: SidecarStore | None = None,
        skip_patterns: set[str] | None = None,
    ) -> None:
        self.root = Path(root).expanduser().resolve()
        self.embedder = embedder or HashingEmbedder()
        self.store = store or SidecarStore(self.root)
        self._owns_store = store is None
        self.skip_patterns = {part.casefold() for part in _DEFAULT_SKIPS}
        if skip_patterns:
            self.skip_patterns.update(part.casefold() for part in skip_patterns)

    async def index_directory(self, only_changed: bool = True) -> IndexSummary:
        """Index the workspace on a worker thread."""
        return await asyncio.to_thread(self.index_directory_sync, only_changed)

    async def index(self, only_changed: bool = True) -> IndexSummary:
        return await self.index_directory(only_changed)

    def index_directory_sync(self, only_changed: bool = True) -> IndexSummary:
        if not self.root.is_dir():
            raise NotADirectoryError(self.root)
        signature = self.embedder.name
        if self.store.get_metadata("embedding_signature") != signature:
            only_changed = False
        indexed = unchanged = skipped = errors = 0
        seen: set[str] = set()
        for path in self._walk():
            rel_path = path.relative_to(self.root).as_posix()
            seen.add(rel_path)
            try:
                outcome = self._index_file(path, rel_path, only_changed)
            except (OSError, UnicodeError, ValueError) as exc:
                errors += 1
                self.store.mark_document_error(rel_path, str(exc))
                _LOGGER.warning("Could not index %s: %s", path, exc)
                continue
            if outcome == "indexed":
                indexed += 1
            elif outcome == "unchanged":
                unchanged += 1
            else:
                skipped += 1
        removed = self.store.prune_documents(seen)
        self.store.set_metadata("embedding_signature", signature)
        self.store.set_metadata("last_indexed_at", str(int(time.time())))
        return IndexSummary(indexed, unchanged, skipped, errors, removed)

    def _walk(self):
        for directory, dirnames, filenames in os.walk(self.root, followlinks=False):
            base = Path(directory)
            dirnames[:] = [
                name
                for name in dirnames
                if name.casefold() not in self.skip_patterns
                and not (base / name).is_symlink()
            ]
            for name in filenames:
                path = base / name
                if name.casefold() in self.skip_patterns or path.is_symlink():
                    continue
                yield path

    def _index_file(self, path: Path, rel_path: str, only_changed: bool) -> str:
        stat = path.stat()
        directory = Path(rel_path).parent.as_posix()
        if directory == ".":
            directory = ""
        if self._is_sensitive(rel_path):
            digest = hashlib.sha256(
                f"{stat.st_size}:{stat.st_mtime_ns}".encode("ascii")
            ).hexdigest()
            existing = self.store.get_document(rel_path)
            if only_changed and existing and existing.get("content_hash") == digest:
                return "unchanged"
            placeholder = (
                f"Sensitive file exists at {rel_path}; its content was deliberately excluded."
            )
            self.store.replace_document(
                rel_path, directory, stat.st_size, int(stat.st_mtime), digest,
                [(placeholder, None, None, max(1, (len(placeholder) + 3) // 4))],
                self.embedder.embed_batch([placeholder]), status="metadata_only",
            )
            return "indexed"

        raw = path.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        existing = self.store.get_document(rel_path)
        if only_changed and existing and existing.get("content_hash") == digest:
            return "unchanged"
        text = raw.decode("utf-8", errors="replace")
        if len(text) > _MAX_CHARACTERS:
            self.store.replace_document(
                rel_path,
                directory,
                stat.st_size,
                int(stat.st_mtime),
                digest,
                [],
                [],
                status="skipped",
                error="More than 500000 characters",
            )
            return "skipped"
        nul_count = text.count("\0")
        if text and nul_count / len(text) > 0.10:
            self.store.replace_document(
                rel_path,
                directory,
                stat.st_size,
                int(stat.st_mtime),
                digest,
                [],
                [],
                status="skipped",
                error="More than 10% NUL characters",
            )
            return "skipped"
        chunks = self.chunk_text(text)
        vectors = self.embedder.embed_batch([chunk[0] for chunk in chunks])
        self.store.replace_document(
            rel_path,
            directory,
            stat.st_size,
            int(stat.st_mtime),
            digest,
            chunks,
            vectors,
        )
        return "indexed"

    @staticmethod
    def _is_sensitive(rel_path: str) -> bool:
        path = Path(rel_path)
        folded_parts = [part.casefold() for part in path.parts]
        filename = folded_parts[-1] if folded_parts else ""
        if filename in _SENSITIVE_FILENAMES or filename.startswith(".env."):
            return True
        if path.suffix.casefold() in _SENSITIVE_EXTENSIONS:
            return True
        if _SSH_PRIVATE_NAME.fullmatch(filename):
            return True
        if len(folded_parts) >= 2 and folded_parts[-2:] == [".docker", "config.json"]:
            return True
        return any(_SENSITIVE_NAME.search(part) for part in folded_parts)

    @staticmethod
    def chunk_text(text: str) -> list[tuple[str, int, int, int]]:
        """Build chunks on line boundaries with inclusive, one-based line ranges."""
        if not text:
            return []
        lines = text.splitlines(keepends=True)
        if not lines:
            lines = [text]
        chunks: list[tuple[str, int, int, int]] = []
        current: list[str] = []
        start_line = 1
        characters = tokens = 0

        def flush(end_line: int) -> None:
            nonlocal current, characters, tokens
            if not current:
                return
            content = "".join(current).rstrip("\r\n")
            if content:
                chunks.append((content, start_line, end_line, max(1, tokens)))
            current = []
            characters = tokens = 0

        for line_number, line in enumerate(lines, start=1):
            line_tokens = max(1, (len(line) + 3) // 4)
            if current and (
                characters + len(line) > _CHUNK_CHARACTERS
                or tokens + line_tokens > _CHUNK_TOKENS
            ):
                flush(line_number - 1)
                start_line = line_number
            current.append(line)
            characters += len(line)
            tokens += line_tokens
        flush(len(lines))
        return chunks

    def close(self) -> None:
        if self._owns_store:
            self.store.close()

    async def aclose(self) -> None:
        if self._owns_store:
            await self.store.aclose()

    async def __aenter__(self) -> WorkspaceIndexer:
        return self

    async def __aexit__(self, *_: object) -> None:
        await self.aclose()
