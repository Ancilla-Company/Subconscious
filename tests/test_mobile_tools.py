"""
Unit tests for subconscious.mobile_tools.

Tests cover:
  - MobileToolRegistry construction and slug inventory
  - mobile_tools.filesystem (sandboxing, CRUD)
  - mobile_tools.web_search (mocked HTTP)
"""

import pytest
import pytest_asyncio
from dataclasses import dataclass
from unittest.mock import AsyncMock, MagicMock, patch

from subconscious.tools import BaseToolRegistry
import subconscious.mobile_tools.filesystem as fs_mod
import subconscious.mobile_tools.web_search as ws_mod
from subconscious.mobile_tools import ToolRegistry, EngineContext


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

@dataclass
class FakeRunContext:
  deps: EngineContext


@pytest_asyncio.fixture
async def sandbox(tmp_path):
  """Return an EngineContext whose data_dir is a fresh temp directory."""
  ctx = EngineContext(db=None, workspace_id=1, thread_id=1, data_dir=str(tmp_path))
  return FakeRunContext(deps=ctx)


# ---------------------------------------------------------------------------
# MobileToolRegistry
# ---------------------------------------------------------------------------

class TestMobileToolRegistry:
  def test_inherits_base_registry(self):
    r = ToolRegistry()
    assert isinstance(r, BaseToolRegistry)

  def test_base_slugs_present(self):
    r = ToolRegistry()
    base_slugs = {"time", "calculator", "weather", "todo", "memory", "notes", "contacts"}
    assert base_slugs.issubset(set(r.all_slugs()))

  def test_mobile_slugs_present(self):
    r = ToolRegistry()
    assert "filesystem" in r.all_slugs()
    assert "web_search" in r.all_slugs()

  def test_no_desktop_only_slugs(self):
    r = ToolRegistry()
    forbidden = {"terminal", "clipboard", "images"}
    overlap = forbidden & set(r.all_slugs())
    assert not overlap, f"Mobile registry should not contain: {overlap}"

  def test_all_tools_callable(self):
    r = ToolRegistry()
    for tool in r.get_tools(r.all_slugs()):
      assert callable(tool)

  def test_singleton_populated(self):
    from subconscious.mobile_tools import registry
    assert isinstance(registry, ToolRegistry)
    assert len(registry.all_slugs()) >= 9


# ---------------------------------------------------------------------------
# mobile_tools.filesystem — sandboxing
# ---------------------------------------------------------------------------

class TestMobileFilesystemSandbox:
  def test_safe_path_allows_subpath(self, tmp_path):
    result = fs_mod._safe_path(str(tmp_path), "subdir/file.txt")
    assert str(result).startswith(str(tmp_path.resolve()))

  def test_safe_path_rejects_traversal(self, tmp_path):
    with pytest.raises(PermissionError):
      fs_mod._safe_path(str(tmp_path), "../../etc/passwd")

  def test_safe_path_rejects_absolute(self, tmp_path):
    """An absolute path that escapes the sandbox must be rejected."""
    with pytest.raises(PermissionError):
      fs_mod._safe_path(str(tmp_path), "/etc/passwd")


# ---------------------------------------------------------------------------
# mobile_tools.filesystem — list_directory
# ---------------------------------------------------------------------------

class TestMobileFilesystemListDir:
  @pytest.mark.asyncio
  async def test_list_empty_dir(self, sandbox, tmp_path):
    result = await fs_mod.list_directory(sandbox, ".")
    assert "entries" in result
    assert result["entries"] == []

  @pytest.mark.asyncio
  async def test_list_dir_with_files(self, sandbox, tmp_path):
    (tmp_path / "a.txt").write_text("hello")
    (tmp_path / "b.txt").write_text("world")
    result = await fs_mod.list_directory(sandbox, ".")
    names = {e["name"] for e in result["entries"]}
    assert {"a.txt", "b.txt"} == names

  @pytest.mark.asyncio
  async def test_list_dir_shows_type(self, sandbox, tmp_path):
    (tmp_path / "sub").mkdir()
    (tmp_path / "file.txt").write_text("x")
    result = await fs_mod.list_directory(sandbox, ".")
    types = {e["name"]: e["type"] for e in result["entries"]}
    assert types["sub"] == "dir"
    assert types["file.txt"] == "file"

  @pytest.mark.asyncio
  async def test_list_nonexistent_dir_returns_error(self, sandbox):
    result = await fs_mod.list_directory(sandbox, "ghost_dir")
    assert "error" in result

  @pytest.mark.asyncio
  async def test_list_dir_traversal_returns_error(self, sandbox):
    result = await fs_mod.list_directory(sandbox, "../../etc")
    assert "error" in result


# ---------------------------------------------------------------------------
# mobile_tools.filesystem — read_file
# ---------------------------------------------------------------------------

class TestMobileFilesystemReadFile:
  @pytest.mark.asyncio
  async def test_read_existing_file(self, sandbox, tmp_path):
    (tmp_path / "hello.txt").write_text("hello world")
    result = await fs_mod.read_file(sandbox, "hello.txt")
    assert result["content"] == "hello world"

  @pytest.mark.asyncio
  async def test_read_nonexistent_file_returns_error(self, sandbox):
    result = await fs_mod.read_file(sandbox, "nope.txt")
    assert "error" in result

  @pytest.mark.asyncio
  async def test_read_directory_returns_error(self, sandbox, tmp_path):
    (tmp_path / "adir").mkdir()
    result = await fs_mod.read_file(sandbox, "adir")
    assert "error" in result

  @pytest.mark.asyncio
  async def test_read_traversal_returns_error(self, sandbox):
    result = await fs_mod.read_file(sandbox, "../../secret.txt")
    assert "error" in result

  @pytest.mark.asyncio
  async def test_read_large_file_returns_error(self, sandbox, tmp_path):
    big = b"x" * (512 * 1024 + 1)
    (tmp_path / "big.bin").write_bytes(big)
    result = await fs_mod.read_file(sandbox, "big.bin")
    assert "error" in result
    assert "too large" in result["error"]


# ---------------------------------------------------------------------------
# mobile_tools.filesystem — write_file
# ---------------------------------------------------------------------------

class TestMobileFilesystemWriteFile:
  @pytest.mark.asyncio
  async def test_write_new_file(self, sandbox, tmp_path):
    result = await fs_mod.write_file(sandbox, "new.txt", "content")
    assert result["status"] == "ok"
    assert (tmp_path / "new.txt").read_text() == "content"

  @pytest.mark.asyncio
  async def test_write_creates_parent_dirs(self, sandbox, tmp_path):
    result = await fs_mod.write_file(sandbox, "sub/dir/file.txt", "data")
    assert result["status"] == "ok"
    assert (tmp_path / "sub" / "dir" / "file.txt").read_text() == "data"

  @pytest.mark.asyncio
  async def test_write_overwrites_existing(self, sandbox, tmp_path):
    (tmp_path / "exist.txt").write_text("old")
    await fs_mod.write_file(sandbox, "exist.txt", "new")
    assert (tmp_path / "exist.txt").read_text() == "new"

  @pytest.mark.asyncio
  async def test_write_traversal_returns_error(self, sandbox):
    result = await fs_mod.write_file(sandbox, "../../evil.txt", "bad")
    assert "error" in result


# ---------------------------------------------------------------------------
# mobile_tools.filesystem — delete_file
# ---------------------------------------------------------------------------

class TestMobileFilesystemDeleteFile:
  @pytest.mark.asyncio
  async def test_delete_existing_file(self, sandbox, tmp_path):
    (tmp_path / "del.txt").write_text("bye")
    result = await fs_mod.delete_file(sandbox, "del.txt")
    assert result["status"] == "ok"
    assert not (tmp_path / "del.txt").exists()

  @pytest.mark.asyncio
  async def test_delete_nonexistent_returns_error(self, sandbox):
    result = await fs_mod.delete_file(sandbox, "ghost.txt")
    assert "error" in result

  @pytest.mark.asyncio
  async def test_delete_directory_returns_error(self, sandbox, tmp_path):
    (tmp_path / "adir").mkdir()
    result = await fs_mod.delete_file(sandbox, "adir")
    assert "error" in result

  @pytest.mark.asyncio
  async def test_delete_traversal_returns_error(self, sandbox):
    result = await fs_mod.delete_file(sandbox, "../../important.txt")
    assert "error" in result


# ---------------------------------------------------------------------------
# mobile_tools.web_search — web_fetch (mocked)
# ---------------------------------------------------------------------------

class TestMobileWebFetch:
  @pytest.mark.asyncio
  async def test_web_fetch_success(self, sandbox):
    fake_response = MagicMock()
    fake_response.status_code = 200
    fake_response.text = "A" * 10000  # more than 8 KB to test truncation
    fake_response.raise_for_status = MagicMock()

    mock_client = AsyncMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)
    mock_client.get = AsyncMock(return_value=fake_response)

    with patch("subconscious.mobile_tools.web_search.httpx.AsyncClient", return_value=mock_client):
      result = await ws_mod.web_fetch(sandbox, "https://example.com")

    assert result["status_code"] == 200
    assert len(result["text"]) <= 8192

  @pytest.mark.asyncio
  async def test_web_fetch_http_error(self, sandbox):
    import httpx
    mock_client = AsyncMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)

    req = httpx.Request("GET", "https://example.com")
    resp = httpx.Response(404, request=req)
    mock_client.get = AsyncMock(side_effect=httpx.HTTPStatusError("404", request=req, response=resp))

    with patch("subconscious.mobile_tools.web_search.httpx.AsyncClient", return_value=mock_client):
      result = await ws_mod.web_fetch(sandbox, "https://example.com")

    assert "error" in result
    assert "404" in result["error"]

  @pytest.mark.asyncio
  async def test_web_fetch_connection_error(self, sandbox):
    import httpx
    mock_client = AsyncMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)
    mock_client.get = AsyncMock(side_effect=httpx.ConnectError("Connection refused"))

    with patch("subconscious.mobile_tools.web_search.httpx.AsyncClient", return_value=mock_client):
      result = await ws_mod.web_fetch(sandbox, "https://example.com")

    assert "error" in result


# ---------------------------------------------------------------------------
# mobile_tools.web_search — web_search_ddg (mocked)
# ---------------------------------------------------------------------------

class TestMobileWebSearchDDG:
  @pytest.mark.asyncio
  async def test_ddg_success_returns_dict_with_query(self, sandbox):
    fake_response = MagicMock()
    fake_response.status_code = 200
    fake_response.text = "<html><body>No results</body></html>"
    fake_response.raise_for_status = MagicMock()

    mock_client = AsyncMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)
    mock_client.post = AsyncMock(return_value=fake_response)

    with patch("subconscious.mobile_tools.web_search.httpx.AsyncClient", return_value=mock_client):
      result = await ws_mod.web_search_ddg(sandbox, "python asyncio", max_results=3)

    assert "query" in result
    assert result["query"] == "python asyncio"
    assert "results" in result

  @pytest.mark.asyncio
  async def test_ddg_max_results_clamped(self, sandbox):
    """max_results > 10 should be clamped to 10."""
    fake_response = MagicMock()
    fake_response.status_code = 200
    fake_response.text = ""
    fake_response.raise_for_status = MagicMock()

    mock_client = AsyncMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)
    mock_client.post = AsyncMock(return_value=fake_response)

    with patch("subconscious.mobile_tools.web_search.httpx.AsyncClient", return_value=mock_client):
      result = await ws_mod.web_search_ddg(sandbox, "test", max_results=99)

    # Should not raise; results capped at 10
    assert "results" in result

  @pytest.mark.asyncio
  async def test_ddg_http_error_returns_error(self, sandbox):
    import httpx
    mock_client = AsyncMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=False)

    req = httpx.Request("POST", "https://lite.duckduckgo.com/lite/")
    resp = httpx.Response(503, request=req)
    mock_client.post = AsyncMock(
      side_effect=httpx.HTTPStatusError("503", request=req, response=resp)
    )

    with patch("subconscious.mobile_tools.web_search.httpx.AsyncClient", return_value=mock_client):
      result = await ws_mod.web_search_ddg(sandbox, "failing query")

    assert "error" in result
