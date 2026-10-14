"""Channel-binding handshake over the ``control`` channel (webrtc.md 5.2).

Both sides send ``peer.hello {node_id, nonce}``. After receiving the other hello
each side answers with ``peer.proof {sig}`` where ``sig`` is an Ed25519 signature
over ``sc-hello-v1 | offerer_fp | answerer_fp | nonce_offerer | nonce_answerer``.
Because the fingerprints come from the negotiated descriptions, a valid proof
shows the DTLS endpoint belongs to the holder of the node key. Application
traffic is rejected until the remote proof verifies.
"""

from __future__ import annotations

import re
import secrets
from typing import Any

from .identity import NodeIdentity, b64u_encode, hello_message, node_ids_equal, verify_signature

_FINGERPRINT = re.compile(
    r"^a=fingerprint:(?P<alg>[A-Za-z0-9-]+)\s+(?P<value>(?:[0-9A-Fa-f]{2}:)*[0-9A-Fa-f]{2})\s*$",
    re.MULTILINE,
)
_MAX_NONCE_CHARS = 64


class HandshakeError(Exception):
    """The peer failed channel binding."""


def extract_fingerprint(sdp: str) -> str:
    """Return ``"sha-256 <HEX:..>"`` from an SDP (lower-case alg, upper-case hex)."""
    matches = {
        f"{m['alg'].lower()} {m['value'].upper()}" for m in _FINGERPRINT.finditer(sdp)
    }
    # aiortc advertises sha-256, sha-384 and sha-512 for one certificate while
    # libwebrtc advertises only sha-256; bind to sha-256 (required by RFC 8122)
    # and insist it is unambiguous.
    preferred = {m for m in matches if m.startswith("sha-256 ")}
    chosen = preferred if preferred else matches
    if len(chosen) != 1:
        raise HandshakeError("The description must carry exactly one DTLS fingerprint.")
    return chosen.pop()


class PeerHandshake:
    def __init__(
        self,
        identity: NodeIdentity,
        remote_node_id: str,
        remote_public_key: bytes,
        offerer_fingerprint: str,
        answerer_fingerprint: str,
        is_offerer: bool,
    ) -> None:
        self._identity = identity
        self._remote_id = remote_node_id
        self._remote_key = remote_public_key
        self._offerer_fp = offerer_fingerprint
        self._answerer_fp = answerer_fingerprint
        self._is_offerer = is_offerer
        self._nonce = b64u_encode(secrets.token_bytes(16))
        self._remote_nonce: str | None = None
        self.authenticated = False

    def hello(self) -> dict[str, Any]:
        return {"node_id": self._identity.node_id, "nonce": self._nonce}

    def receive_hello(self, data: Any) -> dict[str, Any]:
        """Validate the remote hello; return the ``peer.proof`` payload to send."""
        if not isinstance(data, dict) or self._remote_nonce is not None:
            raise HandshakeError("Unexpected hello.")
        node_id, nonce = data.get("node_id"), data.get("nonce")
        if not isinstance(node_id, str) or not node_ids_equal(node_id, self._remote_id):
            raise HandshakeError("Hello came from an unexpected node.")
        if not isinstance(nonce, str) or not 8 <= len(nonce) <= _MAX_NONCE_CHARS:
            raise HandshakeError("Hello nonce is invalid.")
        if nonce == self._nonce:
            raise HandshakeError("Reflected nonce.")
        self._remote_nonce = nonce
        return {"sig": self._identity.sign(self._message())}

    def receive_proof(self, data: Any) -> None:
        if self._remote_nonce is None:
            raise HandshakeError("Proof arrived before hello.")
        sig = data.get("sig") if isinstance(data, dict) else None
        if not isinstance(sig, str) or not verify_signature(
            self._remote_key, sig, self._message()
        ):
            raise HandshakeError("Channel binding failed.")
        self.authenticated = True

    def _message(self) -> bytes:
        assert self._remote_nonce is not None
        nonce_offerer, nonce_answerer = (
            (self._nonce, self._remote_nonce)
            if self._is_offerer
            else (self._remote_nonce, self._nonce)
        )
        return hello_message(
            self._offerer_fp, self._answerer_fp, nonce_offerer, nonce_answerer
        )
