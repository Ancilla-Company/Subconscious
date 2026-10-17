"""Client identification: who is connected, and is it on this machine?

Pure helpers (no pystray, no network) shared by the websocket layer and the tray.
Clients identify themselves with the websocket query parameters ``client_type``,
``client_name`` and ``client_version`` (or the matching ``client.hello`` data
fields ``clientType``, ``clientName``, ``clientVersion``). Everything is
whitelisted, sanitised and length limited; the auth token is never read here.
"""
from collections import Counter
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime, timezone
import ipaddress
import logging
import re
import socket
from typing import Any
_LOG = logging.getLogger(__name__)
CLIENT_TYPES = ("desktop", "mobile", "tui", "browser_extension", "cli", "web")
UNKNOWN_TYPE = "unknown"
CLIENT_DISPLAY = {
    "desktop": "Desktop",
    "mobile": "Mobile",
    "tui": "TUI",
    "browser_extension": "Browser extension",
    "cli": "CLI",
    "web": "Web UI",
    UNKNOWN_TYPE: "Unknown",
}
NO_CLIENTS_LABEL = "No clients connected"
_MAX_TYPE, _MAX_NAME, _MAX_VERSION = 32, 64, 32
_CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")
_SPACES = re.compile(r"\s+")
@dataclass(frozen=True)
class ClientIdentity:
    type: str = UNKNOWN_TYPE
    name: str = ""
    version: str = ""
@dataclass(frozen=True)
class ClientInfo:
    client_id: str
    type: str
    display_name: str
    version: str
    address: str | None
    connected_at: datetime
    is_local: bool
def _clean(value: Any, limit: int) -> str:
    if not isinstance(value, str):
        return ""
    return _SPACES.sub(" ", _CONTROL.sub(" ", value)).strip()[:limit]
def _first(query: Mapping[str, Any] | None, hello: Mapping[str, Any] | None,
           query_key: str, hello_key: str, limit: int) -> str:
    """The query parameter wins; the hello field is the fallback."""
    for source, key in ((query, query_key), (hello, hello_key)):
        if source is None:
            continue
        cleaned = _clean(source.get(key), limit)
        if cleaned:
            return cleaned
    return ""
def parse_identity(
    query_params: Mapping[str, Any] | None, hello_data: Mapping[str, Any] | None = None
) -> ClientIdentity:
    raw_type = _first(query_params, hello_data, "client_type", "clientType", _MAX_TYPE)
    client_type = raw_type.lower().replace("-", "_").replace(" ", "_")
    if client_type not in CLIENT_TYPES:
        client_type = UNKNOWN_TYPE
    return ClientIdentity(
        client_type,
        _first(query_params, hello_data, "client_name", "clientName", _MAX_NAME),
        _first(query_params, hello_data, "client_version", "clientVersion", _MAX_VERSION),
    )
_own_addresses: frozenset[str] | None = None
def _own_interface_addresses() -> frozenset[str]:
    global _own_addresses
    if _own_addresses is not None:
        return _own_addresses
    found: set[str] = set()
    try:
        for entry in socket.getaddrinfo(socket.gethostname(), None):
            found.add(str(entry[4][0]).split("%")[0])
    except OSError:
        _LOG.warning("client_identity: could not list host addresses", exc_info=True)
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            probe.connect(("192.0.2.1", 9))  # UDP connect sends nothing
            found.add(probe.getsockname()[0])
        finally:
            probe.close()
    except OSError:
        _LOG.warning("client_identity: could not detect primary address", exc_info=True)
    _own_addresses = frozenset(found)
    return _own_addresses
def is_local_address(host: Any) -> bool:
    """Loopback or one of this machine's own addresses. Anything else is remote."""
    if not isinstance(host, str) or not host:
        return False
    try:
        address = ipaddress.ip_address(host.split("%")[0])
    except ValueError:
        _LOG.warning("client_identity: unparseable peer address %r", host[:64])
        return False
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None:
        address = address.ipv4_mapped
    if address.is_loopback:
        return True
    return str(address) in _own_interface_addresses()
def build_client_info(
    client_id: str,
    identity: ClientIdentity,
    *,
    label: str | None = None,
    address: str | None = None,
    is_local: bool = True,
    node_name: str | None = None,
) -> ClientInfo:
    if node_name:
        display = _clean(node_name, _MAX_NAME)
    elif identity.type != UNKNOWN_TYPE:
        display = CLIENT_DISPLAY[identity.type]
    else:
        display = _clean(label, _MAX_NAME) or CLIENT_DISPLAY[UNKNOWN_TYPE]
    return ClientInfo(
        client_id, identity.type, display or CLIENT_DISPLAY[UNKNOWN_TYPE],
        identity.version, address, datetime.now(timezone.utc), is_local,
    )
def client_menu_labels(clients: Sequence[ClientInfo]) -> tuple[str, ...]:
    """Human readable tray labels: local first, same kind de-duplicated."""
    if not clients:
        return (NO_CLIENTS_LABEL,)
    counts: Counter[tuple[str, bool, str | None]] = Counter()
    for client in clients:
        counts[(client.display_name, client.is_local, None if client.is_local else client.address)] += 1
    ordered = sorted(counts.items(), key=lambda item: (not item[0][1], item[0][0].casefold(), item[0][2] or ""))
    labels = []
    for (name, local, address), count in ordered:
        base = name if count == 1 else f"{name} x{count}"
        if local:
            labels.append(f"{base} (local)")
        elif address:
            labels.append(f"{base} (remote, {address})")
        else:
            labels.append(f"{base} (remote)")
    return tuple(labels)
