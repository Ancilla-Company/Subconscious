"""Async-facing keyword, vector, hybrid, and graph workspace retrieval."""

from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Any, Literal

from .embeddings import Embedder, HashingEmbedder
from .sidecar import SidecarStore

SearchMode = Literal["keyword", "vector", "hybrid", "graph"]


class WorkspaceRetriever:
    """Retrieve ranked chunks from a workspace's local sidecar."""

    def __init__(
        self,
        root: str | Path,
        embedder: Embedder | None = None,
        store: SidecarStore | None = None,
    ) -> None:
        self.embedder = embedder or HashingEmbedder()
        self.store = store or SidecarStore(root, create=False)
        self._owns_store = store is None

    async def search(
        self,
        query: str,
        limit: int = 20,
        mode: SearchMode = "hybrid",
        min_similarity: float = 0.0,
        graph_fallback: bool = True,
    ) -> list[dict[str, Any]]:
        """Search without blocking the event loop."""
        return await asyncio.to_thread(
            self.search_sync,
            query,
            limit,
            mode,
            min_similarity,
            graph_fallback,
        )

    def search_sync(
        self,
        query: str,
        limit: int = 20,
        mode: SearchMode = "hybrid",
        min_similarity: float = 0.0,
        graph_fallback: bool = True,
    ) -> list[dict[str, Any]]:
        query = query.strip()
        if not query or limit <= 0:
            return []

        if mode == "keyword":
            results = self.store.keyword_search(query, limit)
        elif mode == "vector":
            vector = self.embedder.embed(query)
            results = self.store.vector_search(vector, limit, min_similarity)
        elif mode == "hybrid":
            vector = self.embedder.embed(query)
            results = self.store.hybrid_search(
                query,
                vector,
                limit,
                min_similarity=min_similarity,
            )
        elif mode == "graph":
            return self.graph_search_sync(query, limit=limit)
        else:
            raise ValueError(f"unsupported search mode: {mode}")
        if results or not graph_fallback:
            return results
        return self.store.graph_search(query, limit=limit)

    async def keyword_search(self, query: str, limit: int = 20) -> list[dict[str, Any]]:
        return await asyncio.to_thread(self.store.keyword_search, query, limit)

    async def vector_search(
        self,
        query: str,
        limit: int = 20,
        min_similarity: float = 0.0,
    ) -> list[dict[str, Any]]:
        vector = await asyncio.to_thread(self.embedder.embed, query)
        return await asyncio.to_thread(
            self.store.vector_search,
            vector,
            limit,
            min_similarity,
        )

    async def hybrid_search(
        self,
        query: str,
        limit: int = 20,
        min_similarity: float = 0.0,
    ) -> list[dict[str, Any]]:
        vector = await asyncio.to_thread(self.embedder.embed, query)
        return await asyncio.to_thread(
            self.store.hybrid_search,
            query,
            vector,
            limit,
            60,
            min_similarity,
        )

    async def graph_search(
        self,
        query: str,
        depth: int = 2,
        limit: int = 20,
    ) -> list[dict[str, Any]]:
        return await asyncio.to_thread(self.graph_search_sync, query, depth, limit)

    def graph_search_sync(
        self,
        query: str,
        depth: int = 2,
        limit: int = 20,
    ) -> list[dict[str, Any]]:
        """Search graph nodes; fall back to hybrid chunks when no node matches."""
        graph_results = self.store.graph_search(query, depth=depth, limit=limit)
        if graph_results:
            return graph_results
        vector = self.embedder.embed(query)
        return self.store.hybrid_search(query, vector, limit)

    async def list_documents(self) -> list[dict[str, Any]]:
        return await asyncio.to_thread(self.store.list_documents)

    async def get_document_chunks(self, path: str) -> list[dict[str, Any]]:
        document = await asyncio.to_thread(self.store.get_document, path)
        if not document:
            return []
        return await asyncio.to_thread(self.store.get_chunks, int(document["id"]))

    async def close(self) -> None:
        if self._owns_store:
            await self.store.aclose()

    async def __aenter__(self) -> WorkspaceRetriever:
        return self

    async def __aexit__(self, *_: object) -> None:
        await self.close()
