"""
Unit tests for subconscious.tools.filesystem

All tests operate inside a temporary directory (inside the user home tree)
so the sandbox check passes and no real files are touched.
"""

import pathlib
import pytest
import pytest_asyncio

from subconscious.tools.filesystem import (
  read_file,
  list_directory,
  create_file,
  get_file_info,
)


# ---------------------------------------------------------------------------
# Fixture: temporary directory inside home so _safe_path allows it
# ---------------------------------------------------------------------------

@pytest_asyncio.fixture
async def tmp_home_dir(tmp_path, monkeypatch):
  """
  Redirect pathlib.Path.home() to tmp_path so the sandbox always allows
  access during tests.
  """
  monkeypatch.setattr(pathlib.Path, "home", staticmethod(lambda: tmp_path))
  return tmp_path


# ---------------------------------------------------------------------------
# read_file
# ---------------------------------------------------------------------------

async def test_read_file_success(ctx, tmp_home_dir):
  f = tmp_home_dir / "hello.txt"
  f.write_text("Hello, world!", encoding="utf-8")
  result = await read_file(ctx, str(f))
  assert result == "Hello, world!"


async def test_read_file_not_found(ctx, tmp_home_dir):
  result = await read_file(ctx, str(tmp_home_dir / "missing.txt"))
  assert "not found" in result.lower()


async def test_read_file_is_dir(ctx, tmp_home_dir):
  result = await read_file(ctx, str(tmp_home_dir))
  assert "not a file" in result.lower()


async def test_read_file_outside_home_blocked(ctx, tmp_path, monkeypatch):
  # Point home to a *different* tmp dir so the real tmp_path is outside home
  other = tmp_path / "fake_home"
  other.mkdir()
  monkeypatch.setattr(pathlib.Path, "home", staticmethod(lambda: other))
  result = await read_file(ctx, str(tmp_path / "escape.txt"))
  assert "Access denied" in result or "outside" in result


async def test_read_file_truncates_large_file(ctx, tmp_home_dir):
  f = tmp_home_dir / "big.txt"
  # Write 110 KB of data
  f.write_bytes(b"A" * 110_000_000)
  result = await read_file(ctx, str(f))
  assert "truncated" in result


# ---------------------------------------------------------------------------
# list_directory
# ---------------------------------------------------------------------------

async def test_list_directory_shows_files(ctx, tmp_home_dir):
  (tmp_home_dir / "alpha.txt").write_text("a")
  (tmp_home_dir / "beta.txt").write_text("b")
  result = await list_directory(ctx, str(tmp_home_dir))
  names = [e["name"] for e in result]
  assert "alpha.txt" in names
  assert "beta.txt" in names


async def test_list_directory_hides_dotfiles_by_default(ctx, tmp_home_dir):
  (tmp_home_dir / ".hidden").write_text("secret")
  (tmp_home_dir / "visible.txt").write_text("ok")
  result = await list_directory(ctx, str(tmp_home_dir))
  names = [e["name"] for e in result]
  assert ".hidden" not in names
  assert "visible.txt" in names


async def test_list_directory_shows_dotfiles_when_asked(ctx, tmp_home_dir):
  (tmp_home_dir / ".hidden").write_text("secret")
  result = await list_directory(ctx, str(tmp_home_dir), show_hidden=True)
  names = [e["name"] for e in result]
  assert ".hidden" in names


async def test_list_directory_not_found(ctx, tmp_home_dir):
  result = await list_directory(ctx, str(tmp_home_dir / "no_such_dir"))
  assert any("error" in e for e in result) or any("not found" in str(e).lower() for e in result)


async def test_list_directory_entries_have_type(ctx, tmp_home_dir):
  sub = tmp_home_dir / "subdir"
  sub.mkdir()
  (tmp_home_dir / "file.txt").write_text("x")
  result = await list_directory(ctx, str(tmp_home_dir))
  by_name = {e["name"]: e for e in result}
  assert by_name["subdir"]["type"] == "dir"
  assert by_name["file.txt"]["type"] == "file"


# ---------------------------------------------------------------------------
# create_file
# ---------------------------------------------------------------------------

async def test_create_file_creates_new(ctx, tmp_home_dir):
  path = str(tmp_home_dir / "new_file.txt")
  result = await create_file(ctx, path, content="created!")
  assert "created" in result.lower() or "ok" in result.lower()
  assert pathlib.Path(path).read_text() == "created!"


async def test_create_file_no_overwrite_by_default(ctx, tmp_home_dir):
  path = str(tmp_home_dir / "existing.txt")
  pathlib.Path(path).write_text("original")
  result = await create_file(ctx, path, content="new")
  assert "already exists" in result.lower() or "exist" in result.lower()
  # File content unchanged
  assert pathlib.Path(path).read_text() == "original"


async def test_create_file_overwrite_flag(ctx, tmp_home_dir):
  path = str(tmp_home_dir / "overwrite_me.txt")
  pathlib.Path(path).write_text("old")
  await create_file(ctx, path, content="new", overwrite=True)
  assert pathlib.Path(path).read_text() == "new"


async def test_create_file_creates_parents(ctx, tmp_home_dir):
  path = str(tmp_home_dir / "deep" / "nested" / "file.txt")
  result = await create_file(ctx, path, content="deep")
  assert pathlib.Path(path).exists()


# ---------------------------------------------------------------------------
# get_file_info
# ---------------------------------------------------------------------------

async def test_get_file_info_returns_dict(ctx, tmp_home_dir):
  f = tmp_home_dir / "info.txt"
  f.write_text("some content")
  result = await get_file_info(ctx, str(f))
  assert isinstance(result, dict)
  assert result.get("name") == "info.txt"
  assert result.get("size_bytes") == len("some content")


async def test_get_file_info_not_found(ctx, tmp_home_dir):
  result = await get_file_info(ctx, str(tmp_home_dir / "ghost.txt"))
  # Should return a dict with an error key or a message
  assert "error" in result or "not found" in str(result).lower()
