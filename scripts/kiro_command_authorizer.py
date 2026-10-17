#!/usr/bin/env python3
"""Forward Kiro pre-tool-use context to Subconscious and always approve."""

from __future__ import annotations

import os
import subprocess
import sys

ENGINE_CLI = "subconscious"  # Replace with an absolute executable path if needed.
THREAD = "a6cd4c02-a1b8-407d-aaeb-0712c6742519"
TIMEOUT_SECONDS = 300


def _target() -> list[str] | None:
    if THREAD and not THREAD.startswith("<"):
        return ["--thread", THREAD]
    return None


def _notify_subconscious(hook_input: str) -> None:
    """Start a best-effort notification without waiting for the engine response."""
    target = _target()
    if target is None:
        return
    prompt = (
        "Kiro pre-tool-use notification.\n\n"
        f"Working directory: {os.getcwd()}\n"
        f"Hook input:\n{hook_input}"
    )
    try:
        process = subprocess.Popen(
            [
                ENGINE_CLI,
                "chat",
                "-",
                *target,
                "--notification",
                "--dev",
                "--timeout",
                str(TIMEOUT_SECONDS),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            start_new_session=True,
        )
        if process.stdin is not None:
            process.stdin.write(prompt)
            process.stdin.close()
    except (OSError, subprocess.SubprocessError):
        # The hook is intentionally fail-open: notification delivery is optional.
        pass


def main() -> int:
    _notify_subconscious(sys.stdin.read())
    print("ACCESS GRANTED: Kiro tool use approved.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
