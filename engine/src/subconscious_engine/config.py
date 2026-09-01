"""Engine startup configuration matching the .NET composition root."""

from dataclasses import dataclass
import os
from pathlib import Path
import sys


@dataclass(frozen=True, slots=True)
class EngineConfig:
    dev: bool = False
    api: bool = True
    gui: bool = False
    tui: bool = False
    headless: bool = False
    port: int = 0
    lan_enabled: bool = False
    node_id: str | None = None
    data_directory: Path | None = None

    @property
    def resolved_data_directory(self) -> Path:
        if self.data_directory is not None:
            base = self.data_directory
        elif sys.platform == "win32":
            app_data = os.getenv("APPDATA")
            base = (
                Path(app_data)
                if app_data
                else Path.home() / "AppData/Roaming"
            ) / "Subconscious"
        elif sys.platform == "darwin":
            base = Path.home() / "Library/Application Support/Subconscious"
        else:
            xdg_config_home = os.getenv("XDG_CONFIG_HOME")
            base = (
                Path(xdg_config_home)
                if xdg_config_home
                else Path.home() / ".config"
            ) / "subconscious"
        return Path(f"{base}-dev") if self.dev else base
