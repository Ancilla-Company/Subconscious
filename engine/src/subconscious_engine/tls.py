"""TLS trust for outbound client connections.

httpx verifies against certifi's CA bundle, but ``websockets`` (and anything else
using ``ssl.create_default_context()``) falls back to OpenSSL's compiled-in paths
plus the Windows certificate store. A frozen (PyInstaller/MSIX) build has no
OpenSSL CA directory, and the Windows store can hold expired cross-signed roots,
so ``https://`` worked while ``wss://`` failed with ``SSLCertVerificationError``.
Every outbound TLS client uses this context so both transports trust the same roots.
"""

from __future__ import annotations

import ssl
from functools import lru_cache

import certifi


@lru_cache(maxsize=1)
def client_ssl_context() -> ssl.SSLContext:
    """A verifying client context backed by certifi (the same roots httpx uses)."""
    return ssl.create_default_context(cafile=certifi.where())


def ssl_for_url(url: str) -> ssl.SSLContext | None:
    """The client context for ``wss://``/``https://`` URLs, ``None`` for plain ones."""
    scheme = url.split(":", 1)[0].lower()
    return client_ssl_context() if scheme in ("wss", "https") else None
