from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import Mock, patch

import pytest

from subconscious_engine import __version__
from subconscious_engine.client_identity import ClientInfo
from subconscious_engine.background import (
    DOCUMENTATION_URL,
    ISSUES_URL,
    LICENSE_URL,
    PROJECT_URL,
    SystemTrayStatusIndicator,
    _icon_image,
    build_join_command,
)


class FakeMenuItem:
    def __init__(
        self,
        text,
        action,
        enabled=True,
        default=False,
        visible=True,
    ):
        self.text = text
        self.action = action
        self.enabled = enabled
        self.default = default
        self.visible = visible


class FakeMenu(tuple):
    SEPARATOR = object()

    def __new__(cls, *items):
        return super().__new__(cls, items)


class FakeIcon:
    instances = []

    def __init__(self, name, image, title, menu):
        self.name = name
        self.image = image
        self.title = title
        self.menu = menu
        self.detached = False
        self.stop_calls = 0
        self.update_menu_calls = 0
        self.instances.append(self)

    def run_detached(self):
        self.detached = True

    def update_menu(self):
        self.update_menu_calls += 1

    def stop(self):
        self.stop_calls += 1


def fake_pystray():
    return SimpleNamespace(
        Menu=FakeMenu,
        MenuItem=FakeMenuItem,
        Icon=FakeIcon,
    )


def menu_items(menu):
    if len(menu) == 1 and callable(menu[0]):
        return tuple(menu[0]())
    return tuple(menu)


def test_bundled_tray_icon_is_loadable():
    image = _icon_image()
    assert image.format == "ICO"
    assert image.width > 0
    assert image.height > 0


def test_tray_exposes_status_top_level_actions_and_separate_help_about_menus():
    FakeIcon.instances.clear()
    on_quit = Mock()
    copy_text = Mock()
    open_desktop = Mock()
    open_browser = Mock()
    open_web_ui = Mock()
    open_url = Mock()
    address = "http://192.168.1.5:8123/api/v1/"
    local_address = "http://localhost:8123/api/v1/"
    token = "join-secret"
    indicator = SystemTrayStatusIndicator(
        address,
        local_address=local_address,
        lan_enabled=True,
        dev=True,
        copy_text=copy_text,
        open_desktop=open_desktop,
        open_browser=open_browser,
        open_web_ui=open_web_ui,
        open_url=open_url,
    )

    with patch.dict("sys.modules", {"pystray": fake_pystray()}):
        indicator.start(on_quit, token)

    icon = FakeIcon.instances[-1]
    assert icon.detached is True
    assert icon.name == "subconscious-engine"
    assert icon.title == "Subconscious Engine"
    (
        brand,
        brand_separator,
        lan_status,
        local_status,
        mode_status,
        status_separator,
        copy_join,
        connected_clients,
        action_separator,
        open_item,
        help_item,
        about_item,
        quit_separator,
        default_desktop,
        quit_item,
    ) = menu_items(icon.menu)
    assert brand.text == f"Subconscious\t{__version__}"
    assert brand.enabled is False
    assert brand_separator is FakeMenu.SEPARATOR
    assert lan_status.text == f"LAN: {address}"
    assert local_status.text == f"Local: {local_address}"
    assert mode_status.text == "Mode: Dev"
    assert all(
        item.enabled is False for item in (lan_status, local_status, mode_status)
    )
    assert status_separator is FakeMenu.SEPARATOR
    assert action_separator is FakeMenu.SEPARATOR
    assert quit_separator is FakeMenu.SEPARATOR

    assert copy_join.text == "Copy Join Command"
    copy_join.action(icon, None)
    copy_text.assert_called_once_with(build_join_command(address, token))
    assert connected_clients.text == "Connected Clients"
    empty_client, = menu_items(connected_clients.action)
    assert empty_client.text == "No clients connected"
    assert empty_client.enabled is False

    indicator.set_clients((
        ClientInfo("a", "mobile", "Mobile", "", "192.168.1.5", datetime.now(timezone.utc), False),
        ClientInfo("d", "desktop", "Desktop", "", "127.0.0.1", datetime.now(timezone.utc), True),
    ))
    assert icon.update_menu_calls == 1
    client_items = menu_items(connected_clients.action)
    assert [item.text for item in client_items] == [
        "Desktop (local)", "Mobile (remote, 192.168.1.5)"
    ]
    assert all(item.enabled is False for item in client_items)

    assert open_item.text == "Open"
    desktop, browser, web = menu_items(open_item.action)
    assert [item.text for item in (desktop, browser, web)] == [
        "Desktop",
        "Browser",
        "Web",
    ]
    desktop.action(icon, None)
    browser.action(icon, None)
    web.action(icon, None)
    open_desktop.assert_called_once_with(address, token)
    open_browser.assert_called_once_with(address, token)
    open_web_ui.assert_called_once_with(address, token)
    assert default_desktop.default is True
    assert default_desktop.visible is False

    assert help_item.text == "Help"
    website, docs, issues = menu_items(help_item.action)
    for item in (website, docs, issues):
        item.action(icon, None)

    assert about_item.text == "About"
    product, description, version, copyright_item, about_separator, license_item = (
        menu_items(about_item.action)
    )
    assert product.text == "Subconscious"
    assert description.text == "Distributed agentic AI for every device"
    assert version.text == f"Engine version: {__version__}"
    assert copyright_item.text == "© 2026 Subconscious"
    assert all(
        item.enabled is False
        for item in (product, description, version, copyright_item)
    )
    assert about_separator is FakeMenu.SEPARATOR
    license_item.action(icon, None)
    assert [call.args[0] for call in open_url.call_args_list] == [
        PROJECT_URL,
        DOCUMENTATION_URL,
        ISSUES_URL,
        LICENSE_URL,
    ]

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
        indicator.start(Mock(), "secret")
    icon = FakeIcon.instances[-1]

    indicator.stop()
    indicator.stop()
    assert icon.stop_calls == 1


def test_missing_desktop_backend_warns_without_crashing_engine():
    indicator = SystemTrayStatusIndicator("http://127.0.0.1:1/api/v1/")
    with patch.dict("sys.modules", {"pystray": None}):
        with pytest.warns(RuntimeWarning, match="could not be started"):
            indicator.start(Mock(), "secret")
    indicator.stop()
