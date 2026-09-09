"""Embedding implementations used by workspace retrieval."""

from __future__ import annotations

import asyncio
import hashlib
import math
import re
from collections import Counter
from collections.abc import Sequence
from typing import Protocol, runtime_checkable
from urllib.parse import urlparse

import httpx

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


class OpenAIEmbedder:
    """Synchronous OpenAI-compatible dense embedder with bounded requests."""

    def __init__(self, api_key: str, *, base_url: str = "https://api.openai.com/v1",
                 model: str = "text-embedding-3-small", dimensions: int = 1536,
                 batch_size: int = 64, timeout_seconds: float = 30.0) -> None:
        if not api_key.strip():
            raise ValueError("OpenAI API key is required")
        parsed = urlparse(base_url.strip())
        if parsed.scheme not in {"http", "https"} or not parsed.netloc \
                or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ValueError("OpenAI base URL must be HTTP(S) without credentials or query data")
        if dimensions <= 0 or batch_size <= 0 or timeout_seconds <= 0:
            raise ValueError("embedding dimensions, batch size, and timeout must be positive")
        self._api_key = api_key.strip()
        self.base_url = base_url.strip().rstrip("/")
        self.model = model.strip() or "text-embedding-3-small"
        self.dim = dimensions
        self.sparse_dim = 1024
        self.batch_size = batch_size
        self.timeout_seconds = timeout_seconds
        self.name = f"openai:{self.base_url}:{self.model}:{self.dim}"
        self._sparse = HashingEmbedder(dim=1, sparse_dim=self.sparse_dim)

    def embed(self, text: str) -> list[float]:
        return self.embed_batch([text])[0]

    def embed_sparse(self, text: str) -> dict[int, float]:
        return self._sparse.embed_sparse(text)

    def embed_batch(self, texts: Sequence[str]) -> list[list[float]]:
        if not texts:
            return []
        vectors: list[list[float]] = []
        timeout = httpx.Timeout(self.timeout_seconds, connect=min(10.0, self.timeout_seconds))
        try:
            with httpx.Client(timeout=timeout, trust_env=False) as client:
                for start in range(0, len(texts), self.batch_size):
                    batch = list(texts[start:start + self.batch_size])
                    response = client.post(
                        f"{self.base_url}/embeddings",
                        headers={"Authorization": f"Bearer {self._api_key}"},
                        json={"model": self.model, "input": batch, "dimensions": self.dim},
                    )
                    response.raise_for_status()
                    payload = response.json()
                    data = payload.get("data") if isinstance(payload, dict) else None
                    if not isinstance(data, list) or len(data) != len(batch):
                        raise ValueError("invalid embeddings response")
                    ordered = sorted(data, key=lambda item: item.get("index", -1)
                                     if isinstance(item, dict) else -1)
                    for item in ordered:
                        vector = item.get("embedding") if isinstance(item, dict) else None
                        if not isinstance(vector, list) or len(vector) != self.dim:
                            raise ValueError("invalid embedding vector")
                        vectors.append([float(value) for value in vector])
        except (httpx.HTTPError, TypeError, ValueError) as error:
            raise EmbeddingError("The semantic embedding service is unavailable.") from error
        return vectors


_DEFAULT: HashingEmbedder | None = None


def get_default_embedder() -> HashingEmbedder:
    global _DEFAULT
    if _DEFAULT is None:
        _DEFAULT = HashingEmbedder()
    return _DEFAULT
