"""Command-line entry point."""

import argparse
import asyncio
from pathlib import Path
from typing import Sequence

from .config import EngineConfig
from .host import EngineHost


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the Subconscious Python engine")
    parser.add_argument("--dev", action="store_true", help="Use stable development credentials")
    parser.add_argument("--port", type=int, default=0, help="Listen port; zero selects an available port")
    parser.add_argument("--lan", action="store_true", help="Bind to all interfaces instead of loopback")
    parser.add_argument(
        "--headless",
        action="store_true",
        help="Run without the background system tray status icon",
    )
    parser.add_argument("--node-id")
    parser.add_argument("--data-dir", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    config = EngineConfig(
        dev=args.dev,
        headless=args.headless,
        port=args.port,
        lan_enabled=args.lan,
        node_id=args.node_id,
        data_directory=args.data_dir,
    )
    try:
        asyncio.run(EngineHost(config).serve())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
