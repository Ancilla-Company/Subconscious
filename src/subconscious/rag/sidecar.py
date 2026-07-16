""" Per-directory sidecar store """
from __future__ import annotations

import os
import json
import time
import shutil
import hashlib
import sqlite3
import logging
import threading
from pathlib import Path
from typing import Optional, Sequence

from .embeddings import pack_vector, unpack_vector, cosine


logger = logging.getLogger("subconscious")

SIDECAR_DIRNAME = ".subconscious"
_CACHE_DIRNAME = "index_cache"
_DB_FILENAME = "index.db"
_META_FILENAME = "meta.json"
_SCHEMA_VERSION = 1


def _root_hash(root: Path) -> str:
  """Stable short hash of an absolute, case-normalised directory path.

  Used to key a directory's fallback sidecar under the central cache. Does not
  require the directory to exist (so it also works during detach/destroy).
  """
  norm = os.path.normcase(os.path.abspath(str(root)))
  return hashlib.sha256(norm.encode("utf-8")).hexdigest()[:16]


class SidecarStore:
  """A synchronous SQLite store for one directory + workspace."""

  def __init__(self, root: Path, db_path: Path, conn: sqlite3.Connection, embedder_name: str):
    self.root = root
    self.db_path = db_path
    self._conn = conn
    self._lock = threading.Lock()
    self.embedder_name = embedder_name

  # ------------------------------------------------------------------
  # Construction / lifecycle
  # ------------------------------------------------------------------

  @staticmethod
  def sidecar_dir(root: Path, workspace_uuid: str) -> Path:
    """Preferred in-directory sidecar location."""
    return root / SIDECAR_DIRNAME / workspace_uuid

  @staticmethod
  def cache_sidecar_dir(cache_dir: str, root: Path, workspace_uuid: str) -> Path:
    """Fallback sidecar location under the central data dir.

    Used when the attached directory itself is not writable (read-only mounts,
    network shares, permission-restricted folders). Keyed by a hash of the
    directory path so each attached directory keeps a distinct fallback store.
    """
    return Path(cache_dir) / _CACHE_DIRNAME / _root_hash(root) / workspace_uuid

  @staticmethod
  def _prepare_writable_dir(d: Path) -> Optional[Path]:
    """Create *d* and confirm it's writable; return it, or None on failure."""
    try:
      d.mkdir(parents=True, exist_ok=True)
      probe = d / ".write_test"
      probe.write_text("ok", encoding="utf-8")
      probe.unlink()
      return d
    except OSError:
      return None

  @classmethod
  def open(
    cls,
    root: Path,
    workspace_uuid: str,
    embedder_name: str,
    cache_dir: Optional[str] = None,
  ) -> "SidecarStore":
    """Open (creating if needed) the read-write store for *root*/*workspace_uuid*.

    Prefers the in-directory ``.subconscious`` location. If that directory can't
    be written (read-only / network share) and *cache_dir* is provided, falls
    back to a central per-directory cache so indexing still succeeds.
    """
    db_dir = cls._prepare_writable_dir(cls.sidecar_dir(root, workspace_uuid))
    used_fallback = False
    if db_dir is None and cache_dir:
      db_dir = cls._prepare_writable_dir(cls.cache_sidecar_dir(cache_dir, root, workspace_uuid))
      used_fallback = db_dir is not None
    if db_dir is None:
      raise OSError(f"No writable location for sidecar store of {root}")
    if used_fallback:
      logger.info("Directory %s not writable; using central cache sidecar", root)

    db_path = db_dir / _DB_FILENAME
    conn = sqlite3.connect(str(db_path), check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    store = cls(root, db_path, conn, embedder_name)
    store._ensure_schema()
    store._write_meta(workspace_uuid)
    return store

  @classmethod
  def open_readonly(
    cls,
    root: Path,
    workspace_uuid: str,
    embedder_name: str,
    cache_dir: Optional[str] = None,
  ) -> Optional["SidecarStore"]:
    """Open an existing store for reads, or None when it does not exist.

    Checks the in-directory location first, then the central cache fallback.
    """
    candidates = [cls.sidecar_dir(root, workspace_uuid) / _DB_FILENAME]
    if cache_dir:
      candidates.append(cls.cache_sidecar_dir(cache_dir, root, workspace_uuid) / _DB_FILENAME)
    for db_path in candidates:
      if db_path.exists():
        conn = sqlite3.connect(str(db_path), check_same_thread=False)
        conn.row_factory = sqlite3.Row
        return cls(root, db_path, conn, embedder_name)
    return None

  @classmethod
  def destroy(cls, root: Path, workspace_uuid: str, cache_dir: Optional[str] = None) -> bool:
    """Delete a workspace's store from both the in-directory and cache locations.

    Returns True when something was removed. This is what makes detaching a
    directory a clean severance of its indexed data.
    """
    removed = False

    sdir = cls.sidecar_dir(root, workspace_uuid)
    if sdir.exists():
      shutil.rmtree(sdir, ignore_errors=True)
      removed = True
    parent = root / SIDECAR_DIRNAME
    try:
      if parent.exists() and not any(parent.iterdir()):
        parent.rmdir()
    except OSError:
      pass

    if cache_dir:
      cdir = cls.cache_sidecar_dir(cache_dir, root, workspace_uuid)
      if cdir.exists():
        shutil.rmtree(cdir, ignore_errors=True)
        removed = True
      cparent = cdir.parent  # index_cache/<hash>
      try:
        if cparent.exists() and not any(cparent.iterdir()):
          cparent.rmdir()
      except OSError:
        pass

    return removed

  def close(self) -> None:
    try:
      self._conn.close()
    except Exception:
      pass

  def _write_meta(self, workspace_uuid: str) -> None:
    meta = {
      "schema_version": _SCHEMA_VERSION,
      "workspace_uuid": workspace_uuid,
      "embedder": self.embedder_name,
      "root": str(self.root),
      "updated_at": time.time(),
    }
    try:
      (self.db_path.parent / _META_FILENAME).write_text(
        json.dumps(meta, indent=2), encoding="utf-8"
      )
    except OSError as exc:
      logger.debug("Could not write sidecar meta.json: %s", exc)

  def _ensure_schema(self) -> None:
    with self._lock:
      self._conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS documents (
          id           INTEGER PRIMARY KEY AUTOINCREMENT,
          rel_path     TEXT UNIQUE NOT NULL,
          size         INTEGER,
          mtime        INTEGER,
          content_hash TEXT,
          chunk_count  INTEGER NOT NULL DEFAULT 0,
          status       TEXT NOT NULL DEFAULT 'indexed',
          error        TEXT,
          indexed_at   REAL
        );

        CREATE TABLE IF NOT EXISTS chunks (
          id             INTEGER PRIMARY KEY AUTOINCREMENT,
          document_id    INTEGER NOT NULL,
          ordinal        INTEGER NOT NULL DEFAULT 0,
          content        TEXT NOT NULL,
          start_line     INTEGER,
          end_line       INTEGER,
          token_estimate INTEGER,
          semantic_done  INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_chunks_doc ON chunks(document_id);

        CREATE TABLE IF NOT EXISTS chunk_vectors (
          chunk_id INTEGER PRIMARY KEY,
          dim      INTEGER NOT NULL,
          vec      BLOB NOT NULL
        );

        CREATE TABLE IF NOT EXISTS kg_nodes (
          id    INTEGER PRIMARY KEY AUTOINCREMENT,
          key   TEXT UNIQUE NOT NULL,
          type  TEXT NOT NULL,
          label TEXT NOT NULL,
          data  TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_kg_nodes_type ON kg_nodes(type);

        CREATE TABLE IF NOT EXISTS kg_edges (
          id          INTEGER PRIMARY KEY AUTOINCREMENT,
          src         INTEGER NOT NULL,
          dst         INTEGER NOT NULL,
          rel         TEXT NOT NULL,
          weight      REAL NOT NULL DEFAULT 1.0,
          document_id INTEGER,
          chunk_id    INTEGER,
          UNIQUE(src, dst, rel, document_id)
        );
        CREATE INDEX IF NOT EXISTS idx_kg_edges_src ON kg_edges(src);
        CREATE INDEX IF NOT EXISTS idx_kg_edges_dst ON kg_edges(dst);
        """
      )
      self._conn.commit()

  # ------------------------------------------------------------------
  # Documents & change detection
  # ------------------------------------------------------------------

  def get_document(self, rel_path: str) -> Optional[sqlite3.Row]:
    cur = self._conn.execute(
      "SELECT * FROM documents WHERE rel_path = ?", (rel_path,)
    )
    return cur.fetchone()

  def all_rel_paths(self) -> set[str]:
    cur = self._conn.execute("SELECT rel_path FROM documents")
    return {r[0] for r in cur.fetchall()}

  def mark_error(self, rel_path: str, error: str) -> None:
    with self._lock:
      row = self.get_document(rel_path)
      now = time.time()
      if row:
        self._conn.execute(
          "UPDATE documents SET status='error', error=?, indexed_at=? WHERE id=?",
          (error[:2000], now, row["id"]),
        )
      else:
        self._conn.execute(
          "INSERT INTO documents (rel_path, status, error, chunk_count, indexed_at) "
          "VALUES (?, 'error', ?, 0, ?)",
          (rel_path, error[:2000], now),
        )
      self._conn.commit()

  def replace_document(
    self,
    rel_path: str,
    size: int,
    mtime: int,
    content_hash: Optional[str],
    chunks: Sequence[tuple[str, Optional[int], Optional[int]]],
    vectors: Sequence[bytes],
    dim: int,
  ) -> tuple[int, list[int]]:
    """Insert/replace a document and its chunks + vectors atomically.

    Returns (document_id, [chunk_id, ...]) so the caller can attach knowledge
    graph provenance to specific chunks.
    """
    with self._lock:
      now = time.time()
      row = self.get_document(rel_path)
      if row:
        doc_id = row["id"]
        self._delete_document_children(doc_id)
        self._conn.execute(
          "UPDATE documents SET size=?, mtime=?, content_hash=?, chunk_count=?, "
          "status='indexed', error=NULL, indexed_at=? WHERE id=?",
          (size, mtime, content_hash, len(chunks), now, doc_id),
        )
      else:
        cur = self._conn.execute(
          "INSERT INTO documents (rel_path, size, mtime, content_hash, chunk_count, "
          "status, indexed_at) VALUES (?, ?, ?, ?, ?, 'indexed', ?)",
          (rel_path, size, mtime, content_hash, len(chunks), now),
        )
        doc_id = int(cur.lastrowid)

      chunk_ids: list[int] = []
      for ordinal, (content, start_line, end_line) in enumerate(chunks):
        cur = self._conn.execute(
          "INSERT INTO chunks (document_id, ordinal, content, start_line, end_line, "
          "token_estimate) VALUES (?, ?, ?, ?, ?, ?)",
          (doc_id, ordinal, content, start_line, end_line, max(1, len(content) // 4)),
        )
        cid = int(cur.lastrowid)
        chunk_ids.append(cid)
        if ordinal < len(vectors) and vectors[ordinal]:
          self._conn.execute(
            "INSERT OR REPLACE INTO chunk_vectors (chunk_id, dim, vec) VALUES (?, ?, ?)",
            (cid, dim, vectors[ordinal]),
          )
      self._conn.commit()
      return doc_id, chunk_ids

  def _delete_document_children(self, doc_id: int) -> None:
    """Remove chunks, vectors and KG provenance for a document (caller locks)."""
    cur = self._conn.execute("SELECT id FROM chunks WHERE document_id=?", (doc_id,))
    chunk_ids = [r[0] for r in cur.fetchall()]
    if chunk_ids:
      qmarks = ",".join("?" * len(chunk_ids))
      self._conn.execute(f"DELETE FROM chunk_vectors WHERE chunk_id IN ({qmarks})", chunk_ids)
    self._conn.execute("DELETE FROM chunks WHERE document_id=?", (doc_id,))
    # Drop edges sourced from this document; prune now-orphaned nodes lazily.
    self._conn.execute("DELETE FROM kg_edges WHERE document_id=?", (doc_id,))

  def prune(self, seen_rel_paths: set[str]) -> int:
    """Delete documents (and their children) no longer present on disk."""
    with self._lock:
      cur = self._conn.execute("SELECT id, rel_path FROM documents")
      stale = [r["id"] for r in cur.fetchall() if r["rel_path"] not in seen_rel_paths]
      for doc_id in stale:
        self._delete_document_children(doc_id)
        self._conn.execute("DELETE FROM documents WHERE id=?", (doc_id,))
      if stale:
        self._prune_orphan_nodes()
        self._conn.commit()
      return len(stale)

  def _prune_orphan_nodes(self) -> None:
    """Remove KG nodes that no longer participate in any edge (caller locks)."""
    self._conn.execute(
      "DELETE FROM kg_nodes WHERE id NOT IN "
      "(SELECT src FROM kg_edges UNION SELECT dst FROM kg_edges)"
    )

  # ------------------------------------------------------------------
  # Knowledge graph
  # ------------------------------------------------------------------

  def upsert_node(self, key: str, type_: str, label: str, data: Optional[dict] = None) -> int:
    with self._lock:
      cur = self._conn.execute("SELECT id FROM kg_nodes WHERE key=?", (key,))
      row = cur.fetchone()
      if row:
        node_id = row["id"]
        if data is not None:
          self._conn.execute(
            "UPDATE kg_nodes SET data=? WHERE id=?", (json.dumps(data), node_id)
          )
      else:
        cur = self._conn.execute(
          "INSERT INTO kg_nodes (key, type, label, data) VALUES (?, ?, ?, ?)",
          (key, type_, label, json.dumps(data) if data else None),
        )
        node_id = int(cur.lastrowid)
      self._conn.commit()
      return node_id

  def upsert_edge(
    self,
    src: int,
    dst: int,
    rel: str,
    document_id: Optional[int] = None,
    chunk_id: Optional[int] = None,
    weight: float = 1.0,
  ) -> None:
    with self._lock:
      self._conn.execute(
        "INSERT OR IGNORE INTO kg_edges (src, dst, rel, weight, document_id, chunk_id) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (src, dst, rel, weight, document_id, chunk_id),
      )
      self._conn.commit()

  def add_triples(self, triples: Sequence[dict]) -> int:
    """Bulk-add (subject, predicate, object) triples with provenance.

    Each triple dict: {subj, subj_type, pred, obj, obj_type, document_id, chunk_id}.
    """
    added = 0
    for t in triples:
      subj_key = f"{t['subj_type']}:{t['subj']}"
      obj_key = f"{t['obj_type']}:{t['obj']}"
      s = self.upsert_node(subj_key, t["subj_type"], t["subj"])
      o = self.upsert_node(obj_key, t["obj_type"], t["obj"])
      self.upsert_edge(
        s, o, t["pred"],
        document_id=t.get("document_id"),
        chunk_id=t.get("chunk_id"),
      )
      added += 1
    return added

  def mark_semantic_done(self, chunk_ids: Sequence[int]) -> None:
    if not chunk_ids:
      return
    with self._lock:
      qmarks = ",".join("?" * len(chunk_ids))
      self._conn.execute(
        f"UPDATE chunks SET semantic_done=1 WHERE id IN ({qmarks})", list(chunk_ids)
      )
      self._conn.commit()

  def pending_semantic_chunks(self, limit: int) -> list[sqlite3.Row]:
    cur = self._conn.execute(
      "SELECT id, document_id, content FROM chunks WHERE semantic_done=0 "
      "ORDER BY id LIMIT ?",
      (limit,),
    )
    return cur.fetchall()

  def neighbors(self, node_ids: Sequence[int], limit: int = 25) -> dict:
    """Return 1-hop neighbourhood (edges + connected nodes) for *node_ids*."""
    if not node_ids:
      return {"nodes": [], "edges": []}
    qmarks = ",".join("?" * len(node_ids))
    cur = self._conn.execute(
      f"SELECT * FROM kg_edges WHERE src IN ({qmarks}) OR dst IN ({qmarks}) LIMIT ?",
      list(node_ids) + list(node_ids) + [limit],
    )
    edges = [dict(r) for r in cur.fetchall()]
    ids = set(node_ids)
    for e in edges:
      ids.add(e["src"])
      ids.add(e["dst"])
    nodes = []
    if ids:
      qm = ",".join("?" * len(ids))
      ncur = self._conn.execute(f"SELECT * FROM kg_nodes WHERE id IN ({qm})", list(ids))
      nodes = [dict(r) for r in ncur.fetchall()]
    return {"nodes": nodes, "edges": edges}

  def nodes_for_document(self, document_id: int, limit: int = 25) -> list[int]:
    cur = self._conn.execute(
      "SELECT DISTINCT src FROM kg_edges WHERE document_id=? "
      "UNION SELECT DISTINCT dst FROM kg_edges WHERE document_id=? LIMIT ?",
      (document_id, document_id, limit),
    )
    return [r[0] for r in cur.fetchall()]

  # ------------------------------------------------------------------
  # Search
  # ------------------------------------------------------------------

  def search_keyword(self, query: str, limit: int) -> list[dict]:
    """Simple LIKE-based keyword search (matches the historical behaviour)."""
    q = query.strip()
    if not q:
      return []
    like = f"%{q}%"
    cur = self._conn.execute(
      "SELECT c.id AS chunk_id, c.content, c.start_line, c.end_line, "
      "       d.rel_path, d.id AS document_id "
      "FROM chunks c JOIN documents d ON d.id = c.document_id "
      "WHERE c.content LIKE ? LIMIT ?",
      (like, limit),
    )
    return [dict(r) for r in cur.fetchall()]

  def search_vector(self, query_vec: Sequence[float], limit: int) -> list[dict]:
    """Brute-force cosine similarity over stored chunk vectors.

    Pure-Python and correct on every platform. If a native vector extension
    (e.g. sqlite-vec) is later enabled, this method is the single place to
    delegate to it — the retriever contract stays identical.
    """
    if not query_vec:
      return []
    cur = self._conn.execute(
      "SELECT v.chunk_id, v.vec, c.content, c.start_line, c.end_line, "
      "       d.rel_path, d.id AS document_id "
      "FROM chunk_vectors v "
      "JOIN chunks c ON c.id = v.chunk_id "
      "JOIN documents d ON d.id = c.document_id"
    )
    scored: list[dict] = []
    for r in cur.fetchall():
      sim = cosine(query_vec, unpack_vector(r["vec"]))
      if sim <= 0:
        continue
      scored.append({
        "chunk_id": r["chunk_id"],
        "content": r["content"],
        "start_line": r["start_line"],
        "end_line": r["end_line"],
        "rel_path": r["rel_path"],
        "document_id": r["document_id"],
        "score": sim,
      })
    scored.sort(key=lambda d: d["score"], reverse=True)
    return scored[:limit]

  def chunks_for_nodes(self, node_ids: Sequence[int], limit: int = 10) -> list[dict]:
    """Return chunks that are provenance for edges touching *node_ids*."""
    if not node_ids:
      return []
    qmarks = ",".join("?" * len(node_ids))
    cur = self._conn.execute(
      f"SELECT DISTINCT c.id AS chunk_id, c.content, c.start_line, c.end_line, "
      f"       d.rel_path, d.id AS document_id "
      f"FROM kg_edges e "
      f"JOIN chunks c ON c.id = e.chunk_id "
      f"JOIN documents d ON d.id = c.document_id "
      f"WHERE (e.src IN ({qmarks}) OR e.dst IN ({qmarks})) AND e.chunk_id IS NOT NULL "
      f"LIMIT ?",
      list(node_ids) + list(node_ids) + [limit],
    )
    return [dict(r) for r in cur.fetchall()]

  def stats(self) -> dict:
    d = self._conn.execute("SELECT COUNT(*) FROM documents").fetchone()[0]
    c = self._conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
    n = self._conn.execute("SELECT COUNT(*) FROM kg_nodes").fetchone()[0]
    e = self._conn.execute("SELECT COUNT(*) FROM kg_edges").fetchone()[0]
    return {"documents": d, "chunks": c, "nodes": n, "edges": e}
