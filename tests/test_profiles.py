import asyncio
from dataclasses import replace

import httpx
import pytest

from subconscious_engine.account import AccountUser
from subconscious_engine.config import EngineConfig
from subconscious_engine.host import EngineHost
from subconscious_engine.profiles import (
    DEFAULT_PROFILE_ID,
    ProfileManager,
    ProfileRegistry,
    profile_id_for_email,
)
from subconscious_engine.hive.identity import KeyringIdentitySeedStore
from subconscious_engine.account import KeyringRefreshTokenStore


def _user(email: str) -> AccountUser:
    return AccountUser(id=f"id-{email}", email=email, connected_providers=())


def test_registry_default_is_unowned_until_claimed_and_owner_is_never_replaced(tmp_path):
    registry = ProfileRegistry(tmp_path)
    assert registry.default().email is None
    assert registry.default().directory == tmp_path
    registry.bind(DEFAULT_PROFILE_ID, "A@Example.com")
    registry.bind(DEFAULT_PROFILE_ID, "b@example.com")
    assert ProfileRegistry(tmp_path).default().email == "a@example.com"
    assert registry.find_by_email(" a@EXAMPLE.com ").id == DEFAULT_PROFILE_ID


def test_other_emails_get_their_own_stable_subdirectory(tmp_path):
    registry = ProfileRegistry(tmp_path)
    registry.bind(DEFAULT_PROFILE_ID, "a@example.com")
    pending = registry.pending_for("b@example.com")
    assert pending.id == profile_id_for_email("B@example.com")
    assert pending.directory == tmp_path / "profiles" / pending.id


def test_keyring_entries_are_namespaced_per_profile(monkeypatch):
    stored: dict[tuple[str, str], str] = {}
    monkeypatch.setattr("keyring.set_password", lambda s, u, p: stored.__setitem__((s, u), p))
    monkeypatch.setattr("keyring.get_password", lambda s, u: stored.get((s, u)))
    KeyringRefreshTokenStore().write("one")
    KeyringRefreshTokenStore("u-1").write("two")
    assert KeyringRefreshTokenStore().read() == "one"
    assert KeyringRefreshTokenStore("u-1").read() == "two"
    KeyringIdentitySeedStore().write("seed-a")
    KeyringIdentitySeedStore("u-1").write("seed-b")
    assert KeyringIdentitySeedStore().read() == "seed-a"
    assert KeyringIdentitySeedStore("u-1").read() == "seed-b"


class _NoTray:
    def __init__(self, *args, **kwargs):
        self.clients = ()

    def start(self, on_quit, token):
        pass

    def set_clients(self, clients):
        self.clients = clients

    def stop(self):
        pass


def _factory(config, **context):
    return EngineHost(config, _NoTray, **context)


def test_second_account_gets_its_own_instance_and_data_directory(tmp_path):
    asyncio.run(_second_account_scenario(tmp_path))


async def _second_account_scenario(tmp_path):
    config = EngineConfig(
        port=0,
        data_directory=tmp_path,
        headless=True,
        hive=replace(EngineConfig().hive, enabled=False),
    )
    manager = ProfileManager(config, host_factory=_factory)
    serving = asyncio.ensure_future(manager.serve())
    try:
        await manager.default_host.wait_until_ready()
        # The first sign-in claims the default profile.
        first = await manager.route(DEFAULT_PROFILE_ID, "a@example.com")
        assert first.profile.id == DEFAULT_PROFILE_ID and not first.switched
        manager.default_host.account_session_service._set_user(_user("a@example.com"))
        assert manager.registry.default().email == "a@example.com"

        # Another email is routed to a separate instance in profiles/<id>.
        second = await manager.route(DEFAULT_PROFILE_ID, "b@example.com")
        assert second.switched and second.host is not manager.default_host
        assert second.host.config.resolved_data_directory == second.profile.directory
        assert second.profile.directory.parent == tmp_path / "profiles"
        assert second.host.bound_port != manager.default_host.bound_port
        assert (second.profile.directory / "runtime.json").exists()
        assert second.host.token.value != manager.default_host.token.value

        # Same email again reuses the running instance; the owner keeps the default.
        again = await manager.route(DEFAULT_PROFILE_ID, "B@example.com")
        assert again.host is second.host
        back = await manager.route(second.profile.id, "a@example.com")
        assert back.host is manager.default_host and back.switched

        # Instances are reachable and isolated: each serves its own database.
        async with httpx.AsyncClient() as client:
            for target in (manager.default_host, second.host):
                response = await client.get(
                    f"http://127.0.0.1:{target.bound_port}/api/v1/profiles",
                    headers={"Authorization": f"Bearer {target.token.value}"},
                )
                assert response.status_code == 200
                assert response.json()["current"] == target.profile_id
        assert second.host.database.path != manager.default_host.database.path

        # A failed sign-in does not leave an unclaimed instance running.
        third = await manager.route(DEFAULT_PROFILE_ID, "c@example.com")
        await manager.abandon_if_unclaimed(third.profile)
        assert third.profile.id not in manager.hosts
    finally:
        manager.default_host.request_stop()
        await asyncio.wait_for(serving, 30)
    assert set(manager.hosts) == {DEFAULT_PROFILE_ID}
    assert not (second.profile.directory / "runtime.json").exists()
