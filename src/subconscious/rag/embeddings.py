""" Pluggable text embeddings for RAG.

The default :class:`HashingEmbedder` is fully offline and dependency-free: it
uses signed feature hashing (the "hashing trick") to turn text into a fixed,
L2-normalised vector. Quality is modest but it needs no model download, no
network, and runs happily inside the synchronous indexing worker thread.

The abstraction leaves room to swap in a stronger embedder later (e.g.
``sentence-transformers`` or a provider embedding endpoint) without touching the
sidecar/retrieval code — anything implementing :class:`Embedder` will do.
"""
from __future__ import annotations

import re
import math
import struct
import hashlib
import logging
from typing import Protocol, Sequence, runtime_checkable


logger = logging.getLogger("subconscious")

_TOKEN = re.compile(r"[A-Za-z0-9_]+")


@runtime_checkable
class Embedder(Protocol):
  """Minimal embedding interface used by the sidecar + retriever."""

  #: Stable identifier stored alongside vectors so a store built with one
  #: embedder is never mixed with vectors from another.
  name: str
  #: Vector dimensionality.
  dim: int

  def embed(self, text: str) -> list[float]:
    ...

  def embed_batch(self, texts: Sequence[str]) -> list[list[float]]:
    ...


class HashingEmbedder:
  """Deterministic, offline embedder using signed feature hashing."""

  def __init__(self, dim: int = 256):
    self.dim = dim
    self.name = f"hashing-v1-{dim}"

  def embed(self, text: str) -> list[float]:
    vec = [0.0] * self.dim
    if not text:
      return vec
    for tok in _TOKEN.findall(text.lower()):
      digest = hashlib.blake2b(tok.encode("utf-8"), digest_size=8).digest()
      idx = int.from_bytes(digest[:4], "little") % self.dim
      sign = 1.0 if (digest[4] & 1) else -1.0
      vec[idx] += sign
    norm = math.sqrt(sum(v * v for v in vec))
    if norm > 0:
      inv = 1.0 / norm
      vec = [v * inv for v in vec]
    return vec

  def embed_batch(self, texts: Sequence[str]) -> list[list[float]]:
    return [self.embed(t) for t in texts]


# ---------------------------------------------------------------------------
# Serialisation helpers (float32 little-endian blobs stored in SQLite)
# ---------------------------------------------------------------------------

def pack_vector(vec: Sequence[float]) -> bytes:
  """Pack a float vector to a compact little-endian float32 blob."""
  return struct.pack(f"<{len(vec)}f", *vec)


def unpack_vector(blob: bytes) -> list[float]:
  """Unpack a float32 blob back into a Python list."""
  count = len(blob) // 4
  if count == 0:
    return []
  return list(struct.unpack(f"<{count}f", blob))


def cosine(a: Sequence[float], b: Sequence[float]) -> float:
  """Cosine similarity. Vectors from the embedders above are already
  L2-normalised, so this reduces to a dot product, but we normalise defensively
  to stay correct for arbitrary inputs."""
  if not a or not b or len(a) != len(b):
    return 0.0
  dot = 0.0
  na = 0.0
  nb = 0.0
  for x, y in zip(a, b):
    dot += x * y
    na += x * x
    nb += y * y
  if na == 0.0 or nb == 0.0:
    return 0.0
  return dot / (math.sqrt(na) * math.sqrt(nb))


_DEFAULT: Embedder | None = None


def get_default_embedder() -> Embedder:
  """Return a process-wide default embedder instance."""
  global _DEFAULT
  if _DEFAULT is None:
    _DEFAULT = HashingEmbedder(dim=256)
    logger.debug("Initialised default embedder: %s", _DEFAULT.name)
  return _DEFAULT
