""" Retrieval-Augmented Generation (RAG) subsystem.

This package holds the workspace indexing + retrieval stack:

  * :mod:`embeddings`  – pluggable, offline-first text embedder.
  * :mod:`sidecar`     – per-directory ``.subconscious/<workspace_uuid>/index.db``
                         SQLite store (documents, chunks, vectors, knowledge graph).
  * :mod:`graph`       – structural + semantic knowledge-graph extraction.
  * :mod:`retrieval`   – hybrid (keyword + vector) search and GraphRAG expansion.

The indexer itself lives in :mod:`subconscious.indexing` and drives these
components synchronously inside a worker thread so the asyncio event loop (and
therefore the UI) is never blocked.
"""
from .embeddings import Embedder, HashingEmbedder, get_default_embedder
from .sidecar import SidecarStore, SIDECAR_DIRNAME
from .retrieval import WorkspaceRetriever

__all__ = [
  "Embedder",
  "HashingEmbedder",
  "get_default_embedder",
  "SidecarStore",
  "SIDECAR_DIRNAME",
  "WorkspaceRetriever",
]
