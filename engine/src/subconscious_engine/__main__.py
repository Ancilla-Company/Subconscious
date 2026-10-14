""" Command-line entry point for the Subconscious engine and clients """

import sys
import asyncio
import argparse
import subprocess
from pathlib import Path
from collections.abc import Sequence

from .host import EngineHost
from .config import EngineConfig
from .configuration_file import (
    ConfigurationFileError,
    default_config_path,
    environment_engine_overrides,
    environment_is_development,
    load_configuration,
    set_configuration_value,
    show_configuration,
    write_template,
)


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

    config = subcommands.add_parser("config", help="Create, validate, inspect, or update YAML configuration.")
    config.add_argument("--config", type=Path, default=default_config_path())
    config_actions = config.add_subparsers(dest="config_command", required=True)
    config_init = config_actions.add_parser("init", help="Write a configuration template.")
    config_init.add_argument("--force", action="store_true", help="Overwrite an existing file.")
    config_init.set_defaults(handler=_run_config)
    config_actions.add_parser("validate", help="Validate YAML configuration.").set_defaults(handler=_run_config)
    config_show = config_actions.add_parser("show", help="Print effective configuration.")
    config_show.add_argument("--show-secrets", action="store_true", help="Print configured token values.")
    config_show.set_defaults(handler=_run_config)
    config_set = config_actions.add_parser("set", help="Set a YAML scalar using engine.<key> or client.<key>.")
    config_set.add_argument("key")
    config_set.add_argument("value")
    config_set.set_defaults(handler=_run_config)

    # Start - start the engine
    start = subcommands.add_parser("start", help="Start the local engine service.")
    start.add_argument("--config", type=Path, default=default_config_path(), help="YAML configuration path.")
    start.add_argument("--dev", action="store_true", default=None, help="Use stable development credentials.")
    start.add_argument(
        "--port",
        type=int,
        default=None,
        help="Listen port; default is 50506 (production) or 50505 (development); zero picks an available port.",
    )
    start.add_argument("--lan", action="store_true", default=None, help="Bind to all IPv4 interfaces.")
    start.add_argument("--node-id", help="Advertise a stable engine node identifier.")
    start.add_argument("--data-dir", type=Path, help="Override the engine data directory.")
    start.add_argument(
        "--detached",
        action="store_true",
        default=None,
        help="Launch the engine as a detached background process.",
    )
    start.add_argument(
        "--no-tray",
        action="store_true",
        default=None,
        help="Run without the system tray icon.",
    )
    start.add_argument("--service-child", action="store_true", help=argparse.SUPPRESS)
    start.set_defaults(handler=_run_start)

    # Chat - one off non interactive chat
    chat = subcommands.add_parser("chat", help="Run one non-interactive chat turn.")
    chat.add_argument("--config", type=Path, default=default_config_path(), help="YAML configuration path.")
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
    chat.add_argument("--dev", action="store_true", default=None, help="Enable development mode.")
    chat.add_argument("--data-dir", type=Path, help="Override runtime discovery data directory.")
    chat.add_argument("--timeout", type=_positive_float, default=None)
    chat.set_defaults(handler=_run_chat)

    # Client - start an engine client service
    for name, description in (
        ("tui", "Start the terminal client."),
        ("desktop", "Start the desktop client."),
        ("web", "Start the web client."),
        ("extension", "Start the browser client."),
    ):
        client = subcommands.add_parser(name, help=description)
        client.add_argument("--config", type=Path, default=default_config_path(), help="YAML configuration path.")
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


def _run_config(args: argparse.Namespace) -> int:
    try:
        if args.config_command == "init":
            write_template(args.config, overwrite=args.force)
            print(f"Wrote configuration template: {args.config}")
        elif args.config_command == "validate":
            load_configuration(args.config)
            print(f"Configuration is valid: {args.config}")
        elif args.config_command == "show":
            print(show_configuration(args.config, reveal_secrets=args.show_secrets), end="")
        else:
            set_configuration_value(args.config, args.key, args.value)
            print(f"Updated configuration: {args.key}")
    except ConfigurationFileError as error:
        print(f"subconscious config: {error}", file=sys.stderr)
        return 2
    return 0


def _engine_config_from_args(args: argparse.Namespace) -> EngineConfig:
    configured = load_configuration(args.config).engine
    values = {name: getattr(configured, name) for name in configured.__dataclass_fields__}
    values.update(environment_engine_overrides())
    overrides = {
        "dev": args.dev,
        "port": args.port,
        "lan_enabled": args.lan,
        "node_id": args.node_id,
        "data_directory": args.data_dir,
        "headless": args.no_tray,
    }
    values.update({key: value for key, value in overrides.items() if value is not None})
    return EngineConfig(**values)


def _positive_float(value: str) -> float:
    parsed = float(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def _run_start(args: argparse.Namespace) -> int:
    try:
        config = _engine_config_from_args(args)
    except ConfigurationFileError as error:
        print(f"subconscious start: {error}", file=sys.stderr)
        return 2
    args.dev = config.dev
    args.port = config.port
    args.lan = config.lan_enabled
    args.node_id = config.node_id
    args.data_dir = config.data_directory
    args.no_tray = config.headless
    if args.detached and not args.service_child:
        return _spawn_background_service(args)
    try:
        asyncio.run(EngineHost(config).serve())
    except KeyboardInterrupt:
        pass
    return 0


def _spawn_background_service(args: argparse.Namespace) -> int:
    # PyInstaller sets sys.frozen; Nuitka defines __compiled__. In both, the
    # executable is the program itself and `-m` is not available.
    frozen = getattr(sys, "frozen", False) or "__compiled__" in globals()
    if frozen:
        command = [sys.executable, "start"]
    else:
        command = [sys.executable, "-m", "subconscious_engine", "start"]
    if args.dev:
        command.append("--dev")
    if args.port is not None:
        command.extend(("--port", str(args.port)))
    if args.lan:
        command.append("--lan")
    if args.node_id:
        command.extend(("--node-id", args.node_id))
    if args.data_dir:
        command.extend(("--data-dir", str(args.data_dir)))
    if args.config:
        command.extend(("--config", str(args.config)))
    command.append("--detached")
    if args.no_tray:
        command.append("--no-tray")
    command.append("--service-child")
    if sys.platform == "win32":
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            creationflags=subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP,
        )
    else:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            start_new_session=True,
        )
    print(f"Subconscious engine service started (PID {process.pid}).")
    return 0


def _run_chat(args: argparse.Namespace) -> int:
    from .client import ChatResult, EngineClientError, one_shot_chat, one_shot_notification

    try:
        configured = load_configuration(args.config)
    except ConfigurationFileError as error:
        print(f"subconscious chat: {error}", file=sys.stderr)
        return 2
    prompt = sys.stdin.read() if args.prompt == "-" else args.prompt
    dev = args.dev if args.dev is not None else environment_is_development(configured.engine.dev)
    data_directory = args.data_dir or configured.engine.data_directory
    timeout = args.timeout or 300.0
    workspace = args.workspace or configured.client.get("workspace")
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
                    dev=dev,
                    data_directory=data_directory,
                    timeout=timeout,
                )
            )
        else:
            result = asyncio.run(
                one_shot_chat(
                    prompt,
                    workspace=workspace,
                    thread=args.thread,
                    tools=args.tools,
                    dev=dev,
                    data_directory=data_directory,
                    timeout=timeout,
                )
            )
    except (EngineClientError, KeyboardInterrupt) as error:
        message = str(error) if str(error) else "Chat was interrupted."
        print(f"subconscious chat: {message}", file=sys.stderr)
        return 1
    if args.notification:
        print(f"Notification added to thread: {result.thread_uuid}")
    else:
        assert isinstance(result, ChatResult)
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
  """ Subconscious Engine entry point """
  parser = build_parser()
  arguments = list(argv) if argv is not None else sys.argv[1:]
  root_help = not arguments or arguments in (["-h"], ["--help"])
  if root_help:
    print(LOGO)
  args = parser.parse_args(arguments)

  # Run the handler or print help
  handler = getattr(args, "handler", None)
  if handler is None:
    parser.print_help()
    return 0
  return int(handler(args))


if __name__ == "__main__":
    raise SystemExit(main())
