"""Deterministic, offline embeddings implemented with the Python standard library."""

from __future__ import annotations

import asyncio
import hashlib
import math
import re
from collections import Counter
from collections.abc import Sequence
from typing import Protocol, runtime_checkable

_TOKEN_PATTERN = re.compile(r"[\w]+", re.UNICODE)


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
            encoded = token.encode("utf-8")
            # Slice Unicode characters, then encode each n-gram independently.
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


_DEFAULT: HashingEmbedder | None = None


def get_default_embedder() -> HashingEmbedder:
    global _DEFAULT
    if _DEFAULT is None:
        _DEFAULT = HashingEmbedder()
    return _DEFAULT
