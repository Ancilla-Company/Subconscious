"""Decide whether a connected peer is on this machine.

Security: the decision uses only the transport peer address that the ASGI server
read from the socket. ``Forwarded`` / ``X-Forwarded-*`` headers and any value the
client sends are never consulted. Hive tunnel peers (``PeerSocket``, or a scope
carrying a tunnel principal) are always remote. Addresses of this machine's own
LAN interfaces are NOT local: only loopback is. The bearer token is still required
for every API call; locality only decides role and labelling.
"""

from __future__ import annotations

import ipaddress
import logging
from typing import Any

from .auth import trusted_peer

_LOG = logging.getLogger(__name__)


def is_loopback_host(host: Any) -> bool:
    if not isinstance(host, str) or not host:
        return False
    try:
        address = ipaddress.ip_address(host.split("%", 1)[0])
    except ValueError:
        _LOG.debug("locality.is_loopback_host: not an IP address", exc_info=True)
        return False
    mapped = getattr(address, "ipv4_mapped", None)
    if mapped is not None:
        address = mapped
    return address.is_loopback


def is_local_peer(source: Any) -> bool:
    """True only for a direct loopback transport peer that is not a tunnel peer.

    ``source`` is an ASGI scope (dict), a Starlette WebSocket/Request, or a
    ``PeerSocket``-like object.
    """
    if source is None:
        return False
    if isinstance(source, dict):
        scope = source
        client = scope.get("client")
    else:
        if getattr(source, "link", None) is not None:
            return False
        scope = getattr(source, "scope", None)
        client = getattr(source, "client", None)
    if isinstance(scope, dict):
        try:
            if trusted_peer(scope) is not None:
                return False
        except Exception:
            _LOG.warning("locality.is_local_peer: could not inspect scope; treating as remote", exc_info=True)
            return False
    host: Any
    if isinstance(client, (tuple, list)):
        host = client[0] if client else None
    else:
        host = getattr(client, "host", None)
    return is_loopback_host(host)
