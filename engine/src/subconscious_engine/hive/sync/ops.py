"""Signed sync operations (Appendix A, ``sc-op-v1``)."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from ..identity import NodeIdentity, sha256_hex, verify_signature, b64u_decode, IdentityError
from .hlc import InvalidStamp, parse_stamp
import logging
_LOG = logging.getLogger(__name__)

ENTITIES = ("workspace", "thread", "message", "task")
OPS = ("create", "update", "delete")
MAX_PAYLOAD_BYTES = 1024 * 1024
MAX_UUID_LENGTH = 64
MAX_NODE_ID_LENGTH = 64

# Fields that may cross the wire. Machine local workspace settings (directories,
# tools_config, approval_config, rag_config, skills_config) are deliberately absent
# and the apply path ignores them even if a peer sends them.
SHARED_FIELDS: dict[str, tuple[str, ...]] = {
    "workspace": ("name", "description"),
    "thread": ("title", "description", "default_model_id"),
    "message": (),
    "task": (),
}
# Immutable creation attributes carried with a ``create`` op.
CREATE_FIELDS: dict[str, tuple[str, ...]] = {
    "workspace": ("created_at",),
    "thread": ("workspace_uuid", "created_at"),
    "message": ("thread_uuid", "role", "content", "created_at"),
    "task": (
        "thread_uuid", "workspace_uuid", "executor_node_id", "requester_node_id", "status", "rev",
        "turn_id", "model_id", "client_msg_uuid", "created_at", "started_at", "finished_at", "error",
    ),
}
TASK_FIELDS = CREATE_FIELDS["task"]


class OpError(ValueError):
    """A sync op is malformed or fails verification."""


def canonical_payload(payload: dict[str, Any]) -> str:
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def op_message(
    origin: str, seq: int, entity: str, uuid: str, op: str, hlc: str, payload: dict[str, Any]
) -> bytes:
    digest = sha256_hex(canonical_payload(payload))
    return f"sc-op-v1\n{origin}\n{seq}\n{entity}\n{uuid}\n{op}\n{hlc}\n{digest}".encode()


@dataclass(frozen=True, slots=True)
class SyncOp:
    origin: str
    seq: int
    entity: str
    uuid: str
    op: str
    hlc: str
    payload: dict[str, Any]
    sig: str

    def message(self) -> bytes:
        return op_message(
            self.origin, self.seq, self.entity, self.uuid, self.op, self.hlc, self.payload
        )

    def to_wire(self) -> dict[str, Any]:
        return {
            "origin": self.origin, "seq": self.seq, "entity": self.entity, "uuid": self.uuid,
            "op": self.op, "hlc": self.hlc, "payload": self.payload, "sig": self.sig,
        }

    @classmethod
    def from_wire(cls, raw: Any) -> "SyncOp":
        if not isinstance(raw, dict):
            raise OpError("Op must be an object.")
        origin, seq, entity = raw.get("origin"), raw.get("seq"), raw.get("entity")
        uuid, op, hlc = raw.get("uuid"), raw.get("op"), raw.get("hlc")
        payload, sig = raw.get("payload"), raw.get("sig")
        if not (isinstance(origin, str) and 0 < len(origin) <= MAX_NODE_ID_LENGTH):
            raise OpError("Bad origin.")
        if not (isinstance(seq, int) and not isinstance(seq, bool) and 0 < seq < 2**53):
            raise OpError("Bad sequence number.")
        if entity not in ENTITIES or op not in OPS:
            raise OpError("Unknown entity or operation.")
        if not (isinstance(uuid, str) and 0 < len(uuid) <= MAX_UUID_LENGTH):
            raise OpError("Bad uuid.")
        if not isinstance(payload, dict) or not isinstance(sig, str) or len(sig) > 200:
            raise OpError("Bad payload or signature.")
        try:
            parse_stamp(hlc)
        except InvalidStamp as error:
            raise OpError("Bad clock stamp.") from error
        if len(canonical_payload(payload).encode()) > MAX_PAYLOAD_BYTES:
            raise OpError("Payload too large.")
        return cls(origin, seq, entity, uuid, op, hlc, payload, sig)  # type: ignore[arg-type]


def sign_op(
    identity: NodeIdentity, seq: int, entity: str, uuid: str, op: str, hlc: str, payload: dict[str, Any]
) -> SyncOp:
    message = op_message(identity.node_id, seq, entity, uuid, op, hlc, payload)
    return SyncOp(identity.node_id, seq, entity, uuid, op, hlc, payload, identity.sign(message))


def verify_op(op: SyncOp, public_key: bytes) -> bool:
    try:
        b64u_decode(op.sig)
    except IdentityError:
        _LOG.warning("hive.sync.ops.verify_op: handled IdentityError; continuing with fallback", exc_info=True)
        return False
    return verify_signature(public_key, op.sig, op.message())
