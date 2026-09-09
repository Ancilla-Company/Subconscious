"""Embedding implementations used by workspace retrieval."""

from __future__ import annotations

import asyncio
import hashlib
import math
import os
import re
import threading
from collections import Counter
from collections.abc import Sequence
from pathlib import Path
from typing import Any, Protocol, runtime_checkable

_TOKEN_PATTERN = re.compile(r"[\w]+", re.UNICODE)


class EmbeddingError(RuntimeError):
    """A safe, credential-free embedding failure."""


@runtime_checkable
class Embedder(Protocol):
    """Embedding contract used by the indexer and retriever."""

    name: str
    dim: int
    sparse_dim: int

    def embed(self, text: str) -> list[float]: ...

    def embed_sparse(self, text: str) -> dict[int, float]: ...

    def embed_batch(self, texts: Sequence[str]) -> list[list[float]]: ...


def cosine_similarity(a: Sequence[float], b: Sequence[float]) -> float:
    """Return cosine similarity, or zero for empty/mismatched vectors."""
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(y * y for y in b))
    if norm_a == 0.0 or norm_b == 0.0:
        return 0.0
    return dot / (norm_a * norm_b)


class HashingEmbedder:
    """SHA-256 character n-gram embedder with stable dense and sparse shapes."""

    def __init__(self, dim: int = 768, sparse_dim: int = 1024) -> None:
        if dim <= 0 or sparse_dim <= 0:
            raise ValueError("embedding dimensions must be positive")
        self.dim = dim
        self.sparse_dim = sparse_dim
        self.name = f"sha256-ngram-v1-{dim}-{sparse_dim}"

    @staticmethod
    def _features(text: str) -> Counter[bytes]:
        features: Counter[bytes] = Counter()
        for token in _TOKEN_PATTERN.findall(text.casefold()):
            chars = list(token)
            for width in range(1, min(3, len(chars)) + 1):
                for start in range(len(chars) - width + 1):
                    features["".join(chars[start : start + width]).encode("utf-8")] += 1
        return features

    @staticmethod
    def _index(feature: bytes, dimensions: int) -> int:
        digest = hashlib.sha256(feature).digest()
        return int.from_bytes(digest[:8], "big", signed=False) % dimensions

    def embed(self, text: str) -> list[float]:
        vector = [0.0] * self.dim
        features = self._features(text)
        if not features:
            return vector
        for feature, count in features.items():
            vector[self._index(feature, self.dim)] += float(count)
        norm = math.sqrt(sum(value * value for value in vector))
        if norm:
            vector = [value / norm for value in vector]
        return vector

    def embed_sparse(self, text: str) -> dict[int, float]:
        features = self._features(text)
        if not features:
            return {}
        buckets: Counter[int] = Counter()
        for feature, count in features.items():
            buckets[self._index(feature, self.sparse_dim)] += count
        total = float(sum(buckets.values()))
        return {index: count / total for index, count in sorted(buckets.items())}

    def embed_batch(self, texts: Sequence[str]) -> list[list[float]]:
        return [self.embed(text) for text in texts]

    async def embed_async(self, text: str) -> list[float]:
        return await asyncio.to_thread(self.embed, text)

    async def embed_sparse_async(self, text: str) -> dict[int, float]:
        return await asyncio.to_thread(self.embed_sparse, text)

    async def embed_batch_async(self, texts: Sequence[str]) -> list[list[float]]:
        return await asyncio.to_thread(self.embed_batch, texts)

    @staticmethod
    def cosine(a: Sequence[float], b: Sequence[float]) -> float:
        return cosine_similarity(a, b)


class SentenceTransformerEmbedder:
    """Lazy, process-cached local semantic embedder backed by MiniLM."""

    MODEL = "sentence-transformers/all-MiniLM-L6-v2"
    REVISION = "1110a243fdf4706b3f48f1d95db1a4f5529b4d41"
    DIMENSIONS = 384
    _models: dict[tuple[str, str, str], Any] = {}
    _model_lock = threading.Lock()
    _inference_lock = threading.Lock()

    def __init__(self, *, cache_folder: str | Path | None = None,
                 batch_size: int = 32) -> None:
        if batch_size <= 0:
            raise ValueError("embedding batch size must be positive")
        self.cache_folder = Path(cache_folder).expanduser() if cache_folder else None
        self.batch_size = batch_size
        self.dim = self.DIMENSIONS
        self.sparse_dim = 1024
        self.name = (
            f"sentence-transformers:{self.MODEL}:{self.REVISION}:"
            f"mean:l2:{self.dim}:v1"
        )
        self._sparse = HashingEmbedder(dim=1, sparse_dim=self.sparse_dim)

    def embed(self, text: str) -> list[float]:
        return self.embed_batch([text])[0]

    def embed_sparse(self, text: str) -> dict[int, float]:
        return self._sparse.embed_sparse(text)

    def _model(self) -> Any:
        cache_key = (
            self.MODEL,
            self.REVISION,
            os.path.normcase(str(self.cache_folder.resolve()))
            if self.cache_folder is not None else "",
        )
        with self._model_lock:
            cached = self._models.get(cache_key)
            if cached is not None:
                return cached
            try:
                if self.cache_folder is not None:
                    self.cache_folder.mkdir(parents=True, exist_ok=True)
                from sentence_transformers import SentenceTransformer

                model = SentenceTransformer(
                    self.MODEL,
                    revision=self.REVISION,
                    cache_folder=str(self.cache_folder) if self.cache_folder else None,
                    trust_remote_code=False,
                )
            except Exception as error:
                raise EmbeddingError(
                    "The local semantic embedding model is unavailable."
                ) from error
            self._models[cache_key] = model
            return model

    def embed_batch(self, texts: Sequence[str]) -> list[list[float]]:
        if not texts:
            return []
        model = self._model()
        vectors: list[list[float]] = []
        try:
            with self._inference_lock:
                for start in range(0, len(texts), self.batch_size):
                    batch = list(texts[start:start + self.batch_size])
                    encoded = model.encode(
                        batch,
                        batch_size=min(self.batch_size, len(batch)),
                        normalize_embeddings=True,
                        convert_to_numpy=True,
                        show_progress_bar=False,
                    )
                    if len(encoded) != len(batch):
                        raise ValueError("embedding row count mismatch")
                    for row in encoded:
                        vector = [float(value) for value in row]
                        if len(vector) != self.dim or not all(
                            math.isfinite(value) for value in vector
                        ):
                            raise ValueError("invalid embedding vector")
                        vectors.append(vector)
        except EmbeddingError:
            raise
        except Exception as error:
            raise EmbeddingError(
                "The local semantic embedding model could not process the text."
            ) from error
        if len(vectors) != len(texts):
            raise EmbeddingError(
                "The local semantic embedding model returned incomplete results."
            )
        return vectors


_DEFAULT: HashingEmbedder | None = None


def get_default_embedder() -> HashingEmbedder:
    global _DEFAULT
    if _DEFAULT is None:
        _DEFAULT = HashingEmbedder()
    return _DEFAULT
