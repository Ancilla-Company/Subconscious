"""Encrypted, compatibility-preserving model configuration persistence."""

from __future__ import annotations

import asyncio
import builtins
from collections.abc import Callable, Mapping
from contextlib import AbstractContextManager
import json
import os
from pathlib import Path
import tempfile
from threading import RLock
from typing import Any, TypeVar
from uuid import uuid4

from cryptography.fernet import Fernet, InvalidToken
from pydantic import ValidationError

from .errors import ModelConfigurationStoreError
from .key_provider import FernetKeyProvider, PlatformFernetKeyProvider
from .models import ModelConfig, ModelConfigurationDto, UpsertModelConfigurationRequest

T = TypeVar("T")


class _InterprocessFileLock(AbstractContextManager["_InterprocessFileLock"]):
    """Small stdlib-only exclusive lock, supported on Windows and POSIX."""

    def __init__(self, path: Path) -> None:
        self._path = path
        self._file: Any = None

    def __enter__(self) -> "_InterprocessFileLock":
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._file = self._path.open("a+b")
        self._file.seek(0, os.SEEK_END)
        if self._file.tell() == 0:
            self._file.write(b"\0")
            self._file.flush()
        self._file.seek(0)
        if os.name == "nt":
            import msvcrt
            msvcrt.locking(self._file.fileno(), msvcrt.LK_LOCK, 1)
        else:
            import fcntl
            fcntl.flock(self._file.fileno(), fcntl.LOCK_EX)  # type: ignore[attr-defined]
        return self

    def __exit__(self, exc_type: Any, exc_value: Any, traceback: Any) -> None:
        if self._file is None:
            return
        try:
            self._file.seek(0)
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(self._file.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(self._file.fileno(), fcntl.LOCK_UN)  # type: ignore[attr-defined]
        finally:
            self._file.close()
            self._file = None


class EncryptedModelConfigurationStore:
    """CRUD store for the ``models`` object in encrypted ``data.enc``."""

    def __init__(
        self,
        data_directory: str | Path,
        key_provider: FernetKeyProvider | None = None,
    ) -> None:
        self.data_file_path = Path(data_directory) / "data.enc"
        self.lock_file_path = Path(data_directory) / "data.enc.lock"
        self._key_provider = key_provider or PlatformFernetKeyProvider(
            encrypted_data_path=self.data_file_path
        )
        self._thread_lock = RLock()

    async def list(self) -> list[ModelConfigurationDto]:
        return await asyncio.to_thread(self._locked, self._list_unlocked)

    list_async = list

    async def resolve(self, identifier: str) -> ModelConfig | None:
        return await asyncio.to_thread(self._locked, lambda: self._resolve_unlocked(identifier))

    resolve_async = resolve

    async def create(
        self, request: UpsertModelConfigurationRequest | Mapping[str, Any]
    ) -> ModelConfigurationDto:
        body = _coerce_request(request)
        _validate_request(body)
        return await asyncio.to_thread(self._locked, lambda: self._create_unlocked(body))

    create_async = create

    async def update(
        self, identifier: str, request: UpsertModelConfigurationRequest | Mapping[str, Any]
    ) -> ModelConfigurationDto | None:
        body = _coerce_request(request)
        _validate_request(body)
        return await asyncio.to_thread(
            self._locked, lambda: self._update_unlocked(identifier, body)
        )

    update_async = update

    async def delete(self, identifier: str) -> bool:
        return await asyncio.to_thread(self._locked, lambda: self._delete_unlocked(identifier))

    delete_async = delete

    async def get_tool_auth_config_ids(self) -> set[str]:
        def operation() -> set[str]:
            secrets = self._read_unlocked()
            configured = secrets.get("tool_auth_configs")
            legacy = secrets.get("tool_api_keys")
            ids = set(configured) if isinstance(configured, dict) else set()
            if isinstance(legacy, dict):
                ids.update(legacy)
            return ids
        return await asyncio.to_thread(self._locked, operation)

    async def get_tool_auth_config(self, identifier: str) -> str | None:
        def operation() -> str | None:
            secrets = self._read_unlocked()
            configured = secrets.get("tool_auth_configs")
            if isinstance(configured, dict) and isinstance(configured.get(identifier), str):
                return configured[identifier]
            legacy = secrets.get("tool_api_keys")
            value = legacy.get(identifier) if isinstance(legacy, dict) else None
            if isinstance(value, str) and value:
                return json.dumps({"Authorization": f"Bearer {value}"})
            return None
        return await asyncio.to_thread(self._locked, operation)

    async def update_tool_auth_config(
        self, identifier: str, replacement: str | None, clear: bool = False
    ) -> bool:
        def operation() -> bool:
            secrets = self._read_unlocked()
            configured = secrets.setdefault("tool_auth_configs", {})
            if not isinstance(configured, dict):
                configured = {}
                secrets["tool_auth_configs"] = configured
            legacy = secrets.get("tool_api_keys")
            if replacement is not None and replacement.strip():
                configured[identifier] = replacement.strip()
                if isinstance(legacy, dict):
                    legacy.pop(identifier, None)
            elif clear:
                configured.pop(identifier, None)
                if isinstance(legacy, dict):
                    legacy.pop(identifier, None)
            self._write_unlocked(secrets)
            return identifier in configured or (isinstance(legacy, dict) and identifier in legacy)
        return await asyncio.to_thread(self._locked, operation)

    async def remove_tool_auth_config(self, identifier: str) -> None:
        await self.update_tool_auth_config(identifier, None, clear=True)

    def get_account_refresh_token(self) -> str | None:
        """Return the engine-owned cloud refresh token without exposing it via the API."""
        def operation() -> str | None:
            account = self._read_unlocked().get("account_session")
            if not isinstance(account, dict):
                return None
            token = account.get("refresh_token")
            return token if isinstance(token, str) and token else None
        return self._locked(operation)

    def set_account_refresh_token(self, token: str) -> None:
        def operation() -> None:
            secrets = self._read_unlocked()
            account = secrets.setdefault("account_session", {})
            if not isinstance(account, dict):
                account = {}
                secrets["account_session"] = account
            account["refresh_token"] = token
            self._write_unlocked(secrets)
        self._locked(operation)

    def remove_account_refresh_token(self) -> None:
        def operation() -> None:
            secrets = self._read_unlocked()
            if "account_session" in secrets:
                secrets.pop("account_session")
                self._write_unlocked(secrets)
        self._locked(operation)

    def _locked(self, operation: Callable[[], T]) -> T:
        try:
            with self._thread_lock, _InterprocessFileLock(self.lock_file_path):
                return operation()
        except ModelConfigurationStoreError:
            raise
        except OSError as error:
            raise ModelConfigurationStoreError("data.enc could not be accessed.") from error

    def _list_unlocked(self) -> builtins.list[ModelConfigurationDto]:
        models = self._read_unlocked().get("models")
        if not isinstance(models, dict):
            return []
        return [
            _redacted(identifier, value)
            for identifier, value in sorted(models.items(), key=lambda item: item[0])
            if isinstance(value, dict)
        ]

    def _resolve_unlocked(self, identifier: str) -> ModelConfig | None:
        models = self._read_unlocked().get("models")
        if not isinstance(models, dict):
            return None
        exact = models.get(identifier)
        if isinstance(exact, dict):
            return _resolved(identifier, exact)
        for stored_id, value in models.items():
            if isinstance(value, dict) and _string(value, "model") == identifier:
                return _resolved(stored_id, value)
        return None

    def _create_unlocked(self, request: UpsertModelConfigurationRequest) -> ModelConfigurationDto:
        secrets = self._read_unlocked()
        models = _get_or_create_models(secrets)
        identifier = str(uuid4())
        value: dict[str, Any] = {}
        _apply(request, value, is_new=True)
        models[identifier] = value
        self._write_unlocked(secrets)
        return _redacted(identifier, value)

    def _update_unlocked(
        self, identifier: str, request: UpsertModelConfigurationRequest
    ) -> ModelConfigurationDto | None:
        secrets = self._read_unlocked()
        models = _get_or_create_models(secrets)
        value = models.get(identifier)
        if not isinstance(value, dict):
            return None
        _apply(request, value, is_new=False)
        self._write_unlocked(secrets)
        return _redacted(identifier, value)

    def _delete_unlocked(self, identifier: str) -> bool:
        secrets = self._read_unlocked()
        models = _get_or_create_models(secrets)
        if identifier not in models:
            return False
        del models[identifier]
        self._write_unlocked(secrets)
        return True

    def _read_unlocked(self) -> dict[str, Any]:
        if not self.data_file_path.exists():
            return {}
        try:
            encrypted = self.data_file_path.read_bytes()
            plaintext = self._fernet().decrypt(encrypted)
            parsed = json.loads(plaintext.decode("utf-8"))
        except InvalidToken as error:
            raise ModelConfigurationStoreError(
                "data.enc could not be authenticated with the Subconscious encryption key."
            ) from error
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ModelConfigurationStoreError("data.enc contains invalid decrypted JSON.") from error
        except OSError as error:
            raise ModelConfigurationStoreError("data.enc could not be read.") from error
        if not isinstance(parsed, dict):
            raise ModelConfigurationStoreError("data.enc must contain a JSON object.")
        return parsed

    def _write_unlocked(self, secrets: dict[str, Any]) -> None:
        directory = self.data_file_path.parent
        temporary_path: Path | None = None
        try:
            directory.mkdir(parents=True, exist_ok=True)
            plaintext = json.dumps(
                secrets, ensure_ascii=False, separators=(",", ":")
            ).encode("utf-8")
            encrypted = self._fernet().encrypt(plaintext)
            descriptor, name = tempfile.mkstemp(
                prefix=f".{self.data_file_path.name}.", suffix=".tmp", dir=directory
            )
            temporary_path = Path(name)
            try:
                os.chmod(temporary_path, 0o600)
                with os.fdopen(descriptor, "wb") as temporary:
                    temporary.write(encrypted)
                    temporary.flush()
                    os.fsync(temporary.fileno())
            except BaseException:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
                raise
            os.replace(temporary_path, self.data_file_path)
            temporary_path = None
            if os.name != "nt":
                directory_descriptor = os.open(directory, os.O_RDONLY)
                try:
                    os.fsync(directory_descriptor)
                finally:
                    os.close(directory_descriptor)
        except OSError as error:
            raise ModelConfigurationStoreError("data.enc could not be written.") from error
        finally:
            if temporary_path is not None:
                try:
                    temporary_path.unlink(missing_ok=True)
                except OSError:
                    pass

    def _fernet(self) -> Fernet:
        try:
            return Fernet(self._key_provider.get_or_create_key().encode("ascii"))
        except ModelConfigurationStoreError:
            raise
        except (UnicodeEncodeError, ValueError) as error:
            raise ModelConfigurationStoreError(
                "The Subconscious encryption key is not a valid Fernet key."
            ) from error


def _coerce_request(
    request: UpsertModelConfigurationRequest | Mapping[str, Any],
) -> UpsertModelConfigurationRequest:
    if isinstance(request, UpsertModelConfigurationRequest):
        return request
    try:
        return UpsertModelConfigurationRequest.model_validate(request)
    except ValidationError as error:
        raise ValueError("Invalid model configuration.") from error


def _validate_request(request: UpsertModelConfigurationRequest) -> None:
    if not request.provider.strip():
        raise ValueError("Provider is required.")
    if not request.model.strip():
        raise ValueError("Model is required.")
    if request.context_window is not None and request.context_window <= 0:
        raise ValueError("Context window must be a positive number of tokens.")


def _get_or_create_models(secrets: dict[str, Any]) -> dict[str, Any]:
    models = secrets.get("models")
    if isinstance(models, dict):
        return models
    created: dict[str, Any] = {}
    secrets["models"] = created
    return created


def _apply(
    request: UpsertModelConfigurationRequest,
    model: dict[str, Any],
    *,
    is_new: bool,
) -> None:
    model["provider"] = request.provider.strip()
    model["model"] = request.model.strip()
    model["alias"] = request.alias.strip() if request.alias is not None else ""
    model["base_url"] = request.base_url.strip() if request.base_url is not None else ""
    model["region"] = request.region.strip() if request.region is not None else ""
    if request.context_window is None:
        model.pop("context_window", None)
    else:
        # Preserve the legacy Python/Flet text representation.
        model["context_window"] = str(request.context_window)

    if request.api_key is not None:
        model["api_key"] = request.api_key
    elif request.clear_api_key:
        model.pop("api_key", None)
    elif is_new:
        model["api_key"] = ""

    credentials = {
        "aws_access_key_id": request.aws_access_key_id,
        "aws_secret_access_key": request.aws_secret_access_key,
        "aws_session_token": request.aws_session_token,
    }
    for field, value in credentials.items():
        if value is not None:
            model[field] = value
        elif is_new:
            model[field] = ""


def _redacted(identifier: str, model: dict[str, Any]) -> ModelConfigurationDto:
    api_key = _string(model, "api_key")
    return ModelConfigurationDto(
        id=identifier,
        provider=_string(model, "provider") or "",
        model=_string(model, "model") or "",
        alias=_string(model, "alias"),
        baseUrl=_string(model, "base_url"),
        region=_string(model, "region"),
        contextWindow=_integer(model, "context_window"),
        hasApiKey=bool(api_key and api_key.strip()),
    )


def _resolved(identifier: str, model: dict[str, Any]) -> ModelConfig:
    known_fields = {
        "provider", "model", "api_key", "system_prompt", "base_url", "region",
        "aws_access_key_id", "aws_secret_access_key", "aws_session_token",
        "context_window", "stream_timeout_seconds",
    }
    return ModelConfig(
        id=identifier,
        provider=_string(model, "provider") or "",
        model=_string(model, "model") or "",
        api_key=_string(model, "api_key"),
        system_prompt=_string(model, "system_prompt"),
        base_url=_string(model, "base_url"),
        region=_string(model, "region"),
        aws_access_key_id=_string(model, "aws_access_key_id"),
        aws_secret_access_key=_string(model, "aws_secret_access_key"),
        aws_session_token=_string(model, "aws_session_token"),
        context_window=_integer(model, "context_window"),
        stream_timeout_seconds=_number(model, "stream_timeout_seconds"),
        extra={key: value for key, value in model.items() if key not in known_fields},
    )


def _string(source: dict[str, Any], key: str) -> str | None:
    value = source.get(key)
    return value if isinstance(value, str) else None


def _integer(source: dict[str, Any], key: str) -> int | None:
    value = source.get(key)
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            return None
    return None


def _number(source: dict[str, Any], key: str) -> float | None:
    value = source.get(key)
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None
