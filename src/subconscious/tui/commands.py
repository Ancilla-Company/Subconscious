import re
import logging
from typing import Optional
from dataclasses import dataclass
from enum import Enum


logger = logging.getLogger("subconscious")


class CommandMode(Enum):
    CHAT = "chat"
    CODE = "code"
    EDIT = "edit"


@dataclass
class ParsedCommand:
    command: str
    args: list[str]
    raw: str
    mode: CommandMode = CommandMode.CHAT


class CommandParser:
    COMMANDS = {
        "/chat": {"mode": CommandMode.CHAT, "desc": "Switch to chat mode"},
        "/code": {"mode": CommandMode.CODE, "desc": "Switch to code mode"},
        "/edit": {"mode": CommandMode.EDIT, "desc": "Edit a file"},
        "/new": {"mode": None, "desc": "Start new conversation"},
        "/save": {"mode": None, "desc": "Save current session"},
        "/load": {"mode": None, "desc": "Load a thread"},
        "/clear": {"mode": None, "desc": "Clear screen"},
        "/cls": {"mode": None, "desc": "Clear screen (Windows)"},
        "/help": {"mode": None, "desc": "Show help"},
        "/quit": {"mode": None, "desc": "Exit application"},
        "/threads": {"mode": None, "desc": "List threads"},
        "/workspaces": {"mode": None, "desc": "List workspaces"},
        "/fork": {"mode": None, "desc": "Fork current thread"},
    }

    def __init__(self):
        self.current_mode = CommandMode.CHAT

    def parse(self, text: str) -> ParsedCommand:
        text = text.strip()

        if not text.startswith("/"):
            return ParsedCommand(
                command="",
                args=[],
                raw=text,
                mode=self.current_mode,
            )

        parts = text.split()
        command = parts[0].lower()
        args = parts[1:]

        cmd_info = self.COMMANDS.get(command, {})
        mode = cmd_info.get("mode", self.current_mode)

        return ParsedCommand(
            command=command,
            args=args,
            raw=text,
            mode=mode or self.current_mode,
        )

    def is_command(self, text: str) -> bool:
        return text.strip().startswith("/")

    def get_commands(self) -> dict:
        return self.COMMANDS.copy()

    def get_help_text(self) -> str:
        lines = ["Available commands:"]
        for cmd, info in self.COMMANDS.items():
            lines.append(f"  {cmd:10} - {info['desc']}")
        return "\n".join(lines)

    def set_mode(self, mode: CommandMode) -> None:
        self.current_mode = mode

    def get_mode(self) -> CommandMode:
        return self.current_mode
