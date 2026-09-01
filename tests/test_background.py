from types import SimpleNamespace
from unittest.mock import Mock, patch

import pytest

from subconscious_engine.background import SystemTrayStatusIndicator, _icon_image


class FakeMenuItem:
    def __init__(self, text, action, enabled=True):
        self.text = text
        self.action = action
        self.enabled = enabled


class FakeIcon:
    instances = []

    def __init__(self, name, image, title, menu):
        self.name = name
        self.image = image
        self.title = title
        self.menu = menu
        self.detached = False
        self.stop_calls = 0
        self.instances.append(self)

    def run_detached(self):
        self.detached = True

    def stop(self):
        self.stop_calls += 1


def fake_pystray():
    return SimpleNamespace(
        Menu=lambda *items: items,
        MenuItem=FakeMenuItem,
        Icon=FakeIcon,
    )


def test_generated_tray_icon_has_expected_size_and_brand_colors():
    image = _icon_image()
    assert image.size == (64, 64)
    assert image.mode == "RGBA"
    assert image.getpixel((0, 0)) == (20, 24, 33, 255)
    assert image.getpixel((32, 32)) == (255, 255, 255, 255)

def test_tray_starts_detached_displays_endpoint_and_quits_gracefully():
    FakeIcon.instances.clear()
    on_quit = Mock()
    indicator = SystemTrayStatusIndicator("http://192.168.1.5:8123/api/v1/")

    with patch.dict("sys.modules", {"pystray": fake_pystray()}):
        indicator.start(on_quit)

    icon = FakeIcon.instances[-1]
    assert icon.detached is True
    assert icon.name == "subconscious-engine"
    assert icon.title == "Subconscious Engine"
    status, quit_item = icon.menu
    assert status.text == "Running at http://192.168.1.5:8123/api/v1/"
    assert status.enabled is False and status.action is None
    assert quit_item.text == "Quit"

    quit_item.action(icon, None)
    on_quit.assert_called_once_with()
    assert icon.stop_calls == 1

    indicator.stop()
    assert icon.stop_calls == 1


def test_stop_is_idempotent_after_normal_start():
    FakeIcon.instances.clear()
    indicator = SystemTrayStatusIndicator("http://127.0.0.1:1/api/v1/")
    with patch.dict("sys.modules", {"pystray": fake_pystray()}):
        indicator.start(Mock())
    icon = FakeIcon.instances[-1]

    indicator.stop()
    indicator.stop()
    assert icon.stop_calls == 1


def test_missing_desktop_backend_warns_without_crashing_engine():
    indicator = SystemTrayStatusIndicator("http://127.0.0.1:1/api/v1/")
    with patch.dict("sys.modules", {"pystray": None}):
        with pytest.warns(RuntimeWarning, match="could not be started"):
            indicator.start(Mock())
    indicator.stop()
