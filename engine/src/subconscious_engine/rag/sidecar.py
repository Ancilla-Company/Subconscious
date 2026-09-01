"""SQLite sidecar storage for workspace documents, chunks, vectors, and graph data."""

from __future__ import annotations

import json
import sqlite3
import struct
import threading
import time
from collections.abc import Iterable, Sequence
from pathlib import Path
from typing import Any

from .embeddings import cosine_similarity

SIDECAR_DIRNAME = ".subconscious"
SIDECAR_FILENAME = "sidecar.db"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS documents (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    path TEXT NOT NULL UNIQUE,
    directory TEXT,
    size INTEGER NOT NULL DEFAULT 0,
    mtime INTEGER NOT NULL DEFAULT 0,
    content_hash TEXT,
    chunk_count INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'indexed',
    error TEXT,
    indexed_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_documents_directory ON documents(directory);
CREATE INDEX IF NOT EXISTS idx_documents_status ON documents(status);

CREATE TABLE IF NOT EXISTS chunks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    document_id INTEGER NOT NULL,
    ordinal INTEGER NOT NULL,
    content TEXT NOT NULL,
    start_line INTEGER,
    end_line INTEGER,
    token_estimate INTEGER,
    embedding BLOB,
    created_at INTEGER NOT NULL,
    UNIQUE(document_id, ordinal),
    FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_chunks_document ON chunks(document_id);

CREATE TABLE IF NOT EXISTS chunk_vectors (
    chunk_id INTEGER PRIMARY KEY,
    vector BLOB NOT NULL,
    FOREIGN KEY(chunk_id) REFERENCES chunks(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS kg_nodes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    node_id TEXT NOT NULL UNIQUE,
    label TEXT,
    properties TEXT,
    embedding BLOB,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_kg_nodes_label ON kg_nodes(label);

CREATE TABLE IF NOT EXISTS kg_edges (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    from_node_id TEXT NOT NULL,
    to_node_id TEXT NOT NULL,
    relationship TEXT NOT NULL,
    properties TEXT,
    document_id INTEGER,
    chunk_id INTEGER,
    created_at INTEGER NOT NULL,
    UNIQUE(from_node_id, to_node_id, relationship, document_id),
    FOREIGN KEY(from_node_id) REFERENCES kg_nodes(node_id) ON DELETE CASCADE,
    FOREIGN KEY(to_node_id) REFERENCES kg_nodes(node_id) ON DELETE CASCADE,
    FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE,
    FOREIGN KEY(chunk_id) REFERENCES chunks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_kg_edges_from ON kg_edges(from_node_id);
CREATE INDEX IF NOT EXISTS idx_kg_edges_to ON kg_edges(to_node_id);
CREATE INDEX IF NOT EXISTS idx_kg_edges_document ON kg_edges(document_id);
"""


def _pack_vector(vector: Sequence[float]) -> bytes:
    return struct.pack(f"<{len(vector)}f", *vector)


def _unpack_vector(value: bytes | str | memoryview | None) -> list[float]:
    if value is None:
        return []
    raw = value.tobytes() if isinstance(value, memoryview) else value
    if isinstance(raw, str):
        return [float(item) for item in json.loads(raw)]
    if not raw:
        return []
    if raw[:1] in (b"[", b"{"):
        return [float(item) for item in json.loads(raw.decode("utf-8"))]
    if len(raw) % 4:
        return []
    return list(struct.unpack(f"<{len(raw) // 4}f", raw))


class SidecarStore:
    """Thread-safe synchronous SQLite store; async callers should use its wrappers."""

    def __init__(self, root: str | Path, create: bool = True, readonly: bool = False) -> None:
        supplied = Path(root).expanduser()
        if supplied.name == SIDECAR_FILENAME:
            self.root = supplied.parent.parent
            self.db_path = supplied
        else:
            self.root = supplied
            self.db_path = supplied / SIDECAR_DIRNAME / SIDECAR_FILENAME
        if readonly and not self.db_path.is_file():
            raise FileNotFoundError(self.db_path)
        if create:
            self.db_path.parent.mkdir(parents=True, exist_ok=True)
        uri = f"file:{self.db_path.as_posix()}?mode=ro" if readonly else str(self.db_path)
        self._connection = sqlite3.connect(
            uri,
            uri=readonly,
            timeout=30.0,
            check_same_thread=False,
        )
        self._connection.row_factory = sqlite3.Row
        self._lock = threading.RLock()
        self._closed = False
        self._connection.execute("PRAGMA foreign_keys=ON")
        self._connection.execute("PRAGMA busy_timeout=30000")
        if create and not readonly:
            with self._lock:
                self._connection.executescript(_SCHEMA)
                self._connection.commit()

    @classmethod
    def open_readonly(cls, root: str | Path) -> SidecarStore | None:
        try:
            return cls(root, create=False, readonly=True)
        except (FileNotFoundError, sqlite3.OperationalError):
            return None

    def close(self) -> None:
        with self._lock:
            if not self._closed:
                self._connection.close()
                self._closed = True

    async def aclose(self) -> None:
        await __import__("asyncio").to_thread(self.close)

    def __enter__(self) -> SidecarStore:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    @staticmethod
    def _dict(row: sqlite3.Row | None) -> dict[str, Any] | None:
        return dict(row) if row is not None else None

    def get_document(self, path: str) -> dict[str, Any] | None:
        with self._lock:
            row = self._connection.execute(
                "SELECT id, path, directory, size, mtime, content_hash, chunk_count, "
                "status, error, indexed_at FROM documents WHERE path=?",
                (path,),
            ).fetchone()
        return self._dict(row)

    def list_documents(self) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._connection.execute(
                "SELECT id, path, directory, size, mtime, content_hash, chunk_count, "
                "status, error, indexed_at FROM documents ORDER BY path"
            ).fetchall()
        return [dict(row) for row in rows]

    def mark_document_error(self, path: str, error: str) -> None:
        now = int(time.time())
        directory = Path(path).parent.as_posix()
        if directory == ".":
            directory = ""
        with self._lock, self._connection:
            self._connection.execute(
                "INSERT INTO documents "
                "(path, directory, size, mtime, content_hash, chunk_count, status, error, indexed_at) "
                "VALUES (?, ?, 0, 0, NULL, 0, 'error', ?, ?) "
                "ON CONFLICT(path) DO UPDATE SET status='error', error=excluded.error, "
                "indexed_at=excluded.indexed_at",
                (path, directory, error[:2000], now),
            )

    def replace_document(
        self,
        path: str,
        directory: str,
        size: int,
        mtime: int,
        content_hash: str | None,
        chunks: Sequence[tuple[str, int | None, int | None, int | None]],
        vectors: Sequence[Sequence[float]],
        *,
        status: str = "indexed",
        error: str | None = None,
    ) -> tuple[int, list[int]]:
        """Atomically write a parent document before its chunks and vectors."""
        now = int(time.time())
        normalized_chunks: list[tuple[str, int | None, int | None, int | None]] = []
        for chunk in chunks:
            if len(chunk) == 3:
                content, start_line, end_line = chunk
                token_estimate = max(1, (len(content) + 3) // 4)
            else:
                content, start_line, end_line, token_estimate = chunk
            normalized_chunks.append((content, start_line, end_line, token_estimate))
        with self._lock, self._connection:
            self._connection.execute(
                "INSERT INTO documents "
                "(path, directory, size, mtime, content_hash, chunk_count, status, error, indexed_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(path) DO UPDATE SET directory=excluded.directory, size=excluded.size, "
                "mtime=excluded.mtime, content_hash=excluded.content_hash, "
                "chunk_count=excluded.chunk_count, status=excluded.status, error=excluded.error, "
                "indexed_at=excluded.indexed_at",
                (
                    path,
                    directory,
                    size,
                    mtime,
                    content_hash,
                    len(normalized_chunks),
                    status,
                    error,
                    now,
                ),
            )
            document_row = self._connection.execute(
                "SELECT id FROM documents WHERE path=?", (path,)
            ).fetchone()
            if document_row is None:
                raise sqlite3.IntegrityError("document upsert did not return an id")
            document_id = int(document_row["id"])
            self._connection.execute("DELETE FROM chunks WHERE document_id=?", (document_id,))
            chunk_ids: list[int] = []
            for ordinal, (content, start_line, end_line, token_estimate) in enumerate(
                normalized_chunks
            ):
                vector = vectors[ordinal] if ordinal < len(vectors) else ()
                packed = _pack_vector(vector) if vector else None
                cursor = self._connection.execute(
                    "INSERT INTO chunks "
                    "(document_id, ordinal, content, start_line, end_line, token_estimate, "
                    "embedding, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        document_id,
                        ordinal,
                        content,
                        start_line,
                        end_line,
                        token_estimate,
                        packed,
                        now,
                    ),
                )
                if cursor.lastrowid is None:
                    raise sqlite3.IntegrityError("chunk insert did not return an id")
                chunk_id = int(cursor.lastrowid)
                chunk_ids.append(chunk_id)
                if packed is not None:
                    self._connection.execute(
                        "INSERT INTO chunk_vectors (chunk_id, vector) VALUES (?, ?)",
                        (chunk_id, packed),
                    )
        return document_id, chunk_ids

    def upsert_document(
        self,
        path: str,
        directory: str = "",
        size: int = 0,
        mtime: int = 0,
        content_hash: str | None = None,
        chunk_count: int = 0,
        status: str = "indexed",
        error: str | None = None,
    ) -> int:
        now = int(time.time())
        with self._lock, self._connection:
            self._connection.execute(
                "INSERT INTO documents "
                "(path, directory, size, mtime, content_hash, chunk_count, status, error, indexed_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(path) DO UPDATE SET directory=excluded.directory, size=excluded.size, "
                "mtime=excluded.mtime, content_hash=excluded.content_hash, "
                "chunk_count=excluded.chunk_count, status=excluded.status, error=excluded.error, "
                "indexed_at=excluded.indexed_at",
                (path, directory, size, mtime, content_hash, chunk_count, status, error, now),
            )
            row = self._connection.execute(
                "SELECT id FROM documents WHERE path=?", (path,)
            ).fetchone()
        if row is None:
            raise sqlite3.IntegrityError("document upsert did not return an id")
        return int(row["id"])

    def upsert_chunk(
        self,
        document_id: int,
        ordinal: int,
        content: str,
        start_line: int | None = None,
        end_line: int | None = None,
        token_estimate: int | None = None,
        embedding: Sequence[float] | None = None,
    ) -> int:
        packed = _pack_vector(embedding) if embedding else None
        now = int(time.time())
        with self._lock, self._connection:
            self._connection.execute(
                "INSERT INTO chunks "
                "(document_id, ordinal, content, start_line, end_line, token_estimate, "
                "embedding, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(document_id, ordinal) DO UPDATE SET content=excluded.content, "
                "start_line=excluded.start_line, end_line=excluded.end_line, "
                "token_estimate=excluded.token_estimate, embedding=excluded.embedding, "
                "created_at=excluded.created_at",
                (
                    document_id,
                    ordinal,
                    content,
                    start_line,
                    end_line,
                    token_estimate,
                    packed,
                    now,
                ),
            )
            row = self._connection.execute(
                "SELECT id FROM chunks WHERE document_id=? AND ordinal=?",
                (document_id, ordinal),
            ).fetchone()
            if row is None:
                raise sqlite3.IntegrityError("chunk upsert did not return an id")
            chunk_id = int(row["id"])
            if packed is None:
                self._connection.execute("DELETE FROM chunk_vectors WHERE chunk_id=?", (chunk_id,))
            else:
                self._connection.execute(
                    "INSERT INTO chunk_vectors (chunk_id, vector) VALUES (?, ?) "
                    "ON CONFLICT(chunk_id) DO UPDATE SET vector=excluded.vector",
                    (chunk_id, packed),
                )
        return chunk_id

    def get_chunks(self, document_id: int) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._connection.execute(
                "SELECT id, document_id, ordinal, content, start_line, end_line, "
                "token_estimate, created_at FROM chunks WHERE document_id=? ORDER BY ordinal",
                (document_id,),
            ).fetchall()
        return [dict(row) for row in rows]

    def delete_document(self, path: str) -> bool:
        with self._lock, self._connection:
            cursor = self._connection.execute("DELETE FROM documents WHERE path=?", (path,))
        return cursor.rowcount > 0

    def prune_documents(self, seen_paths: set[str]) -> int:
        with self._lock, self._connection:
            rows = self._connection.execute("SELECT id, path FROM documents").fetchall()
            stale_ids = [int(row["id"]) for row in rows if row["path"] not in seen_paths]
            self._connection.executemany(
                "DELETE FROM documents WHERE id=?", ((doc_id,) for doc_id in stale_ids)
            )
        return len(stale_ids)

    @staticmethod
    def _result(row: sqlite3.Row, score: float) -> dict[str, Any]:
        return {
            "chunk_id": int(row["chunk_id"]),
            "document_id": int(row["document_id"]),
            "path": row["path"],
            "document_path": row["path"],
            "ordinal": int(row["ordinal"]),
            "content": row["content"],
            "start_line": row["start_line"],
            "end_line": row["end_line"],
            "token_estimate": row["token_estimate"],
            "score": float(score),
            "result_type": "chunk",
        }

    def keyword_search(self, query: str, limit: int = 20) -> list[dict[str, Any]]:
        terms = list(dict.fromkeys(term for term in query.casefold().split() if term))
        if not terms or limit <= 0:
            return []
        def escaped(term: str) -> str:
            return term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        predicates = " OR ".join("LOWER(c.content) LIKE ? ESCAPE '\\'" for _ in terms)
        parameters: list[Any] = [f"%{escaped(term)}%" for term in terms]
        parameters.append(max(limit * 8, 50))
        sql = (
            "SELECT c.id AS chunk_id, c.document_id, c.ordinal, c.content, c.start_line, "
            "c.end_line, c.token_estimate, d.path FROM chunks c "
            "JOIN documents d ON d.id=c.document_id WHERE "
            + predicates
            + " ORDER BY c.id LIMIT ?"
        )
        with self._lock:
            rows = self._connection.execute(sql, parameters).fetchall()
        scored: list[dict[str, Any]] = []
        phrase = query.casefold().strip()
        for row in rows:
            content = str(row["content"]).casefold()
            coverage = sum(term in content for term in terms) / len(terms)
            frequency = sum(content.count(term) for term in terms)
            score = coverage + min(frequency, 10) / 100.0
            if phrase and phrase in content:
                score += 0.25
            scored.append(self._result(row, score))
        scored.sort(key=lambda item: (-item["score"], item["path"], item["ordinal"]))
        return scored[:limit]

    search_keyword = keyword_search

    def vector_search(
        self,
        query_vector: Sequence[float],
        limit: int = 20,
        min_similarity: float = 0.0,
    ) -> list[dict[str, Any]]:
        if not query_vector or limit <= 0:
            return []
        with self._lock:
            rows = self._connection.execute(
                "SELECT c.id AS chunk_id, c.document_id, c.ordinal, c.content, c.start_line, "
                "c.end_line, c.token_estimate, d.path, v.vector FROM chunk_vectors v "
                "JOIN chunks c ON c.id=v.chunk_id JOIN documents d ON d.id=c.document_id"
            ).fetchall()
        results: list[dict[str, Any]] = []
        for row in rows:
            score = cosine_similarity(query_vector, _unpack_vector(row["vector"]))
            if score >= min_similarity:
                results.append(self._result(row, score))
        results.sort(key=lambda item: (-item["score"], item["path"], item["ordinal"]))
        return results[:limit]

    search_vector = vector_search

    def hybrid_search(
        self,
        query: str,
        query_vector: Sequence[float],
        limit: int = 20,
        rrf_k: int = 60,
        min_similarity: float = 0.0,
    ) -> list[dict[str, Any]]:
        """Fuse independent keyword/vector rankings with reciprocal-rank fusion."""
        if limit <= 0 or rrf_k < 0:
            return []
        keyword = self.keyword_search(query, limit * 2)
        vector = self.vector_search(query_vector, limit * 2, min_similarity)
        fused: dict[int, dict[str, Any]] = {}
        for source, score_name in ((keyword, "keyword_score"), (vector, "vector_score")):
            for rank, result in enumerate(source, start=1):
                chunk_id = int(result["chunk_id"])
                current = fused.setdefault(
                    chunk_id,
                    {
                        **result,
                        "score": 0.0,
                        "keyword_score": 0.0,
                        "vector_score": 0.0,
                    },
                )
                current["score"] += 1.0 / (rrf_k + rank)
                current[score_name] = result["score"]
        results = list(fused.values())
        results.sort(key=lambda item: (-item["score"], item["path"], item["ordinal"]))
        return results[:limit]

    search_hybrid = hybrid_search

    def upsert_node(
        self,
        node_id: str,
        label: str | None = None,
        properties: dict[str, Any] | str | None = None,
        embedding: Sequence[float] | None = None,
    ) -> int:
        props = properties if isinstance(properties, str) else json.dumps(properties or {})
        packed = _pack_vector(embedding) if embedding else None
        now = int(time.time())
        with self._lock, self._connection:
            self._connection.execute(
                "INSERT INTO kg_nodes (node_id, label, properties, embedding, created_at) "
                "VALUES (?, ?, ?, ?, ?) ON CONFLICT(node_id) DO UPDATE SET "
                "label=excluded.label, properties=excluded.properties, "
                "embedding=excluded.embedding",
                (node_id, label, props, packed, now),
            )
            row = self._connection.execute(
                "SELECT id FROM kg_nodes WHERE node_id=?", (node_id,)
            ).fetchone()
        if row is None:
            raise sqlite3.IntegrityError("node upsert did not return an id")
        return int(row["id"])

    def add_edge(
        self,
        from_node_id: str,
        to_node_id: str,
        relationship: str,
        properties: dict[str, Any] | str | None = None,
        document_id: int | None = None,
        chunk_id: int | None = None,
    ) -> int:
        props = properties if isinstance(properties, str) else json.dumps(properties or {})
        with self._lock, self._connection:
            cursor = self._connection.execute(
                "INSERT INTO kg_edges "
                "(from_node_id, to_node_id, relationship, properties, document_id, chunk_id, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(from_node_id, to_node_id, "
                "relationship, document_id) DO UPDATE SET properties=excluded.properties, "
                "chunk_id=excluded.chunk_id",
                (
                    from_node_id,
                    to_node_id,
                    relationship,
                    props,
                    document_id,
                    chunk_id,
                    int(time.time()),
                ),
            )
        return int(cursor.lastrowid or 0)

    def graph_search(
        self,
        query: str,
        depth: int = 2,
        limit: int = 20,
    ) -> list[dict[str, Any]]:
        query = query.strip()
        if not query or limit <= 0:
            return []
        like = f"%{query}%"
        with self._lock:
            seeds = self._connection.execute(
                "SELECT id, node_id, label, properties FROM kg_nodes "
                "WHERE node_id LIKE ? OR label LIKE ? OR properties LIKE ? "
                "ORDER BY node_id LIMIT ?",
                (like, like, like, limit),
            ).fetchall()
            if not seeds:
                return []
            discovered = {str(row["node_id"]) for row in seeds}
            frontier = set(discovered)
            edges: list[dict[str, Any]] = []
            for _ in range(max(0, depth)):
                if not frontier or len(discovered) >= limit * 4:
                    break
                placeholders = ",".join("?" for _ in frontier)
                parameters = list(frontier) + list(frontier) + [limit * 4]
                edge_rows = self._connection.execute(
                    f"SELECT id, from_node_id, to_node_id, relationship, properties, "
                    f"document_id, chunk_id FROM kg_edges WHERE from_node_id IN "
                    f"({placeholders}) OR to_node_id IN ({placeholders}) ORDER BY id LIMIT ?",
                    parameters,
                ).fetchall()
                next_frontier: set[str] = set()
                known_edge_ids = {edge["id"] for edge in edges}
                for row in edge_rows:
                    edge = dict(row)
                    if edge["id"] not in known_edge_ids:
                        edges.append(edge)
                        known_edge_ids.add(edge["id"])
                    for node_id in (str(row["from_node_id"]), str(row["to_node_id"])):
                        if node_id not in discovered:
                            discovered.add(node_id)
                            next_frontier.add(node_id)
                frontier = next_frontier
            placeholders = ",".join("?" for _ in discovered)
            node_rows = self._connection.execute(
                f"SELECT id, node_id, label, properties FROM kg_nodes "
                f"WHERE node_id IN ({placeholders}) ORDER BY node_id",
                list(discovered),
            ).fetchall()
        seed_ids = {str(row["node_id"]) for row in seeds}
        relations: dict[str, list[dict[str, Any]]] = {node_id: [] for node_id in discovered}
        for edge in edges:
            relations[str(edge["from_node_id"])].append(edge)
            relations[str(edge["to_node_id"])].append(edge)
        results = []
        for row in node_rows:
            node_id = str(row["node_id"])
            results.append(
                {
                    "result_type": "node",
                    "node_id": node_id,
                    "label": row["label"],
                    "properties": row["properties"],
                    "relations": relations[node_id],
                    "score": 1.0 if node_id in seed_ids else 0.5,
                }
            )
        results.sort(key=lambda item: (-item["score"], item["node_id"]))
        return results[:limit]

    def stats(self) -> dict[str, int]:
        with self._lock:
            counts = {}
            for table in ("documents", "chunks", "chunk_vectors", "kg_nodes", "kg_edges"):
                counts[table] = int(
                    self._connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
                )
        return counts

    async def replace_document_async(self, *args: Any, **kwargs: Any) -> tuple[int, list[int]]:
        import asyncio

        return await asyncio.to_thread(self.replace_document, *args, **kwargs)

    async def keyword_search_async(self, query: str, limit: int = 20) -> list[dict[str, Any]]:
        import asyncio

        return await asyncio.to_thread(self.keyword_search, query, limit)

    async def vector_search_async(
        self,
        query_vector: Sequence[float],
        limit: int = 20,
        min_similarity: float = 0.0,
    ) -> list[dict[str, Any]]:
        import asyncio

        return await asyncio.to_thread(
            self.vector_search, query_vector, limit, min_similarity
        )
