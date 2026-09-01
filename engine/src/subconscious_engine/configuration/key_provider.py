"""Fernet key retrieval compatible with the existing Python/.NET stores."""

import os
from threading import Lock
from typing import Protocol

from cryptography.fernet import Fernet

from .errors import ModelConfigurationStoreError

SERVICE_NAME = "subconscious"
USER_NAME = "encryption_key"
ENVIRONMENT_VARIABLE = "SUBCONSCIOUS_FERNET_KEY"


class FernetKeyProvider(Protocol):
    def get_or_create_key(self) -> str:
        """Return a validated URL-safe base64 Fernet key."""


class KeyringFernetKeyProvider:
    """Gets or creates the shared Fernet key in the OS credential store."""

    def __init__(self) -> None:
        self._key: str | None = None
        self._lock = Lock()

    def get_or_create_key(self) -> str:
        with self._lock:
            if self._key is not None:
                return self._key

            override = os.getenv(ENVIRONMENT_VARIABLE)
            if override and override.strip():
                self._key = _validate_key(override.strip())
                return self._key

            try:
                import keyring

                stored = keyring.get_password(SERVICE_NAME, USER_NAME)
                if stored and stored.strip():
                    self._key = _validate_key(stored.strip())
                    return self._key

                generated = Fernet.generate_key().decode("ascii")
                keyring.set_password(SERVICE_NAME, USER_NAME, generated)
                self._key = generated
                return generated
            except ModelConfigurationStoreError:
                raise
            except Exception as error:
                raise ModelConfigurationStoreError(
                    "The Subconscious encryption key is unavailable."
                ) from error


def _validate_key(key: str) -> str:
    try:
        Fernet(key.encode("ascii"))
    except (UnicodeEncodeError, ValueError) as error:
        raise ModelConfigurationStoreError(
            "The Subconscious encryption key is not a valid Fernet key."
        ) from error
    return key
