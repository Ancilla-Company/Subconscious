from pathlib import Path
from unittest.mock import patch

from subconscious_engine.__main__ import build_parser, main


class FakeHost:
    instances = []

    def __init__(self, config):
        self.config = config
        self.served = False
        self.instances.append(self)

    async def serve(self):
        self.served = True


def test_parser_exposes_network_tray_identity_and_storage_options(tmp_path):
    args = build_parser().parse_args(
        [
            "--dev",
            "--port",
            "8123",
            "--lan",
            "--headless",
            "--node-id",
            "node-a",
            "--data-dir",
            str(tmp_path),
        ]
    )
    assert args.dev is True
    assert args.port == 8123
    assert args.lan is True
    assert args.headless is True
    assert args.node_id == "node-a"
    assert args.data_dir == tmp_path


def test_main_builds_config_and_runs_host(tmp_path):
    FakeHost.instances.clear()
    with patch("subconscious_engine.__main__.EngineHost", FakeHost):
        main(
            [
                "--dev",
                "--lan",
                "--headless",
                "--port",
                "9000",
                "--node-id",
                "test-node",
                "--data-dir",
                str(tmp_path),
            ]
        )

    host = FakeHost.instances[-1]
    assert host.served is True
    assert host.config.dev is True
    assert host.config.headless is True
    assert host.config.lan_enabled is True
    assert host.config.port == 9000
    assert host.config.node_id == "test-node"
    assert host.config.data_directory == Path(tmp_path)


def test_main_treats_keyboard_interrupt_as_graceful_shutdown(tmp_path):
    def interrupt(coroutine):
        coroutine.close()
        raise KeyboardInterrupt

    with patch("subconscious_engine.__main__.EngineHost", FakeHost), patch(
        "subconscious_engine.__main__.asyncio.run", side_effect=interrupt
    ):
        main(["--data-dir", str(tmp_path), "--headless"])
