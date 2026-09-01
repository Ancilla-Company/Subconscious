"""Workspace-scoped composition over local RAG sidecars."""

from dataclasses import asdict
import json
from pathlib import Path
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from subconscious_engine.rag import SIDECAR_DIRNAME, SidecarStore, WorkspaceIndexer, WorkspaceRetriever
from subconscious_engine.storage.models import Workspace


class RagServiceError(RuntimeError):
    def __init__(self, status_code: int, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code


class WorkspaceRagService:
    async def roots(self, session: AsyncSession, workspace_uuid: str) -> list[Path]:
        raw = await session.scalar(select(Workspace.directories).where(Workspace.uuid == workspace_uuid))
        if raw is None:
            raise RagServiceError(404, "The requested workspace does not exist.")
        try:
            values = json.loads(raw) if raw else []
        except json.JSONDecodeError as error:
            raise RagServiceError(400, "Workspace directories must be valid JSON.") from error
        if not isinstance(values, list):
            raise RagServiceError(400, "Workspace directories must be a JSON array.")
        roots: list[Path] = []
        for value in values:
            if not isinstance(value, str):
                raise RagServiceError(400, "Workspace roots must be absolute directory paths.")
            root = Path(value).expanduser()
            junction = getattr(root, "is_junction", lambda: False)
            if not root.is_absolute() or not root.is_dir() or root.is_symlink() or junction():
                raise RagServiceError(400, "Workspace roots must be existing, non-reparse absolute directories.")
            roots.append(root.resolve())
        return roots

    async def index(self, session: AsyncSession, workspace_uuid: str) -> dict[str, Any]:
        summaries: list[dict[str, Any]] = []
        for root_index, root in enumerate(await self.roots(session, workspace_uuid)):
            async with WorkspaceIndexer(root) as indexer:
                summary = await indexer.index(only_changed=True)
            summaries.append({"rootIndex": root_index, **asdict(summary)})
        return {"roots": summaries}

    async def search(self, session: AsyncSession, workspace_uuid: str, query: str,
                     mode: str = "hybrid", limit: int = 8) -> list[dict[str, Any]]:
        if mode not in {"keyword", "vector", "hybrid", "graph"}:
            raise RagServiceError(400, "RAG mode must be keyword, vector, hybrid, or graph.")
        combined: list[dict[str, Any]] = []
        for root_index, root in enumerate(await self.roots(session, workspace_uuid)):
            db_path = root / SIDECAR_DIRNAME / "sidecar.db"
            if not db_path.is_file():
                continue
            store = SidecarStore.open_readonly(root)
            if store is None:
                continue
            retriever = WorkspaceRetriever(root, store=store)
            try:
                results = await retriever.search(query, limit=limit, mode=mode)  # type: ignore[arg-type]
            finally:
                store.close()
            for result in results:
                combined.append({**result, "rootIndex": root_index})
        combined.sort(key=lambda item: (-float(item.get("score", 0.0)),
                                        int(item.get("rootIndex", 0)), str(item.get("path", ""))))
        return combined[:limit]
