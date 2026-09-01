import asyncio
from contextlib import asynccontextmanager, suppress
import ipaddress
import json
import socket
from unittest.mock import patch

import httpx
import pytest

from subconscious_engine import __version__
from subconscious_engine.config import EngineConfig
from subconscious_engine.host import EngineHost


class FakeIndicator:
    def __init__(self, address):
        self.address = address
        self.on_quit = None
        self.start_calls = 0
        self.stop_calls = 0

    def start(self, on_quit):
        self.on_quit = on_quit
        self.start_calls += 1

    def stop(self):
        self.stop_calls += 1


class IndicatorFactory:
    def __init__(self):
        self.instances = []

    def __call__(self, address):
        indicator = FakeIndicator(address)
        self.instances.append(indicator)
        return indicator


@asynccontextmanager
async def running_host(host):
    task = asyncio.create_task(host.serve())
    try:
        await host.wait_until_ready()
        yield task
    finally:
        host.request_stop()
        await asyncio.wait_for(task, 10)


def run(coroutine):
    return asyncio.run(coroutine)

def test_host_defaults_choose_loopback_ephemeral_or_stable_dev_port(tmp_path):
    production = EngineHost(EngineConfig(data_directory=tmp_path, headless=True))
    development = EngineHost(
        EngineConfig(dev=True, data_directory=tmp_path, headless=True)
    )
    lan = EngineHost(
        EngineConfig(lan_enabled=True, data_directory=tmp_path, headless=True)
    )

    assert production.bind_host == "127.0.0.1"
    assert production.requested_port == 0
    assert development.requested_port == EngineHost.DEVELOPMENT_PORT
    assert development.token.value == EngineHost.DEVELOPMENT_TOKEN
    assert lan.bind_host == "0.0.0.0"
    with pytest.raises(RuntimeError, match="not bound"):
        _ = production.bound_port


def test_real_tcp_host_is_ready_authenticated_discoverable_and_cleans_up(tmp_path):
    async def scenario():
        host = EngineHost(
            EngineConfig(data_directory=tmp_path, headless=True, node_id="node-a")
        )
        async with running_host(host):
            assert host.is_ready is True
            assert host.bound_port > 0
            runtime_path = tmp_path / "runtime.json"
            runtime = json.loads(runtime_path.read_text(encoding="utf-8"))
            assert runtime == {
                "host": "127.0.0.1",
                "port": host.bound_port,
                "token": host.token.value,
                "pid": runtime["pid"],
                "version": __version__,
                "node_id": "node-a",
            }
            async with httpx.AsyncClient(
                base_url=host.address, timeout=5, trust_env=False
            ) as client:
                health = await client.get("health")
                assert health.status_code == 200
                assert health.json() == {"status": "ok", "version": __version__}
                denied = await client.get("workspaces")
                assert denied.status_code == 401
                allowed = await client.get(
                    "workspaces",
                    headers={"Authorization": f"Bearer {host.token.value}"},
                )
                assert allowed.status_code == 200
                assert allowed.json() == []
        assert not (tmp_path / "runtime.json").exists()
        assert host.is_ready is False

    run(scenario())


def test_host_starts_tray_after_readiness_and_tray_quit_stops_server(tmp_path):
    async def scenario():
        factory = IndicatorFactory()
        host = EngineHost(
            EngineConfig(data_directory=tmp_path),
            status_indicator_factory=factory,
        )
        task = asyncio.create_task(host.serve())
        await host.wait_until_ready()
        indicator = factory.instances[-1]
        assert indicator.address == host.address
        assert indicator.start_calls == 1
        assert indicator.on_quit is not None

        indicator.on_quit()
        await asyncio.wait_for(task, 10)
        assert indicator.stop_calls == 1
        assert not (tmp_path / "runtime.json").exists()

    run(scenario())

def test_headless_host_never_constructs_tray_indicator(tmp_path):
    async def scenario():
        factory = IndicatorFactory()
        host = EngineHost(
            EngineConfig(data_directory=tmp_path, headless=True),
            status_indicator_factory=factory,
        )
        async with running_host(host):
            assert factory.instances == []

    run(scenario())


def test_port_conflict_fails_without_publishing_runtime_file(tmp_path):
    blocker = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    blocker.bind(("127.0.0.1", 0))
    blocker.listen(1)
    try:
        port = blocker.getsockname()[1]
        host = EngineHost(
            EngineConfig(port=port, data_directory=tmp_path, headless=True)
        )
        with pytest.raises(OSError):
            run(host.serve())
        assert not (tmp_path / "runtime.json").exists()
    finally:
        blocker.close()


def test_runtime_write_failure_stops_server_and_closes_listener(tmp_path):
    async def scenario():
        host = EngineHost(
            EngineConfig(data_directory=tmp_path, headless=True)
        )
        with patch(
            "subconscious_engine.host.RuntimeInfoWriter.write",
            side_effect=OSError("read only"),
        ):
            with pytest.raises(OSError, match="read only"):
                await asyncio.wait_for(host.serve(), 10)
        assert not (tmp_path / "runtime.json").exists()
        assert host._listener is None
        assert host._server is None

    run(scenario())


def _active_lan_ipv4():
    candidates = []
    route = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        route.connect(("192.0.2.1", 9))
        candidates.append(route.getsockname()[0])
    except OSError:
        pass
    finally:
        route.close()

    with suppress(OSError):
        candidates.extend(
            info[4][0]
            for info in socket.getaddrinfo(
                socket.gethostname(), None, socket.AF_INET, socket.SOCK_STREAM
            )
        )
    for candidate in candidates:
        address = ipaddress.ip_address(candidate)
        if not (
            address.is_loopback
            or address.is_link_local
            or address.is_unspecified
            or address.is_multicast
        ):
            return candidate
    return None

@pytest.mark.lan
def test_lan_server_is_reachable_through_real_non_loopback_interface(tmp_path):
    """Proves all-interface binding by using the machine's actual LAN address."""
    lan_ip = _active_lan_ipv4()
    if lan_ip is None:
        pytest.skip("No active non-loopback IPv4 LAN interface is available")
    assert not ipaddress.ip_address(lan_ip).is_loopback

    async def scenario():
        host = EngineHost(
            EngineConfig(
                lan_enabled=True,
                data_directory=tmp_path,
                headless=True,
            )
        )
        async with running_host(host):
            assert host.bind_host == "0.0.0.0"
            async with httpx.AsyncClient(timeout=5, trust_env=False) as client:
                response = await client.get(
                    f"http://{lan_ip}:{host.bound_port}/api/v1/health"
                )
            assert response.status_code == 200
            assert response.json() == {"status": "ok", "version": __version__}

    run(scenario())
