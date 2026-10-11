"""Platform-protected Fernet key retrieval for encrypted configuration."""

from __future__ import annotations

from collections.abc import Callable
import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import sys
import tempfile
from threading import Lock
from typing import Any, Protocol

from cryptography.fernet import Fernet

from .errors import ModelConfigurationStoreError

SERVICE_NAME = "subconscious"
USER_NAME = "encryption_key"
ENVIRONMENT_VARIABLE = "SUBCONSCIOUS_FERNET_KEY"
DPAPI_KEY_FILE_NAME = "master-key.dpapi"
_DPAPI_FILE_MAGIC = b"SUBCONSCIOUS-DPAPI\x00\x01"
_CRYPTPROTECT_UI_FORBIDDEN = 0x1


class FernetKeyProvider(Protocol):
    def get_or_create_key(self) -> str:
        """Return a validated URL-safe base64 Fernet key."""
        ...


class KeyringFernetKeyProvider:
    """Gets or creates the shared Fernet key in the OS credential store."""

    def __init__(self) -> None:
        self._key: str | None = None
        self._lock = Lock()

    def get_or_create_key(self) -> str:
        with self._lock:
            if self._key is not None:
                return self._key

            override = _environment_override()
            if override is not None:
                self._key = override
                return override

            try:
                stored = _read_legacy_keyring_key()
                if stored is not None:
                    self._key = stored
                    return stored

                generated = Fernet.generate_key().decode("ascii")
                import keyring

                keyring.set_password(SERVICE_NAME, USER_NAME, generated)
                self._key = generated
                return generated
            except ModelConfigurationStoreError:
                raise
            except Exception as error:
                raise ModelConfigurationStoreError(
                    "The Subconscious encryption key is unavailable."
                ) from error


class DpapiFernetKeyProvider:
    """Stores the Fernet key in a current-user DPAPI-protected local file."""

    def __init__(
        self,
        key_file_path: str | Path | None = None,
        *,
        encrypted_data_path: str | Path | None = None,
        legacy_key_reader: Callable[[], str | None] | None = None,
    ) -> None:
        self.key_file_path = Path(key_file_path or _default_dpapi_key_path())
        self.lock_file_path = self.key_file_path.with_suffix(
            f"{self.key_file_path.suffix}.lock"
        )
        self._encrypted_data_path = (
            Path(encrypted_data_path) if encrypted_data_path is not None else None
        )
        self._legacy_key_reader = legacy_key_reader or _read_legacy_keyring_key
        self._key: str | None = None
        self._lock = Lock()

    def get_or_create_key(self) -> str:
        with self._lock:
            if self._key is not None:
                return self._key

            override = _environment_override()
            if override is not None:
                self._key = override
                return override

            if sys.platform != "win32":
                raise ModelConfigurationStoreError(
                    "DPAPI encryption key storage is only available on Windows."
                )

            try:
                with _WindowsFileLock(self.lock_file_path):
                    if self.key_file_path.exists():
                        self._key = self._read_key_file()
                        return self._key

                    legacy_error: Exception | None = None
                    try:
                        key = self._legacy_key_reader()
                    except Exception as error:
                        legacy_error = error
                        key = None

                    if key is None and self._encrypted_data_exists():
                        message = (
                            "The existing encrypted configuration has no recoverable "
                            "Subconscious encryption key."
                        )
                        if legacy_error is not None:
                            raise ModelConfigurationStoreError(message) from legacy_error
                        raise ModelConfigurationStoreError(message)

                    key = key or Fernet.generate_key().decode("ascii")
                    key = _validate_key(key)
                    self._write_key_file(key)
                    self._key = key
                    return key
            except ModelConfigurationStoreError:
                raise
            except Exception as error:
                raise ModelConfigurationStoreError(
                    "The Windows-protected Subconscious encryption key is unavailable."
                ) from error

    def _encrypted_data_exists(self) -> bool:
        return (
            self._encrypted_data_path is not None
            and self._encrypted_data_path.exists()
            and self._encrypted_data_path.stat().st_size > 0
        )

    def _read_key_file(self) -> str:
        try:
            payload = self.key_file_path.read_bytes()
            if not payload.startswith(_DPAPI_FILE_MAGIC):
                raise ValueError("Unsupported DPAPI key file format")
            protected = payload[len(_DPAPI_FILE_MAGIC) :]
            if not protected:
                raise ValueError("Empty DPAPI key payload")
            key = _dpapi_unprotect(protected).decode("ascii")
            return _validate_key(key)
        except ModelConfigurationStoreError:
            raise
        except Exception as error:
            raise ModelConfigurationStoreError(
                "The Windows-protected Subconscious encryption key could not be read."
            ) from error

    def _write_key_file(self, key: str) -> None:
        directory = self.key_file_path.parent
        temporary_path: Path | None = None
        descriptor: int | None = None
        try:
            directory.mkdir(parents=True, exist_ok=True)
            payload = _DPAPI_FILE_MAGIC + _dpapi_protect(key.encode("ascii"))
            descriptor, name = tempfile.mkstemp(
                prefix=f".{self.key_file_path.name}.", suffix=".tmp", dir=directory
            )
            temporary_path = Path(name)
            os.chmod(temporary_path, 0o600)
            with os.fdopen(descriptor, "wb") as temporary:
                descriptor = None
                temporary.write(payload)
                temporary.flush()
                os.fsync(temporary.fileno())
            os.replace(temporary_path, self.key_file_path)
            temporary_path = None
        except Exception as error:
            raise ModelConfigurationStoreError(
                "The Windows-protected Subconscious encryption key could not be saved."
            ) from error
        finally:
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
            if temporary_path is not None:
                try:
                    temporary_path.unlink(missing_ok=True)
                except OSError:
                    pass


class PlatformFernetKeyProvider:
    """Uses DPAPI on Windows and the system keyring on other platforms."""

    def __init__(self, *, encrypted_data_path: str | Path | None = None) -> None:
        self._provider: FernetKeyProvider = (
            DpapiFernetKeyProvider(encrypted_data_path=encrypted_data_path)
            if sys.platform == "win32"
            else KeyringFernetKeyProvider()
        )

    def get_or_create_key(self) -> str:
        return self._provider.get_or_create_key()


class _WindowsFileLock:
    """Interprocess lock protecting DPAPI key migration and creation."""

    def __init__(self, path: Path) -> None:
        self._path = path
        self._file: Any = None

    def __enter__(self) -> "_WindowsFileLock":
        import msvcrt

        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._file = self._path.open("a+b")
        self._file.seek(0, os.SEEK_END)
        if self._file.tell() == 0:
            self._file.write(b"\0")
            self._file.flush()
        self._file.seek(0)
        msvcrt.locking(self._file.fileno(), msvcrt.LK_LOCK, 1)
        return self

    def __exit__(self, exc_type: Any, exc_value: Any, traceback: Any) -> None:
        import msvcrt

        if self._file is None:
            return
        try:
            self._file.seek(0)
            msvcrt.locking(self._file.fileno(), msvcrt.LK_UNLCK, 1)
        finally:
            self._file.close()
            self._file = None


class _DataBlob(ctypes.Structure):
    _fields_ = [
        ("cbData", wintypes.DWORD),
        ("pbData", ctypes.POINTER(ctypes.c_ubyte)),
    ]


def _default_dpapi_key_path() -> Path:
    local_app_data = os.getenv("LOCALAPPDATA")
    root = Path(local_app_data) if local_app_data else Path.home() / "AppData/Local"
    return root / "Subconscious" / DPAPI_KEY_FILE_NAME


def _environment_override() -> str | None:
    override = os.getenv(ENVIRONMENT_VARIABLE)
    return _validate_key(override.strip()) if override and override.strip() else None


def _read_legacy_keyring_key() -> str | None:
    import keyring

    stored = keyring.get_password(SERVICE_NAME, USER_NAME)
    return _validate_key(stored.strip()) if stored and stored.strip() else None


def _data_blob(data: bytes) -> tuple[_DataBlob, Any]:
    buffer = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
    return _DataBlob(len(data), buffer), buffer


def _dpapi_protect(data: bytes) -> bytes:
    crypt32 = ctypes.WinDLL("Crypt32.dll", use_last_error=True)
    kernel32 = ctypes.WinDLL("Kernel32.dll", use_last_error=True)
    crypt32.CryptProtectData.argtypes = [
        ctypes.POINTER(_DataBlob),
        wintypes.LPCWSTR,
        ctypes.POINTER(_DataBlob),
        ctypes.c_void_p,
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.POINTER(_DataBlob),
    ]
    crypt32.CryptProtectData.restype = wintypes.BOOL
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    kernel32.LocalFree.restype = ctypes.c_void_p

    source, source_buffer = _data_blob(data)
    result = _DataBlob()
    try:
        if not crypt32.CryptProtectData(
            ctypes.byref(source),
            "Subconscious Fernet key",
            None,
            None,
            None,
            _CRYPTPROTECT_UI_FORBIDDEN,
            ctypes.byref(result),
        ):
            raise ctypes.WinError(ctypes.get_last_error())
        return ctypes.string_at(result.pbData, result.cbData)
    finally:
        del source_buffer
        if result.pbData:
            kernel32.LocalFree(result.pbData)


def _dpapi_unprotect(data: bytes) -> bytes:
    crypt32 = ctypes.WinDLL("Crypt32.dll", use_last_error=True)
    kernel32 = ctypes.WinDLL("Kernel32.dll", use_last_error=True)
    crypt32.CryptUnprotectData.argtypes = [
        ctypes.POINTER(_DataBlob),
        ctypes.POINTER(wintypes.LPWSTR),
        ctypes.POINTER(_DataBlob),
        ctypes.c_void_p,
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.POINTER(_DataBlob),
    ]
    crypt32.CryptUnprotectData.restype = wintypes.BOOL
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    kernel32.LocalFree.restype = ctypes.c_void_p

    source, source_buffer = _data_blob(data)
    result = _DataBlob()
    try:
        if not crypt32.CryptUnprotectData(
            ctypes.byref(source),
            None,
            None,
            None,
            None,
            _CRYPTPROTECT_UI_FORBIDDEN,
            ctypes.byref(result),
        ):
            raise ctypes.WinError(ctypes.get_last_error())
        return ctypes.string_at(result.pbData, result.cbData)
    finally:
        del source_buffer
        if result.pbData:
            kernel32.LocalFree(result.pbData)


def _validate_key(key: str) -> str:
    try:
        Fernet(key.encode("ascii"))
    except (UnicodeEncodeError, ValueError) as error:
        raise ModelConfigurationStoreError(
            "The Subconscious encryption key is not a valid Fernet key."
        ) from error
    return key
