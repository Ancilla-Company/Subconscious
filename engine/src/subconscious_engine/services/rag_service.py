"""Workspace-scoped composition over local semantic RAG sidecars."""

from __future__ import annotations

import asyncio
from dataclasses import asdict, dataclass
import json
import logging
import os
from pathlib import Path
import sqlite3
import time
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from subconscious_engine.configuration import (
    EncryptedModelConfigurationStore, ModelConfigurationStoreError,
)
from subconscious_engine.configuration.models import ModelConfig
from subconscious_engine.rag import (
    EmbeddingError, HashingEmbedder, OpenAIEmbedder, SIDECAR_DIRNAME,
    SidecarStore, WorkspaceIndexer, WorkspaceRetriever,
)
from subconscious_engine.storage.models import Workspace

_LOGGER = logging.getLogger(__name__)
_DAY_SECONDS = 24 * 60 * 60
_DEFAULT_OPENAI_BASE = "https://api.openai.com/v1"
_DEFAULT_EMBEDDING_MODEL = "text-embedding-3-small"
_DEFAULT_EMBEDDING_DIMENSIONS = 1536


class RagServiceError(RuntimeError):
    def __init__(self, status_code: int, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code


@dataclass(frozen=True, slots=True)
class _Root:
    index: int
    original_path: str
    path: Path
    enabled: bool


class WorkspaceRagService:
    def __init__(self, configuration_store: EncryptedModelConfigurationStore | None = None) -> None:
        self.configuration_store = configuration_store
        self._root_locks: dict[str, asyncio.Lock] = {}

    async def _workspace(self, session: AsyncSession, workspace_uuid: str) -> Workspace:
        workspace = await session.scalar(
            select(Workspace).where(Workspace.uuid == workspace_uuid)
        )
        if workspace is None:
            raise RagServiceError(404, "The requested workspace does not exist.")
        return workspace

    async def _root_specs(self, session: AsyncSession, workspace_uuid: str) -> tuple[Workspace, list[_Root]]:
        workspace = await self._workspace(session, workspace_uuid)
        try:
            values = json.loads(workspace.directories) if workspace.directories else []
        except (TypeError, json.JSONDecodeError) as error:
            raise RagServiceError(400, "Workspace directories must be valid JSON.") from error
        if not isinstance(values, list):
            raise RagServiceError(400, "Workspace directories must be a JSON array.")

        disabled_paths: set[str] = set()
        try:
            rag_config = json.loads(workspace.rag_config) if workspace.rag_config else {}
        except (TypeError, json.JSONDecodeError):
            rag_config = {}
        if isinstance(rag_config, dict):
            configured_roots = rag_config.get("roots")
            if isinstance(configured_roots, list):
                for configured in configured_roots:
                    if isinstance(configured, dict) and isinstance(configured.get("path"), str) \
                            and configured.get("enabled") is False:
                        disabled_paths.add(self._path_key(configured["path"]))

        roots: list[_Root] = []
        for index, value in enumerate(values):
            if not isinstance(value, str):
                raise RagServiceError(400, "Workspace roots must be absolute directory paths.")
            root = Path(value).expanduser()
            junction = getattr(root, "is_junction", lambda: False)
            if not root.is_absolute() or not root.is_dir() or root.is_symlink() or junction():
                raise RagServiceError(
                    400, "Workspace roots must be existing, non-reparse absolute directories."
                )
            resolved = root.resolve()
            roots.append(_Root(index, value, resolved, self._path_key(resolved) not in disabled_paths))
        return workspace, roots

    @staticmethod
    def _path_key(path: str | Path) -> str:
        try:
            resolved = Path(path).expanduser().resolve(strict=False)
        except (OSError, RuntimeError):
            resolved = Path(path).expanduser()
        return os.path.normcase(os.path.normpath(str(resolved)))

    async def roots(self, session: AsyncSession, workspace_uuid: str) -> list[Path]:
        _, roots = await self._root_specs(session, workspace_uuid)
        return [root.path for root in roots]

    def _lock(self, root: Path) -> asyncio.Lock:
        return self._root_locks.setdefault(os.path.normcase(str(root)), asyncio.Lock())

    @staticmethod
    def _rag_config(workspace: Workspace) -> dict[str, Any]:
        try:
            value = json.loads(workspace.rag_config) if workspace.rag_config else {}
        except (TypeError, json.JSONDecodeError):
            return {}
        return value if isinstance(value, dict) else {}

    @staticmethod
    def _dimensions() -> int:
        raw = os.environ.get("OPENAI_EMBEDDING_DIMENSIONS")
        if raw is None:
            return _DEFAULT_EMBEDDING_DIMENSIONS
        try:
            dimensions = int(raw)
        except ValueError as error:
            raise RagServiceError(503, "OpenAI embedding dimensions are invalid.") from error
        if dimensions <= 0:
            raise RagServiceError(503, "OpenAI embedding dimensions are invalid.")
        return dimensions

    def _openai_embedder(self, config: ModelConfig, workspace: Workspace) -> OpenAIEmbedder:
        rag_config = self._rag_config(workspace)
        configured_model = rag_config.get("embeddingModel")
        model = configured_model.strip() if isinstance(configured_model, str) else ""
        try:
            return OpenAIEmbedder(
                config.api_key or "",
                base_url=config.base_url or _DEFAULT_OPENAI_BASE,
                model=model or os.environ.get(
                    "OPENAI_EMBEDDING_MODEL", _DEFAULT_EMBEDDING_MODEL
                ),
                dimensions=self._dimensions(),
            )
        except ValueError as error:
            raise RagServiceError(503, "OpenAI embedding configuration is invalid.") from error

    async def _embedder(self, workspace: Workspace):
        if self.configuration_store is None:
            return HashingEmbedder()
        environment_key = os.environ.get("OPENAI_API_KEY")
        if environment_key:
            try:
                return OpenAIEmbedder(
                    environment_key,
                    base_url=os.environ.get("OPENAI_BASE_URL", _DEFAULT_OPENAI_BASE),
                    model=os.environ.get("OPENAI_EMBEDDING_MODEL", _DEFAULT_EMBEDDING_MODEL),
                    dimensions=self._dimensions(),
                )
            except ValueError as error:
                raise RagServiceError(503, "OpenAI embedding configuration is invalid.") from error

        try:
            rag_config = self._rag_config(workspace)
            configured_id = rag_config.get("modelConfigurationId")
            if isinstance(configured_id, str) and configured_id:
                configured = await self.configuration_store.resolve(configured_id)
                if configured and configured.provider.casefold() == "openai" and configured.api_key:
                    return self._openai_embedder(configured, workspace)

            if workspace.default_model_id:
                default = await self.configuration_store.resolve(workspace.default_model_id)
                if default and default.provider.casefold() == "openai" and default.api_key:
                    return self._openai_embedder(default, workspace)

            for item in await self.configuration_store.list():
                if item.provider.casefold() != "openai" or not item.has_api_key:
                    continue
                configured = await self.configuration_store.resolve(item.id)
                if configured and configured.provider.casefold() == "openai" and configured.api_key:
                    return self._openai_embedder(configured, workspace)
        except ModelConfigurationStoreError as error:
            raise RagServiceError(503, "Model credentials are unavailable.") from error
        raise RagServiceError(
            503, "Semantic RAG requires an OpenAI API key or OpenAI model configuration."
        )

    async def _index_spec(self, workspace: Workspace, root: _Root,
                          *, only_if_due: bool = False) -> dict[str, Any] | None:
        async with self._lock(root.path):
            if only_if_due and not self._is_due(root.path):
                return None
            embedder = await self._embedder(workspace)
            try:
                async with WorkspaceIndexer(root.path, embedder=embedder) as indexer:
                    summary = await indexer.index(only_changed=True)
            except EmbeddingError as error:
                raise RagServiceError(503, str(error)) from error
        return {"rootIndex": root.index, **asdict(summary)}

    async def index(self, session: AsyncSession, workspace_uuid: str) -> dict[str, Any]:
        workspace, roots = await self._root_specs(session, workspace_uuid)
        summaries: list[dict[str, Any]] = []
        for root in roots:
            if not root.enabled:
                continue
            summary = await self._index_spec(workspace, root)
            if summary is not None:
                summaries.append(summary)
        return {"roots": summaries}

    async def index_root(self, session: AsyncSession, workspace_uuid: str,
                         root_index: int) -> dict[str, Any]:
        workspace, roots = await self._root_specs(session, workspace_uuid)
        if root_index < 0 or root_index >= len(roots):
            raise RagServiceError(404, "The requested workspace root does not exist.")
        root = roots[root_index]
        if not root.enabled:
            raise RagServiceError(409, "The requested workspace root is disabled for RAG.")
        result = await self._index_spec(workspace, root)
        assert result is not None
        return result

    async def search(self, session: AsyncSession, workspace_uuid: str, query: str,
                     mode: str = "hybrid", limit: int = 8) -> list[dict[str, Any]]:
        if mode not in {"keyword", "vector", "hybrid"}:
            raise RagServiceError(400, "RAG mode must be keyword, vector, or hybrid.")
        workspace, roots = await self._root_specs(session, workspace_uuid)
        embedder = await self._embedder(workspace) if mode in {"vector", "hybrid"} else None
        combined: list[dict[str, Any]] = []
        for root in roots:
            if not root.enabled:
                continue
            db_path = root.path / SIDECAR_DIRNAME / "sidecar.db"
            if not db_path.is_file():
                continue
            store = SidecarStore.open_readonly(root.path)
            if store is None:
                continue
            if embedder is not None:
                try:
                    signature = store.get_metadata("embedding_signature")
                except sqlite3.Error:
                    signature = None
                if signature != embedder.name:
                    store.close()
                    continue
            retriever = WorkspaceRetriever(root.path, embedder=embedder, store=store)
            try:
                results = await retriever.search(
                    query, limit=limit, mode=mode, graph_fallback=False  # type: ignore[arg-type]
                )
            except EmbeddingError as error:
                raise RagServiceError(503, str(error)) from error
            finally:
                store.close()
            for result in results:
                if WorkspaceIndexer._is_sensitive(str(result.get("path", ""))):
                    path = str(result.get("path", ""))
                    result = {
                        **result,
                        "content": (
                            f"Sensitive file exists at {path}; its content was deliberately excluded."
                        ),
                        "start_line": None,
                        "end_line": None,
                        "status": "metadata_only",
                        "sensitive": True,
                        "metadata_only": True,
                    }
                combined.append({**result, "rootIndex": root.index})
        combined.sort(key=lambda item: (-float(item.get("score", 0.0)),
                                        int(item.get("rootIndex", 0)), str(item.get("path", ""))))
        return combined[:limit]

    @staticmethod
    def _is_due(root: Path, now: float | None = None) -> bool:
        store = SidecarStore.open_readonly(root)
        if store is None:
            return True
        try:
            raw = store.get_metadata("last_indexed_at")
        except (sqlite3.Error, ValueError):
            return True
        finally:
            store.close()
        if raw is None:
            return True
        try:
            return (now if now is not None else time.time()) - float(raw) >= _DAY_SECONDS
        except ValueError:
            return True

    async def index_due(self, database: Any) -> None:
        async with database.session() as session:
            workspace_ids = list(await session.scalars(select(Workspace.uuid)))
        for workspace_uuid in workspace_ids:
            try:
                async with database.session() as session:
                    workspace, roots = await self._root_specs(session, workspace_uuid)
                for root in roots:
                    if not root.enabled or not self._is_due(root.path):
                        continue
                    try:
                        await self._index_spec(workspace, root, only_if_due=True)
                    except Exception as error:
                        _LOGGER.warning(
                            "Scheduled RAG indexing failed for workspace %s root %d: %s",
                            workspace_uuid, root.index, error,
                        )
            except Exception as error:
                _LOGGER.warning("Scheduled RAG scan failed for workspace %s: %s", workspace_uuid, error)

    async def run_daily_indexing(self, database: Any) -> None:
        while True:
            try:
                await self.index_due(database)
            except Exception as error:
                _LOGGER.warning("Scheduled RAG scan failed: %s", error)
            await asyncio.sleep(_DAY_SECONDS)
