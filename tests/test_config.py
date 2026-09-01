from pathlib import Path
from unittest.mock import patch

import pytest

from subconscious_engine.config import EngineConfig


def test_explicit_data_directory_wins_and_dev_uses_isolated_suffix(tmp_path):
    assert EngineConfig(data_directory=tmp_path).resolved_data_directory == tmp_path
    assert EngineConfig(
        dev=True, data_directory=tmp_path
    ).resolved_data_directory == Path(f"{tmp_path}-dev")


def test_windows_data_directory_uses_appdata():
    with patch("subconscious_engine.config.sys.platform", "win32"), patch.dict(
        "os.environ", {"APPDATA": r"C:\Users\Test\AppData\Roaming"}, clear=True
    ):
        assert EngineConfig().resolved_data_directory == Path(
            r"C:\Users\Test\AppData\Roaming\Subconscious"
        )


def test_macos_data_directory_uses_application_support():
    with patch("subconscious_engine.config.sys.platform", "darwin"), patch(
        "subconscious_engine.config.Path.home", return_value=Path("/Users/test")
    ):
        assert EngineConfig().resolved_data_directory == Path(
            "/Users/test/Library/Application Support/Subconscious"
        )


def test_linux_data_directory_prefers_xdg_config_home():
    with patch("subconscious_engine.config.sys.platform", "linux"), patch.dict(
        "os.environ", {"XDG_CONFIG_HOME": "/var/test-config"}, clear=True
    ):
        assert EngineConfig().resolved_data_directory == Path(
            "/var/test-config/subconscious"
        )


@pytest.mark.parametrize(
    ("field", "expected"),
    [
        ("dev", False),
        ("api", True),
        ("gui", False),
        ("tui", False),
        ("headless", False),
        ("port", 0),
        ("lan_enabled", False),
        ("node_id", None),
        ("data_directory", None),
    ],
)
def test_default_configuration_is_loopback_desktop_safe(field, expected):
    assert getattr(EngineConfig(), field) == expected
