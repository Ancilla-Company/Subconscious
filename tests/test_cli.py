from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from subconscious_engine.__main__ import LOGO, build_parser, main


class FakeHost:
    instances = []

    def __init__(self, config, **_profile_context):
        self.config = config
        self.served = False
        self.instances.append(self)

    async def serve(self):
        self.served = True


def test_parser_exposes_detached_tray_network_identity_and_storage_options(tmp_path):
    args = build_parser().parse_args(
        [
            "start",
            "--dev",
            "--port",
            "8123",
            "--lan",
            "--node-id",
            "node-a",
            "--data-dir",
            str(tmp_path),
            "--detached",
            "--no-tray",
            "--service-child",
        ]
    )
    assert args.command == "start"
    assert args.dev is True
    assert args.port == 8123
    assert args.lan is True
    assert args.node_id == "node-a"
    assert args.data_dir == tmp_path
    assert args.detached is True
    assert args.no_tray is True
    assert args.service_child is True


def test_main_without_command_prints_logo_and_help(capsys):
    assert main([]) == 0
    output = capsys.readouterr()
    assert LOGO.strip() in output.out
    assert "usage: subconscious" in output.out
    assert "start" in output.out
    assert output.err == ""


def test_main_builds_config_and_runs_service_child_without_logo(tmp_path, capsys):
    FakeHost.instances.clear()
    with patch("subconscious_engine.__main__.EngineHost", FakeHost):
        result = main(
            [
                "start",
                "--dev",
                "--lan",
                "--port",
                "9000",
                "--node-id",
                "test-node",
                "--data-dir",
                str(tmp_path),
                "--detached",
                "--no-tray",
                "--service-child",
            ]
        )

    output = capsys.readouterr()
    assert LOGO.strip() not in output.out
    assert result == 0
    host = FakeHost.instances[-1]
    assert host.served is True
    assert host.config.dev is True
    assert host.config.headless is True
    assert host.config.lan_enabled is True
    assert host.config.port == 9000
    assert host.config.node_id == "test-node"
    assert host.config.data_directory == Path(tmp_path)


def test_detached_spawns_background_child_without_implicitly_hiding_tray(tmp_path):
    process = SimpleNamespace(pid=42)
    with patch("subconscious_engine.__main__.subprocess.Popen", return_value=process) as popen:
        assert main(["start", "--detached", "--data-dir", str(tmp_path)]) == 0

    command = popen.call_args.args[0]
    assert command[-2:] == ["--detached", "--service-child"]
    assert "--no-tray" not in command
    assert popen.call_args.kwargs["stdout"] is not None


def test_desktop_stub_accepts_copied_join_command_arguments_without_logo(capsys):
    args = build_parser().parse_args(
        [
            "desktop",
            "--engine-url",
            "http://192.168.1.5:8123/api/v1/",
            "--token",
            "secret",
        ]
    )
    assert args.command == "desktop"
    assert args.engine_url == "http://192.168.1.5:8123/api/v1/"
    assert args.token == "secret"
    assert main(
        [
            "desktop",
            "--engine-url",
            "http://192.168.1.5:8123/api/v1/",
            "--token",
            "secret",
        ]
    ) == 1
    output = capsys.readouterr()
    assert LOGO.strip() not in output.out
    assert "not implemented yet" in output.err


def test_main_treats_keyboard_interrupt_as_graceful_shutdown(tmp_path):
    def interrupt(coroutine):
        coroutine.close()
        raise KeyboardInterrupt

    with patch("subconscious_engine.__main__.EngineHost", FakeHost), patch(
        "subconscious_engine.__main__.asyncio.run", side_effect=interrupt
    ):
        assert main(["start", "--data-dir", str(tmp_path)]) == 0
