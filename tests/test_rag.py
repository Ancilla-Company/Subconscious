import asyncio
import json
import math

import pytest
from sqlalchemy import select

from subconscious_engine.api.schemas import CreateWorkspaceRequest
from subconscious_engine.rag import (
    HashingEmbedder, SidecarStore, WorkspaceIndexer, WorkspaceRetriever,
    cosine_similarity,
)
from subconscious_engine.rag.sidecar import _pack_vector, _unpack_vector
from subconscious_engine.services.rag_service import RagServiceError, WorkspaceRagService
from subconscious_engine.services.workspaces import WorkspaceService
from subconscious_engine.storage.database import Database
from subconscious_engine.storage.models import Workspace


def run(coro):
    return asyncio.run(coro)


def test_hashing_embedder_is_deterministic_normalized_and_validates_dimensions():
    embedder = HashingEmbedder(dim=32, sparse_dim=17)
    first = embedder.embed("Hello, HELLO world")
    assert first == embedder.embed("hello hello WORLD!")
    assert len(first) == 32
    assert math.isclose(sum(value * value for value in first), 1.0)
    sparse = embedder.embed_sparse("hello hello world")
    assert list(sparse) == sorted(sparse)
    assert math.isclose(sum(sparse.values()), 1.0)
    assert embedder.embed("") == [0.0] * 32
    assert embedder.embed_sparse("---") == {}
    assert embedder.embed_batch(["a", "b"]) == [embedder.embed("a"), embedder.embed("b")]
    assert run(embedder.embed_async("a")) == embedder.embed("a")
    assert run(embedder.embed_sparse_async("a")) == embedder.embed_sparse("a")
    assert run(embedder.embed_batch_async(["a"])) == [embedder.embed("a")]
    with pytest.raises(ValueError, match="positive"):
        HashingEmbedder(dim=0)


def test_cosine_and_vector_serialization_cover_empty_mismatch_and_legacy_formats():
    assert cosine_similarity([1, 0], [1, 0]) == pytest.approx(1.0)
    assert cosine_similarity([1, 0], [-1, 0]) == pytest.approx(-1.0)
    assert cosine_similarity([], []) == 0.0
    assert cosine_similarity([1], [1, 2]) == 0.0
    assert cosine_similarity([0, 0], [1, 2]) == 0.0
    assert _unpack_vector(_pack_vector([1.25, -2.5])) == pytest.approx([1.25, -2.5])
    assert _unpack_vector(memoryview(_pack_vector([3.0]))) == [3.0]
    assert _unpack_vector("[1, 2]") == [1.0, 2.0]
    assert _unpack_vector(b"[3, 4]") == [3.0, 4.0]
    assert _unpack_vector(None) == []
    assert _unpack_vector(b"bad") == []


def test_sidecar_document_search_update_prune_and_readonly_lifecycle(tmp_path):
    assert SidecarStore.open_readonly(tmp_path) is None
    with SidecarStore(tmp_path) as store:
        first_id, chunk_ids = store.replace_document(
            "a.txt", "", 20, 1, "hash-a",
            [("alpha beta alpha", 1, 1), ("100% under_score", 2, 2, 4)],
            [[1.0, 0.0], [0.0, 1.0]],
        )
        second_id, _ = store.replace_document(
            "b.txt", "", 10, 2, "hash-b", [("beta", 1, 1)], [[0.8, 0.2]])
        assert store.stats() == {"documents": 2, "chunks": 3, "chunk_vectors": 3,
                                 "kg_nodes": 0, "kg_edges": 0}
        assert store.get_document("a.txt")["chunk_count"] == 2
        assert [row["ordinal"] for row in store.get_chunks(first_id)] == [0, 1]
        assert store.keyword_search("alpha beta", 1)[0]["path"] == "a.txt"
        assert store.keyword_search("100% under_score")[0]["chunk_id"] == chunk_ids[1]
        assert store.keyword_search("", 5) == []
        vectors = store.vector_search([1.0, 0.0], min_similarity=0.99)
        assert [(row["path"], row["score"]) for row in vectors] == [("a.txt", 1.0)]
        assert store.vector_search([], 5) == []
        hybrid = store.hybrid_search("beta", [1.0, 0.0], limit=3, rrf_k=0)
        assert hybrid[0]["path"] == "a.txt"
        assert {"keyword_score", "vector_score"} <= hybrid[0].keys()
        assert store.hybrid_search("beta", [1.0], rrf_k=-1) == []

        same_id, replacement_ids = store.replace_document(
            "a.txt", "src", 3, 3, "new", [("replacement", 4, 4)], [[]])
        assert same_id == first_id and replacement_ids != chunk_ids
        assert store.stats()["chunk_vectors"] == 1
        assert store.upsert_chunk(first_id, 0, "updated", embedding=[0.5, 0.5]) == replacement_ids[0]
        assert store.stats()["chunk_vectors"] == 2
        store.upsert_chunk(first_id, 0, "without vector")
        assert store.stats()["chunk_vectors"] == 1
        store.mark_document_error("broken/file.txt", "x" * 3000)
        assert store.get_document("broken/file.txt")["status"] == "error"
        assert len(store.get_document("broken/file.txt")["error"]) == 2000
        assert store.prune_documents({"a.txt"}) == 2
        assert store.delete_document("missing") is False
        assert store.delete_document("a.txt") is True
        assert store.stats()["chunks"] == 0
    readonly = SidecarStore.open_readonly(tmp_path)
    assert readonly is not None
    readonly.close()
    readonly.close()


def test_graph_storage_traversal_and_retriever_fallbacks(tmp_path):
    embedder = HashingEmbedder(dim=16)
    with SidecarStore(tmp_path) as store:
        document_id, chunk_ids = store.replace_document(
            "facts.txt", "", 10, 1, "hash", [("oranges are fruit", 1, 1)],
            [embedder.embed("oranges are fruit")])
        assert store.upsert_node("alice", "Person", {"role": "engineer"}) > 0
        store.upsert_node("bob", "Person", "{\"role\":\"designer\"}")
        store.add_edge("alice", "bob", "KNOWS", {"since": 2020}, document_id, chunk_ids[0])
        graph = store.graph_search("alice", depth=1)
        assert [item["node_id"] for item in graph] == ["alice", "bob"]
        assert graph[0]["score"] == 1.0 and graph[1]["score"] == 0.5
        assert graph[0]["relations"][0]["relationship"] == "KNOWS"
        assert store.graph_search("missing") == []
        retriever = WorkspaceRetriever(tmp_path, embedder=embedder, store=store)
        assert retriever.search_sync("alice", mode="graph")[0]["result_type"] == "node"
        fallback = retriever.search_sync("oranges", mode="graph")
        assert fallback[0]["result_type"] == "chunk"
        assert retriever.search_sync("", mode="hybrid") == []
        assert retriever.search_sync("orange", limit=0) == []
        with pytest.raises(ValueError, match="unsupported"):
            retriever.search_sync("x", mode="invalid")
        assert run(retriever.list_documents())[0]["path"] == "facts.txt"
        assert run(retriever.get_document_chunks("facts.txt"))[0]["content"] == "oranges are fruit"
        assert run(retriever.get_document_chunks("missing")) == []


def test_indexer_chunks_skips_unchanged_changes_and_removes_files(tmp_path):
    root = tmp_path / "workspace"
    root.mkdir()
    (root / "keep.txt").write_text("first line\nsecond line\n", encoding="utf-8")
    (root / "binary.dat").write_bytes(b"a\0\0\0")
    (root / "large.txt").write_text("x" * 500_001, encoding="utf-8")
    (root / ".git").mkdir()
    (root / ".git" / "ignored.txt").write_text("ignored", encoding="utf-8")
    with SidecarStore(root) as store:
        indexer = WorkspaceIndexer(root, embedder=HashingEmbedder(dim=16), store=store)
        first = indexer.index_directory_sync()
        assert first == type(first)(indexed=1, unchanged=0, skipped=2, errors=0, removed=0)
        assert [row["path"] for row in store.list_documents()] == [
            "binary.dat", "keep.txt", "large.txt"]
        assert store.get_document("binary.dat")["status"] == "skipped"
        assert store.get_document("large.txt")["error"] == "More than 500000 characters"
        second = run(indexer.index())
        assert second.unchanged == 3 and second.indexed == second.skipped == 0
        (root / "keep.txt").write_text("changed text", encoding="utf-8")
        (root / "binary.dat").unlink()
        third = indexer.index_directory_sync()
        assert (third.indexed, third.unchanged, third.removed) == (1, 1, 1)
        assert WorkspaceIndexer.chunk_text("") == []
        chunks = WorkspaceIndexer.chunk_text("a" * 1490 + "\n" + "b" * 20)
        assert [(item[1], item[2]) for item in chunks] == [(1, 1), (2, 2)]
    with SidecarStore(tmp_path / "other") as store:
        with pytest.raises(NotADirectoryError):
            WorkspaceIndexer(tmp_path / "missing", store=store).index_directory_sync()


def test_workspace_rag_service_validates_roots_indexes_and_combines_results(tmp_path):
    async def scenario():
        first_root = tmp_path / "first"
        second_root = tmp_path / "second"
        first_root.mkdir()
        second_root.mkdir()
        (first_root / "a.txt").write_text("shared alpha", encoding="utf-8")
        (second_root / "b.txt").write_text("shared beta", encoding="utf-8")
        database = Database(tmp_path / "rag-service.db")
        await database.initialize()
        service = WorkspaceRagService(embedder=HashingEmbedder())
        try:
            async with database.session() as session:
                created = await WorkspaceService(session).create(CreateWorkspaceRequest(
                    name="RAG", directories=json.dumps([str(first_root), str(second_root)])))
                summary = await service.index(session, created.uuid)
                assert [item["rootIndex"] for item in summary["roots"]] == [0, 1]
                assert [item["indexed"] for item in summary["roots"]] == [1, 1]
                results = await service.search(session, created.uuid, "shared", "keyword", 2)
                assert [(item["rootIndex"], item["path"]) for item in results] == [
                    (0, "a.txt"), (1, "b.txt")]
                with pytest.raises(RagServiceError) as mode_error:
                    await service.search(session, created.uuid, "x", "bad")
                assert mode_error.value.status_code == 400
                with pytest.raises(RagServiceError) as missing:
                    await service.roots(session, "missing")
                assert missing.value.status_code == 404

                row = await session.scalar(select(Workspace).where(Workspace.uuid == created.uuid))
                row.directories = "not-json"
                await session.commit()
                with pytest.raises(RagServiceError) as malformed:
                    await service.roots(session, created.uuid)
                assert malformed.value.status_code == 400
                row.directories = json.dumps(["relative"])
                await session.commit()
                with pytest.raises(RagServiceError) as invalid:
                    await service.roots(session, created.uuid)
                assert invalid.value.status_code == 400
        finally:
            await database.close()
    run(scenario())
