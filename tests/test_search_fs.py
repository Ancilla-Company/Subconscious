import asyncio


def test_search_by_name(tmp_path):
  f = tmp_path / "hello.txt"
  f.write_text("hello world\n")

  from subconscious.desktop_tools.search import search_fs

  res = asyncio.run(search_fs(None, str(tmp_path), name_pattern="hello*", max_results=10))
  assert isinstance(res, list)
  assert len(res) == 1
  assert res[0]["name"] == "hello.txt"


def test_search_by_content(tmp_path):
  f = tmp_path / "data.txt"
  f.write_text("first line\nmatch on second line\nthird\n")

  from subconscious.desktop_tools.search import search_fs

  res = asyncio.run(search_fs(None, str(tmp_path), name_pattern="*", content_query="match", max_results=10))
  assert isinstance(res, list)
  # Should find the file and report first_match_line
  assert any("first_match_line" in r for r in res)
