""" Hybrid retrieval + GraphRAG across a workspace's per-directory sidecars.

A workspace can have several attached directories, each with its own sidecar
store. The retriever fans out across them, runs keyword and vector search in
each, merges and re-ranks the results, and rehydrates relative paths back to
absolute ones. All of this is synchronous SQLite work, intended to be driven
from an executor thread by the engine so the event loop stays free.
"""
from __future__ import annotations

import logging
from pathlib import Path
from typing import Optional, Sequence

from .embeddings import Embedder
from .sidecar import SidecarStore


logger = logging.getLogger("subconscious")


class WorkspaceRetriever:
  """Search across every sidecar attached to a workspace."""

  def __init__(self, embedder: Embedder, cache_dir: Optional[str] = None):
    self.embedder = embedder
    # Fallback sidecar location for directories that were indexed to the central
    # cache because they aren't writable in place.
    self.cache_dir = cache_dir

  # ------------------------------------------------------------------
  # Public (synchronous — run me in an executor thread)
  # ------------------------------------------------------------------

  def search(
    self,
    workspace_uuid: str,
    directories: Sequence[str],
    query: str,
    limit: int = 8,
    mode: str = "hybrid",
  ) -> list[dict]:
    """Return the top *limit* chunks for *query* across all directories.

    *mode* is one of ``"keyword"``, ``"vector"`` or ``"hybrid"`` (default).
    """
    if not query or not query.strip() or not directories:
      return []

    query_vec = self.embedder.embed(query) if mode in ("vector", "hybrid") else []
    q_tokens = {t for t in query.lower().split() if t}

    merged: dict[tuple[str, int], dict] = {}
    for d in directories:
      root = Path(d)
      store = SidecarStore.open_readonly(root, workspace_uuid, self.embedder.name, self.cache_dir)
      if store is None:
        continue
      try:
        self._collect(store, root, query, query_vec, q_tokens, limit, mode, merged)
      except Exception as exc:  # a corrupt/locked sidecar must not sink the whole search
        logger.warning("Search failed for sidecar %s: %s", root, exc)
      finally:
        store.close()

    results = sorted(merged.values(), key=lambda r: r["score"], reverse=True)
    return results[:limit]

  def graph_search(
    self,
    workspace_uuid: str,
    directories: Sequence[str],
    query: str,
    limit: int = 6,
  ) -> dict:
    """GraphRAG: seed with hybrid search, then expand along the knowledge graph.

    Returns ``{"seeds": [...chunks...], "related": [...chunks...],
    "graph": {"nodes": [...], "edges": [...]}}``.
    """
    seeds = self.search(workspace_uuid, directories, query, limit=limit, mode="hybrid")
    related: list[dict] = []
    all_nodes: list[dict] = []
    all_edges: list[dict] = []

    # Group seed documents per directory so we expand within the right sidecar.
    by_dir: dict[str, set[int]] = {}
    for s in seeds:
      by_dir.setdefault(s["_dir"], set()).add(s["document_id"])

    seen_chunks = {(s["_dir"], s["chunk_id"]) for s in seeds}
    for d, doc_ids in by_dir.items():
      root = Path(d)
      store = SidecarStore.open_readonly(root, workspace_uuid, self.embedder.name, self.cache_dir)
      if store is None:
        continue
      try:
        node_ids: list[int] = []
        for doc_id in doc_ids:
          node_ids.extend(store.nodes_for_document(doc_id, limit=15))
        node_ids = list(dict.fromkeys(node_ids))  # dedupe, keep order
        if not node_ids:
          continue
        hood = store.neighbors(node_ids, limit=40)
        all_nodes.extend(hood["nodes"])
        all_edges.extend(hood["edges"])
        neighbor_ids = [n["id"] for n in hood["nodes"]]
        for ch in store.chunks_for_nodes(neighbor_ids, limit=limit):
          key = (d, ch["chunk_id"])
          if key in seen_chunks:
            continue
          seen_chunks.add(key)
          ch["path"] = str(root / ch["rel_path"])
          ch["_dir"] = d
          related.append(ch)
      except Exception as exc:
        logger.warning("Graph expansion failed for sidecar %s: %s", root, exc)
      finally:
        store.close()

    return {
      "seeds": seeds,
      "related": related[:limit],
      "graph": {"nodes": all_nodes, "edges": all_edges},
    }

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  def _collect(
    self,
    store: SidecarStore,
    root: Path,
    query: str,
    query_vec: list[float],
    q_tokens: set[str],
    limit: int,
    mode: str,
    merged: dict,
  ) -> None:
    dir_str = str(root)

    if mode in ("keyword", "hybrid"):
      for r in store.search_keyword(query, limit * 2):
        kw = self._keyword_score(r["content"], q_tokens)
        self._merge(merged, dir_str, root, r, kw_score=kw, vec_score=0.0)

    if mode in ("vector", "hybrid"):
      for r in store.search_vector(query_vec, limit * 2):
        self._merge(merged, dir_str, root, r, kw_score=0.0, vec_score=r["score"])

  @staticmethod
  def _keyword_score(content: str, q_tokens: set[str]) -> float:
    if not q_tokens:
      return 0.0
    low = content.lower()
    hits = sum(1 for t in q_tokens if t in low)
    return hits / len(q_tokens)

  @staticmethod
  def _merge(merged: dict, dir_str: str, root: Path, row: dict, kw_score: float, vec_score: float) -> None:
    key = (dir_str, row["chunk_id"])
    existing = merged.get(key)
    # Hybrid score: even split of keyword coverage and vector similarity.
    score = 0.5 * kw_score + 0.5 * vec_score
    if existing:
      existing["kw_score"] = max(existing["kw_score"], kw_score)
      existing["vec_score"] = max(existing["vec_score"], vec_score)
      existing["score"] = 0.5 * existing["kw_score"] + 0.5 * existing["vec_score"]
      return
    merged[key] = {
      "chunk_id": row["chunk_id"],
      "document_id": row["document_id"],
      "path": str(root / row["rel_path"]),
      "rel_path": row["rel_path"],
      "start_line": row.get("start_line"),
      "end_line": row.get("end_line"),
      "content": row["content"],
      "kw_score": kw_score,
      "vec_score": vec_score,
      "score": score,
      "_dir": dir_str,
    }
