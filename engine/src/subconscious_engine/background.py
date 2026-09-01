"""Desktop status indicator for the background engine process."""

from collections.abc import Callable
from typing import Protocol
import warnings


class BackgroundStatusIndicator(Protocol):
    def start(self, on_quit: Callable[[], None]) -> None: ...

    def stop(self) -> None: ...


def _icon_image():
    from PIL import Image, ImageDraw

    image = Image.new("RGBA", (64, 64), (20, 24, 33, 255))
    draw = ImageDraw.Draw(image)
    draw.ellipse((7, 7, 57, 57), fill=(89, 73, 255, 255))
    draw.ellipse((20, 18, 44, 42), fill=(255, 255, 255, 255))
    draw.rectangle((28, 36, 36, 52), fill=(255, 255, 255, 255))
    return image


class SystemTrayStatusIndicator:
    """Shows a tray icon with endpoint status and a graceful Quit action."""

    def __init__(self, address: str) -> None:
        self.address = address
        self._icon = None

    def start(self, on_quit: Callable[[], None]) -> None:
        try:
            import pystray

            def quit_engine(icon, _item) -> None:
                on_quit()
                icon.stop()
                self._icon = None

            menu = pystray.Menu(
                pystray.MenuItem(f"Running at {self.address}", None, enabled=False),
                pystray.MenuItem("Quit", quit_engine),
            )
            self._icon = pystray.Icon(
                "subconscious-engine", _icon_image(), "Subconscious Engine", menu
            )
            self._icon.run_detached()
        except Exception as error:
            self._icon = None
            warnings.warn(f"System tray icon could not be started: {error}", RuntimeWarning)

    def stop(self) -> None:
        if self._icon is not None:
            self._icon.stop()
            self._icon = None
