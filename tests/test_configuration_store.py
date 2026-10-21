import asyncio
import json
from dataclasses import dataclass
from unittest.mock import patch

import pytest
from cryptography.fernet import Fernet

from subconscious_engine.configuration.catalog import build_model_catalog
from subconscious_engine.configuration.errors import ModelConfigurationStoreError
from subconscious_engine.configuration.models import UpsertModelConfigurationRequest
from subconscious_engine.configuration.store import EncryptedModelConfigurationStore


def run(coro):
    return asyncio.run(coro)


@dataclass
class StaticKeyProvider:
    key: str

    def get_or_create_key(self):
        return self.key


def store_at(path, key=None):
    key = key or Fernet.generate_key().decode("ascii")
    return EncryptedModelConfigurationStore(path, StaticKeyProvider(key)), key


def encrypt_file(path, key, value):
    path.mkdir(parents=True, exist_ok=True)
    plaintext = value if isinstance(value, bytes) else json.dumps(value).encode()
    (path / "data.enc").write_bytes(Fernet(key.encode()).encrypt(plaintext))


def test_crud_is_encrypted_redacted_and_resolvable_by_id_or_model(tmp_path):
    async def scenario():
        store, _ = store_at(tmp_path)
        created = await store.create({"provider": " openai ", "model": " gpt-test ",
                                      "alias": " Test ", "contextWindow": 4096,
                                      "apiKey": "top-secret"})
        assert created.provider == "openai" and created.has_api_key
        assert not hasattr(created, "api_key")
        assert b"top-secret" not in (tmp_path / "data.enc").read_bytes()
        assert (await store.list()) == [created]
        by_id = await store.resolve(created.id)
        by_model = await store.resolve("gpt-test")
        assert by_id == by_model
        assert by_id.api_key == "top-secret" and by_id.context_window == 4096
    run(scenario())


def test_update_preserves_or_clears_secret_and_delete_is_idempotent(tmp_path):
    async def scenario():
        store, _ = store_at(tmp_path)
        created = await store.create(UpsertModelConfigurationRequest(
            provider="p", model="m", apiKey="secret"
        ))
        updated = await store.update(created.id, {"provider": "p2", "model": "m2"})
        assert updated.has_api_key is True
        assert (await store.resolve(created.id)).api_key == "secret"
        cleared = await store.update(created.id, {
            "provider": "p2", "model": "m2", "clearApiKey": True
        })
        assert cleared.has_api_key is False
        assert (await store.resolve(created.id)).api_key is None
        assert await store.update("missing", {"provider": "p", "model": "m"}) is None
        assert await store.delete(created.id) is True
        assert await store.delete(created.id) is False
        assert await store.resolve(created.id) is None
    run(scenario())


@pytest.mark.parametrize("payload", [
    {"provider": " ", "model": "m"},
    {"provider": "p", "model": " "},
    {"provider": "p", "model": "m", "contextWindow": 0},
    {"provider": "p", "model": "m", "contextWindow": -1},
    {"provider": 3, "model": "m"},
])
def test_invalid_requests_are_rejected_without_creating_data(tmp_path, payload):
    store, _ = store_at(tmp_path)
    with pytest.raises(ValueError):
        run(store.create(payload))
    assert not (tmp_path / "data.enc").exists()


def test_catalog_uses_alias_without_exposing_credentials_and_adds_echo_only_for_dev(tmp_path):
    store, _ = store_at(tmp_path)
    configured = run(store.create({"provider": "p", "model": "model-x", "alias": "Friendly"}))
    catalog = build_model_catalog(run(store.list()), include_dev_models=True)
    assert [(item.name, item.provider) for item in catalog] == [
        ("Friendly", "p"), ("Echo (dev)", "subconscious")
    ]
    assert catalog[0].id == configured.id and catalog[0].description == "model-x"
    # A production engine never lists the dev-only Echo model.
    production = build_model_catalog(run(store.list()))
    assert [(item.name, item.provider) for item in production] == [("Friendly", "p")]


def test_wrong_key_tampering_and_invalid_plaintext_fail_safely(tmp_path):
    store, key = store_at(tmp_path)
    run(store.create({"provider": "p", "model": "m"}))
    wrong_store, _ = store_at(tmp_path, Fernet.generate_key().decode("ascii"))
    with pytest.raises(ModelConfigurationStoreError, match="authenticated"):
        run(wrong_store.list())

    (tmp_path / "data.enc").write_bytes(b"not-a-fernet-token")
    with pytest.raises(ModelConfigurationStoreError, match="authenticated"):
        run(store.list())

    encrypt_file(tmp_path, key, b"not-json")
    with pytest.raises(ModelConfigurationStoreError, match="invalid decrypted JSON"):
        run(store.list())

    encrypt_file(tmp_path, key, [])
    with pytest.raises(ModelConfigurationStoreError, match="JSON object"):
        run(store.list())


def test_invalid_fernet_key_is_reported_as_store_error(tmp_path):
    store, _ = store_at(tmp_path, "invalid")
    with pytest.raises(ModelConfigurationStoreError, match="valid Fernet key"):
        run(store.create({"provider": "p", "model": "m"}))


def test_tool_auth_supports_legacy_values_updates_and_clear(tmp_path):
    async def scenario():
        store, key = store_at(tmp_path)
        encrypt_file(tmp_path, key, {"tool_api_keys": {"legacy": "token"}})
        assert await store.get_tool_auth_config_ids() == {"legacy"}
        assert json.loads(await store.get_tool_auth_config("legacy")) == {
            "Authorization": "Bearer token"
        }
        assert await store.update_tool_auth_config("legacy", '{"X-Key":"new"}') is True
        assert await store.get_tool_auth_config("legacy") == '{"X-Key":"new"}'
        await store.remove_tool_auth_config("legacy")
        assert await store.get_tool_auth_config("legacy") is None
        assert await store.update_tool_auth_config("unknown", "   ") is False
    run(scenario())


def test_failed_atomic_replace_is_wrapped_and_leaves_no_temporary_file(tmp_path):
    store, _ = store_at(tmp_path)
    with patch("subconscious_engine.configuration.store.os.replace", side_effect=OSError("busy")):
        with pytest.raises(ModelConfigurationStoreError, match="could not be written"):
            run(store.create({"provider": "p", "model": "m"}))
    assert not list(tmp_path.glob(".data.enc.*.tmp"))
