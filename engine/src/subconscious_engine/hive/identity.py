"""Node identity: Ed25519 keys, node id derivation and the signing contexts.

The private key lives in the OS keyring (service ``subconscious.node.identity.v1``)
with the same encrypted ``data.enc`` fallback used for the account refresh token.
Signing contexts are binding strings from webrtc.md section 5; every signature is
base64url without padding.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import logging
from typing import Protocol

import keyring
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from keyring.errors import PasswordDeleteError

from subconscious_engine.configuration import EncryptedModelConfigurationStore
from subconscious_engine.configuration.key_provider import (
    SERVICE_NAME as _ENCRYPTION_KEYRING_SERVICE,
)
_LOG = logging.getLogger(__name__)

_LOGGER = logging.getLogger("uvicorn.error")
KEYRING_SERVICE = "subconscious.node.identity.v1"
_KEYRING_USER = "ed25519_seed"

if KEYRING_SERVICE == _ENCRYPTION_KEYRING_SERVICE:  # pragma: no cover - guard
    raise RuntimeError("Node identity and encryption credentials must be distinct.")


class IdentityError(Exception):
    """A node identity could not be loaded, stored or verified."""


# --- encoding helpers -------------------------------------------------------


def b64u_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def b64u_decode(text: str) -> bytes:
    if not isinstance(text, str) or not text.isascii():
        raise IdentityError("Invalid base64url value.")
    try:
        return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
    except (binascii.Error, ValueError) as error:
        raise IdentityError("Invalid base64url value.") from error


def sha256_hex(value: str | bytes) -> str:
    data = value.encode("utf-8") if isinstance(value, str) else value
    return hashlib.sha256(data).hexdigest()


def derive_node_id(public_key: bytes) -> str:
    """``n_`` + lowercase base32 (no padding) of the first 16 bytes of SHA-256(key)."""
    digest = hashlib.sha256(public_key).digest()[:16]
    return "n_" + base64.b32encode(digest).decode("ascii").rstrip("=").lower()


def node_ids_equal(left: str, right: str) -> bool:
    return left.casefold() == right.casefold()


# --- signing contexts (binding, see webrtc.md 4.3/5.2/5.3) -------------------


def register_message(user_id: str, public_key_b64u: str) -> bytes:
    return f"sc-register-v1\n{user_id}\n{public_key_b64u}".encode()


def signal_auth_message(challenge: str, ticket: str, node_id: str) -> bytes:
    return f"sc-signal-v1\n{challenge}\n{sha256_hex(ticket)}\n{node_id}".encode()


def sdp_message(sid: str, sender: str, recipient: str, sdp: str) -> bytes:
    return f"sc-sdp-v1\n{sid}\n{sender}\n{recipient}\n{sha256_hex(sdp)}".encode()


def approval_message(user_id: str, new_public_key_b64u: str) -> bytes:
    return f"sc-approve-v1\n{user_id}\n{new_public_key_b64u}".encode()


def hello_message(
    offerer_fp: str, answerer_fp: str, nonce_a: str, nonce_b: str
) -> bytes:
    """Fingerprints ordered (offerer, answerer); nonces ordered the same way."""
    return f"sc-hello-v1\n{offerer_fp}\n{answerer_fp}\n{nonce_a}\n{nonce_b}".encode()


def verify_signature(public_key: bytes, signature_b64u: str, message: bytes) -> bool:
    """Verify an Ed25519 signature; any malformed input is simply ``False``."""
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(
            b64u_decode(signature_b64u), message
        )
    except (InvalidSignature, ValueError, IdentityError):
        _LOG.warning("hive.identity.verify_signature: handled (InvalidSignature, ValueError, IdentityError); continuing with fallback", exc_info=True)
        return False
    return True


def short_authentication_string(key_a: bytes, key_b: bytes) -> str:
    """Six digits both sides can compare; symmetric in the two public keys."""
    first, second = sorted((key_a, key_b))
    digest = hashlib.sha256(b"sc-sas-v1\n" + first + second).digest()
    return f"{int.from_bytes(digest[:4], 'big') % 1_000_000:06d}"


# --- identity ---------------------------------------------------------------


class NodeIdentity:
    def __init__(self, private_key: Ed25519PrivateKey) -> None:
        self._private_key = private_key
        self.public_key: bytes = private_key.public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw
        )
        self.public_key_b64u = b64u_encode(self.public_key)
        self.node_id = derive_node_id(self.public_key)

    @classmethod
    def generate(cls) -> "NodeIdentity":
        return cls(Ed25519PrivateKey.generate())

    @classmethod
    def from_seed(cls, seed: bytes) -> "NodeIdentity":
        if len(seed) != 32:
            raise IdentityError("The stored node key is malformed.")
        return cls(Ed25519PrivateKey.from_private_bytes(seed))

    def seed(self) -> bytes:
        return self._private_key.private_bytes(
            serialization.Encoding.Raw,
            serialization.PrivateFormat.Raw,
            serialization.NoEncryption(),
        )

    def sign(self, message: bytes) -> str:
        return b64u_encode(self._private_key.sign(message))

    def __repr__(self) -> str:  # never reveal key material
        return f"NodeIdentity(node_id={self.node_id!r})"


class IdentitySeedStore(Protocol):
    def read(self) -> str | None: ...
    def write(self, seed: str) -> None: ...
    def delete(self) -> None: ...


class KeyringIdentitySeedStore:
    def __init__(self, namespace: str | None = None) -> None:
        self._user = _KEYRING_USER if not namespace else f"{_KEYRING_USER}:{namespace}"

    def read(self) -> str | None:
        try:
            value = keyring.get_password(KEYRING_SERVICE, self._user)
        except Exception as error:
            raise IdentityError("The node identity could not be read.") from error
        return value.strip() if value and value.strip() else None

    def write(self, seed: str) -> None:
        try:
            keyring.set_password(KEYRING_SERVICE, self._user, seed)
        except Exception as error:
            raise IdentityError("The node identity could not be saved.") from error

    def delete(self) -> None:
        try:
            keyring.delete_password(KEYRING_SERVICE, self._user)
        except PasswordDeleteError:
            _LOG.warning("hive.identity.KeyringIdentitySeedStore.delete: handled PasswordDeleteError; continuing with fallback", exc_info=True)
            pass
        except Exception as error:
            raise IdentityError("The node identity could not be cleared.") from error


class EncryptedIdentitySeedStore:
    """Fallback inside the Fernet-encrypted ``data.enc`` vault."""

    def __init__(self, credential_store: EncryptedModelConfigurationStore) -> None:
        self._store = credential_store

    def read(self) -> str | None:
        try:
            return self._store.get_node_identity_seed()
        except Exception as error:
            raise IdentityError("The encrypted node identity is unavailable.") from error

    def write(self, seed: str) -> None:
        try:
            self._store.set_node_identity_seed(seed)
        except Exception as error:
            raise IdentityError("The node identity could not be saved.") from error

    def delete(self) -> None:
        try:
            self._store.remove_node_identity_seed()
        except Exception as error:
            raise IdentityError("The node identity could not be cleared.") from error


class ResilientIdentitySeedStore:
    """Keyring first, ``data.enc`` fallback (mirrors the refresh-token store)."""

    def __init__(self, primary: IdentitySeedStore, fallback: IdentitySeedStore) -> None:
        self._primary = primary
        self._fallback = fallback

    def read(self) -> str | None:
        try:
            seed = self._fallback.read()
        except IdentityError:
            _LOG.warning("hive.identity.ResilientIdentitySeedStore.read: handled IdentityError; continuing with fallback", exc_info=True)
            seed = None
        if seed:
            return seed
        try:
            return self._primary.read()
        except IdentityError:
            _LOG.warning("hive.identity.ResilientIdentitySeedStore.read: handled IdentityError; continuing with fallback", exc_info=True)
            return None

    def write(self, seed: str) -> None:
        try:
            self._primary.write(seed)
        except IdentityError:
            if not getattr(self, "_warned_write", False):
                self._warned_write = True
                _LOG.warning("Keyring write failed; using the encrypted fallback store.")
            else:
                _LOG.debug("Keyring write failed again; using the fallback.", exc_info=True)
            self._fallback.write(seed)
        else:
            try:
                self._fallback.delete()
            except IdentityError:
                _LOG.warning("hive.identity.ResilientIdentitySeedStore.write: handled IdentityError; continuing with fallback", exc_info=True)
                pass

    def delete(self) -> None:
        errors: list[IdentityError] = []
        for store in (self._fallback, self._primary):
            try:
                store.delete()
            except IdentityError as error:
                _LOG.warning("hive.identity.ResilientIdentitySeedStore.delete: handled IdentityError; continuing with fallback", exc_info=True)
                errors.append(error)
        if len(errors) == 2:
            raise errors[0]


def default_identity_store(
    credential_store: EncryptedModelConfigurationStore,
    namespace: str | None = None,
) -> IdentitySeedStore:
    return ResilientIdentitySeedStore(
        KeyringIdentitySeedStore(namespace), EncryptedIdentitySeedStore(credential_store)
    )


def load_identity(store: IdentitySeedStore) -> NodeIdentity | None:
    seed = store.read()
    return NodeIdentity.from_seed(b64u_decode(seed)) if seed else None


def load_or_create_identity(store: IdentitySeedStore) -> NodeIdentity:
    existing = load_identity(store)
    if existing is not None:
        return existing
    identity = NodeIdentity.generate()
    store.write(b64u_encode(identity.seed()))
    return identity
