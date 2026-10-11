"""Engine startup configuration matching the .NET composition root"""

import os
import sys
from pathlib import Path
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class EngineConfig:
    port: int = 0
    api: bool = True
    dev: bool = False
    gui: bool = False
    tui: bool = False
    headless: bool = False
    lan_enabled: bool = False
    node_id: str | None = None
    data_directory: Path | None = None
    conscious_graph: Path | None = None
    subconscious_graph: Path | None = None
    subconscious_model_id: str | None = None
    subconscious_enabled: bool = True
    subconscious_interval_seconds: float = 86_400
    subconscious_jitter_ratio: float = 0.1
    account_server_url: str | None = None

    @property
    def resolved_account_server_url(self) -> str:
        return self.account_server_url or os.getenv(
            "SUBCONSCIOUS_SERVER_URL", "https://api.subconscious.chat"
        )

    @property
    def resolved_conscious_graph(self) -> Path:
        configured = self.conscious_graph or (
            Path(value)
            if (value := os.getenv("SUBCONSCIOUS_CONSCIOUS_GRAPH"))
            else None
        )
        return configured or self.resolved_data_directory / "graphs" / "conscious.json"

    @property
    def resolved_subconscious_graph(self) -> Path:
        configured = self.subconscious_graph or (
            Path(value)
            if (value := os.getenv("SUBCONSCIOUS_SUBCONSCIOUS_GRAPH"))
            else None
        )
        return (
            configured or self.resolved_data_directory / "graphs" / "subconscious.json"
        )

    @property
    def resolved_data_directory(self) -> Path:
        if self.data_directory is not None:
            base = self.data_directory
        elif sys.platform == "win32":
            app_data = os.getenv("APPDATA")
            base = (
                Path(app_data) if app_data else Path.home() / "AppData/Roaming"
            ) / "Subconscious"
        elif sys.platform == "darwin":
            base = Path.home() / "Library/Application Support/Subconscious"
        else:
            xdg_config_home = os.getenv("XDG_CONFIG_HOME")
            base = (
                Path(xdg_config_home) if xdg_config_home else Path.home() / ".config"
            ) / "subconscious"
        return Path(f"{base}-dev") if self.dev else base
