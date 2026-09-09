""" Command-line entry point for the Subconscious engine and clients """

import sys
import asyncio
import argparse
import subprocess
from pathlib import Path
from collections.abc import Sequence

from .host import EngineHost
from .config import EngineConfig


LOGO = """
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣠⣶⣶⣦⣠⣤⣤⣤⣄⣀⣠⣤⣤⡀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣿⣿⣿⣿⠏⠉⠉⠉⠙⢻⣿⣿⣿⡷⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⣰⣿⠋⠙⠛⠻⣷⣄⣀⠀⣠⣾⠟⠛⠛⠁⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⣰⣾⣿⣷⣄⣀⣀⣀⣹⣿⣿⣿⡟⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⢻⣿⣿⣿⠟⠛⠛⠛⠻⣿⣿⣿⠇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠈⠻⣷⣤⣀⠀⠀⠀⢀⣿⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠙⠻⠿⣶⣶⣿⣿⣷⡄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠻⣿⣿⣿⢿⣶⣤⡀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣰⡿⠉⠀⠀⠈⠙⢿⣦⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣾⣿⣿⣷⡀⠀⠀⠀⠀⠈⣿⡆⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣠⣿⣿⣿⠿⠿⣶⣦⣄⣀⣤⣿⣇⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⢀⣀⣀⣠⣾⠟⠁⢸⣿⠀⠀⠀⠉⠙⣿⣿⣿⣿⠆⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⢠⣿⣿⣿⣿⠁⠀⢀⣼⣿⡀⠀⠀⢀⣠⣿⠿⠟⠋⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠈⠿⣿⡿⠿⠿⢷⣿⣿⣿⣿⣶⠿⠟⠋⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⠿⠿⠛⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
"""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="subconscious",
        description="Run and interact with the Subconscious agent engine.",
    )
    subcommands = parser.add_subparsers(dest="command", metavar="COMMAND")

    start = subcommands.add_parser("start", help="Start the local engine service.")
    start.add_argument("--dev", action="store_true", help="Use stable development credentials.")
    start.add_argument(
        "--port",
        type=int,
        default=0,
        help="Listen port; zero uses 55681 in dev mode or an available port otherwise.",
    )
    start.add_argument("--lan", action="store_true", help="Bind to all IPv4 interfaces.")
    start.add_argument("--node-id", help="Advertise a stable engine node identifier.")
    start.add_argument("--data-dir", type=Path, help="Override the engine data directory.")
    start.add_argument(
        "--detached",
        action="store_true",
        help="Launch the engine as a detached background process.",
    )
    start.add_argument(
        "--no-tray",
        action="store_true",
        help="Run without the system tray icon.",
    )
    start.add_argument("--service-child", action="store_true", help=argparse.SUPPRESS)
    start.set_defaults(handler=_run_start)

    chat = subcommands.add_parser("chat", help="Run one non-interactive chat turn.")
    chat.add_argument("prompt", help="Message text, or '-' to read it from stdin.")
    target = chat.add_mutually_exclusive_group()
    target.add_argument("--workspace", help="Target workspace UUID or exact name.")
    target.add_argument("--thread", help="Continue an existing thread UUID.")
    chat.add_argument("--tools", action="store_true", help="Enable workspace-default tools.")
    chat.add_argument(
        "--notification",
        action="store_true",
        help="Append a system notification to an existing thread without running an agent.",
    )
    chat.add_argument("--dev", action="store_true", help="Enable development mode.")
    chat.add_argument("--data-dir", type=Path, help="Override runtime discovery data directory.")
    chat.add_argument("--timeout", type=_positive_float, default=300.0)
    chat.set_defaults(handler=_run_chat)
    for name, description in (
        ("tui", "Start the terminal client."),
        ("desktop", "Start the desktop client."),
        ("web", "Start the web client."),
        ("extension", "Start the browser client."),
    ):
        client = subcommands.add_parser(name, help=description)
        if name == "desktop":
            client.add_argument(
                "--engine-url",
                help="Engine API URL supplied by a copied tray join command.",
            )
            client.add_argument(
                "--token",
                help="Engine joining token supplied by a copied tray join command.",
            )
        client.set_defaults(handler=_client_stub)
    return parser


def _positive_float(value: str) -> float:
    parsed = float(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def _run_start(args: argparse.Namespace) -> int:
    if args.detached and not args.service_child:
        return _spawn_background_service(args)
    config = EngineConfig(
        dev=args.dev,
        headless=args.no_tray,
        port=args.port,
        lan_enabled=args.lan,
        node_id=args.node_id,
        data_directory=args.data_dir,
    )
    try:
        asyncio.run(EngineHost(config).serve())
    except KeyboardInterrupt:
        pass
    return 0


def _spawn_background_service(args: argparse.Namespace) -> int:
    command = [sys.executable, "-m", "subconscious_engine", "start"]
    if args.dev:
        command.append("--dev")
    if args.port:
        command.extend(("--port", str(args.port)))
    if args.lan:
        command.append("--lan")
    if args.node_id:
        command.extend(("--node-id", args.node_id))
    if args.data_dir:
        command.extend(("--data-dir", str(args.data_dir)))
    command.append("--detached")
    if args.no_tray:
        command.append("--no-tray")
    command.append("--service-child")
    options: dict[str, object] = {
        "stdin": subprocess.DEVNULL,
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "close_fds": True,
    }
    if sys.platform == "win32":
        options["creationflags"] = (
            subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
        )
    else:
        options["start_new_session"] = True
    process = subprocess.Popen(command, **options)
    print(f"Subconscious engine service started (PID {process.pid}).")
    return 0


def _run_chat(args: argparse.Namespace) -> int:
    from .client import EngineClientError, one_shot_chat, one_shot_notification

    prompt = sys.stdin.read() if args.prompt == "-" else args.prompt
    if not prompt.strip():
        print("subconscious chat: the prompt cannot be empty", file=sys.stderr)
        return 2
    if args.notification and args.thread is None:
        print(
            "subconscious chat: --notification requires --thread <UUID>",
            file=sys.stderr,
        )
        return 2
    try:
        if args.notification:
            result = asyncio.run(
                one_shot_notification(
                    prompt,
                    thread=args.thread,
                    dev=args.dev,
                    data_directory=args.data_dir,
                    timeout=args.timeout,
                )
            )
        else:
            result = asyncio.run(
                one_shot_chat(
                    prompt,
                    workspace=args.workspace,
                    thread=args.thread,
                    tools=args.tools,
                    dev=args.dev,
                    data_directory=args.data_dir,
                    timeout=args.timeout,
                )
            )
    except (EngineClientError, KeyboardInterrupt) as error:
        message = str(error) if str(error) else "Chat was interrupted."
        print(f"subconscious chat: {message}", file=sys.stderr)
        return 1
    if args.notification:
        print(f"Notification added to thread: {result.thread_uuid}")
    else:
        print(result.response)
        if result.created_thread:
            print(f"Thread: {result.thread_uuid}", file=sys.stderr)
    return 0


def _client_stub(args: argparse.Namespace) -> int:
    print(
        f"subconscious {args.command}: client launch support is not implemented yet.",
        file=sys.stderr,
    )
    return 1


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    arguments = list(argv) if argv is not None else sys.argv[1:]
    root_help = not arguments or arguments in (["-h"], ["--help"])
    if root_help:
        print(LOGO)
    args = parser.parse_args(arguments)
    handler = getattr(args, "handler", None)
    if handler is None:
        parser.print_help()
        return 0
    return int(handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
