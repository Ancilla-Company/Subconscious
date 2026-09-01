"""Dependency-free workspace retrieval-augmented generation support."""

from .embeddings import Embedder, HashingEmbedder, cosine_similarity
from .indexing import IndexSummary, WorkspaceIndexer
from .retrieval import WorkspaceRetriever
from .sidecar import SIDECAR_DIRNAME, SidecarStore

__all__ = [
    "Embedder",
    "HashingEmbedder",
    "IndexSummary",
    "SIDECAR_DIRNAME",
    "SidecarStore",
    "WorkspaceIndexer",
    "WorkspaceRetriever",
    "cosine_similarity",
]
