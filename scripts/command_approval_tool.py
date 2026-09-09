#!/usr/bin/env python3
"""External stdin/stdout tool used as a Subconscious approval boundary.

The Subconscious host is expected to apply its standard tool approval policy
before starting this process. Reaching this script therefore means the tool
call was approved; the script validates the request and returns approve-once.
"""

from __future__ import annotations

import json
import sys
from typing import Any

_MAX_INPUT_BYTES = 1_048_576


def _arguments(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ValueError("request must be a JSON object")
    nested = payload.get("arguments")
    if nested is not None:
        if not isinstance(nested, dict):
            raise ValueError("arguments must be a JSON object")
        return nested
    return payload


def main() -> int:
    raw = sys.stdin.buffer.read(_MAX_INPUT_BYTES + 1)
    if len(raw) > _MAX_INPUT_BYTES:
        print("command_approval: input exceeds 1 MiB", file=sys.stderr)
        return 2
    try:
        payload = json.loads(raw.decode("utf-8"))
        arguments = _arguments(payload)
        command = arguments.get("command")
        shell = arguments.get("shell")
        commands = arguments.get("commands")
        cwd = arguments.get("cwd")
        opinion = arguments.get("opinion")
        if not isinstance(command, str) or not command.strip():
            raise ValueError("command must be a non-empty string")
        if not isinstance(shell, str) or not shell.strip():
            raise ValueError("shell must be a non-empty string")
        if not isinstance(commands, list) or not commands:
            raise ValueError("commands must be a non-empty array")
        if not all(isinstance(item, str) and item.strip() for item in commands):
            raise ValueError("each parsed command must be a non-empty string")
        if not isinstance(cwd, str) or not cwd.strip():
            raise ValueError("cwd must be a non-empty string")
        if not isinstance(opinion, str) or not opinion.strip():
            raise ValueError("opinion must be a non-empty string")
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        print(f"command_approval: {error}", file=sys.stderr)
        return 2

    print(
        json.dumps(
            {
                "ok": True,
                "result": {
                    "decision": "approve",
                    "scope": "once",
                    "message": "The command approval tool call was approved.",
                },
            },
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
