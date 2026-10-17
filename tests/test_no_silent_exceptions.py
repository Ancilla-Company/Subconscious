"""Static guard: no engine exception handler may hide an error."""
import ast
from pathlib import Path

import pytest

ENGINE = Path(__file__).resolve().parents[1] / "engine" / "src" / "subconscious_engine"
LOG_METHODS = {"debug", "info", "warning", "warn", "error", "critical", "exception", "log"}


def _logs_or_raises(handler: ast.ExceptHandler) -> bool:
    for node in ast.walk(handler):
        if isinstance(node, ast.Raise):
            return True
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Attribute) and func.attr in LOG_METHODS:
                return True
            if isinstance(func, ast.Name) and func.id.startswith("log_"):
                return True
    return False


def _files():
    return [p for p in sorted(ENGINE.rglob("*.py")) if p.name != "logging_setup.py"]


@pytest.mark.parametrize("path", _files(), ids=lambda p: p.relative_to(ENGINE).as_posix())
def test_no_silent_exception_handlers(path):
    tree = ast.parse(path.read_text(encoding="utf-8"))
    problems = []
    for node in ast.walk(tree):
        if isinstance(node, ast.ExceptHandler) and not _logs_or_raises(node):
            problems.append(f"{path.name}:{node.lineno} except handler neither logs nor re-raises")
        if isinstance(node, ast.Call):
            name = ast.unparse(node.func)
            if name in ("suppress", "contextlib.suppress"):
                problems.append(f"{path.name}:{node.lineno} contextlib.suppress hides errors; use logged_suppress")
            if name in ("asyncio.create_task", "asyncio.ensure_future", "loop.create_task"):
                problems.append(f"{path.name}:{node.lineno} {name} outside spawn_logged")
    assert not problems, "\n".join(problems)
