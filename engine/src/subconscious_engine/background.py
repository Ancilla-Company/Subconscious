"""Desktop status indicator for the background engine process."""

from collections.abc import Callable
from importlib.resources import files
import shlex
import subprocess
import sys
from threading import RLock
from typing import Protocol
import warnings
import webbrowser

from . import __version__
from .desktop_launcher import launch_desktop_app

LaunchAction = Callable[[str, str], None]

PROJECT_URL = "https://subconscious.chat/"
DOCUMENTATION_URL = "https://github.com/Ancilla-Company/Subconscious#readme"
LICENSE_URL = "https://github.com/Ancilla-Company/Subconscious/blob/main/LICENSE"
ISSUES_URL = "https://github.com/Ancilla-Company/Subconscious/issues"


class BackgroundStatusIndicator(Protocol):
    def start(self, on_quit: Callable[[], None], token: str) -> None: ...

    def set_clients(self, clients: tuple[str, ...]) -> None: ...

    def stop(self) -> None: ...


def build_join_command(address: str, token: str) -> str:
    """Build a shell command that launches the desktop client for this engine."""
    arguments = [
        "subconscious",
        "desktop",
        "--engine-url",
        address,
        "--token",
        token,
    ]
    if sys.platform == "win32":
        return subprocess.list2cmdline(arguments)
    return shlex.join(arguments)


def _copy_to_clipboard(text: str) -> None:
    import tkinter

    root = tkinter.Tk()
    try:
        root.withdraw()
        root.clipboard_clear()
        root.clipboard_append(text)
        root.update()
    finally:
        root.destroy()


def _desktop_stub(_address: str, _token: str) -> None:
    warnings.warn("Desktop UI launch support is not implemented yet.", RuntimeWarning)


def _browser_stub(_address: str, _token: str) -> None:
    warnings.warn("Browser launch support is not implemented yet.", RuntimeWarning)


def _web_ui_stub(_address: str, _token: str) -> None:
    warnings.warn("Web UI launch support is not implemented yet.", RuntimeWarning)


def _icon_image():
    from PIL import Image

    icon_resource = files("subconscious_engine").joinpath("app_icon.ico")
    with icon_resource.open("rb") as icon_stream:
        image = Image.open(icon_stream)
        image.load()
    return image


class SystemTrayStatusIndicator:
    """Shows engine status and client actions in the system tray."""

    def __init__(
        self,
        address: str,
        *,
        local_address: str | None = None,
        lan_enabled: bool = False,
        dev: bool = False,
        copy_text: Callable[[str], None] | None = None,
        open_desktop: LaunchAction | None = None,
        open_browser: LaunchAction | None = None,
        open_web_ui: LaunchAction | None = None,
        open_url: Callable[[str], object] | None = None,
    ) -> None:
        self.address = address
        self.local_address = local_address or address
        self.lan_enabled = lan_enabled
        self.dev = dev
        self._copy_text = copy_text or _copy_to_clipboard
        self._open_desktop = open_desktop or launch_desktop_app
        self._open_browser = open_browser or _browser_stub
        self._open_web_ui = open_web_ui or _web_ui_stub
        self._open_url = open_url or webbrowser.open
        self._clients: tuple[str, ...] = ()
        self._lock = RLock()
        self._icon = None

    def start(self, on_quit: Callable[[], None], token: str) -> None:
        try:
            import pystray

            def tray_action(label: str, action: Callable[[], None]):
                def invoke(_icon, _item) -> None:
                    try:
                        action()
                    except Exception as error:
                        warnings.warn(
                            f"Tray action '{label}' failed: {error}", RuntimeWarning
                        )

                return invoke

            def quit_engine(icon, _item) -> None:
                on_quit()
                icon.stop()
                with self._lock:
                    if self._icon is icon:
                        self._icon = None

            def connected_clients():
                with self._lock:
                    clients = self._clients
                if not clients:
                    return (
                        pystray.MenuItem(
                            "No connected clients", None, enabled=False
                        ),
                    )
                return tuple(
                    pystray.MenuItem(client, None, enabled=False)
                    for client in clients
                )

            def link_item(label: str, url: str):
                return pystray.MenuItem(
                    label,
                    tray_action(label, lambda: self._open_url(url)),
                )

            join_command = build_join_command(self.address, token)
            clients_menu = pystray.Menu(connected_clients)
            open_menu = pystray.Menu(
                pystray.MenuItem(
                    "Desktop",
                    tray_action(
                        "Open Desktop",
                        lambda: self._open_desktop(self.address, token),
                    ),
                ),
                pystray.MenuItem(
                    "Browser",
                    tray_action(
                        "Open Browser",
                        lambda: self._open_browser(self.address, token),
                    ),
                ),
                pystray.MenuItem(
                    "Web",
                    tray_action(
                        "Open Web UI",
                        lambda: self._open_web_ui(self.address, token),
                    ),
                ),
            )
            help_menu = pystray.Menu(
                link_item("Subconscious.chat", PROJECT_URL),
                link_item("Documentation", DOCUMENTATION_URL),
                link_item("Report an Issue", ISSUES_URL),
            )
            about_menu = pystray.Menu(
                pystray.MenuItem("Subconscious", None, enabled=False),
                pystray.MenuItem(
                    "Distributed agentic AI for every device",
                    None,
                    enabled=False,
                ),
                pystray.MenuItem(
                    f"Engine version: {__version__}",
                    None,
                    enabled=False,
                ),
                pystray.MenuItem("© 2026 Subconscious", None, enabled=False),
                pystray.Menu.SEPARATOR,
                link_item("View License", LICENSE_URL),
            )
            lan_status = (
                (
                    pystray.MenuItem(
                        f"LAN: {self.address}", None, enabled=False
                    ),
                )
                if self.lan_enabled
                else ()
            )
            menu = pystray.Menu(
                pystray.MenuItem(
                    f"Subconscious\t{__version__}", None, enabled=False
                ),
                pystray.Menu.SEPARATOR,
                *lan_status,
                pystray.MenuItem(
                    f"Local: {self.local_address}", None, enabled=False
                ),
                pystray.MenuItem(
                    f"Mode: {'Dev' if self.dev else 'Live'}",
                    None,
                    enabled=False,
                ),
                pystray.Menu.SEPARATOR,
                pystray.MenuItem(
                    "Copy Join Command",
                    tray_action(
                        "Copy Join Command",
                        lambda: self._copy_text(join_command),
                    ),
                ),
                pystray.MenuItem("Connected Clients", clients_menu),
                pystray.Menu.SEPARATOR,
                pystray.MenuItem("Open", open_menu),
                pystray.MenuItem("Help", help_menu),
                pystray.MenuItem("About", about_menu),
                pystray.Menu.SEPARATOR,
                pystray.MenuItem(
                    "Open Desktop",
                    tray_action(
                        "Open Desktop",
                        lambda: self._open_desktop(self.address, token),
                    ),
                    default=True,
                    visible=False,
                ),
                pystray.MenuItem("Quit", quit_engine),
            )
            icon = pystray.Icon(
                "subconscious-engine", _icon_image(), "Subconscious Engine", menu
            )
            with self._lock:
                self._icon = icon
            icon.run_detached()
        except Exception as error:
            with self._lock:
                self._icon = None
            warnings.warn(f"System tray icon could not be started: {error}", RuntimeWarning)

    def set_clients(self, clients: tuple[str, ...]) -> None:
        normalized = tuple(clients)
        with self._lock:
            if normalized == self._clients:
                return
            self._clients = normalized
            icon = self._icon
        if icon is not None:
            try:
                icon.update_menu()
            except Exception as error:
                warnings.warn(
                    f"Connected-client tray menu could not be updated: {error}",
                    RuntimeWarning,
                )

    def stop(self) -> None:
        with self._lock:
            icon = self._icon
            self._icon = None
        if icon is not None:
            icon.stop()
