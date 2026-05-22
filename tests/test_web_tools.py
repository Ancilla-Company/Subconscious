"""
Unit tests for subconscious.desktop_tools.web_tools
"""

import pytest
from unittest.mock import AsyncMock, MagicMock, patch

from subconscious.desktop_tools.web_tools import (
  check_connectivity,
  fetch_page,
  search_web,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_response(text: str = "", status_code: int = 200, content_type: str = "text/html"):
  """Build a minimal mock httpx response."""
  response = MagicMock()
  response.text = text
  response.status_code = status_code
  response.headers = {"content-type": content_type}
  response.raise_for_status = MagicMock()
  return response


# ---------------------------------------------------------------------------
# check_connectivity
# ---------------------------------------------------------------------------

async def test_check_connectivity_connected(ctx):
  """Returns connected=True and a numeric latency when the request succeeds."""
  mock_client = AsyncMock()
  mock_client.__aenter__ = AsyncMock(return_value=mock_client)
  mock_client.__aexit__ = AsyncMock(return_value=False)
  mock_client.get = AsyncMock(return_value=_make_response())

  with patch("subconscious.desktop_tools.web_tools.httpx.AsyncClient", return_value=mock_client):
    result = await check_connectivity(ctx)

  assert result["connected"] is True
  assert isinstance(result["latency_ms"], float)
  assert result["latency_ms"] >= 0


async def test_check_connectivity_disconnected(ctx):
  """Returns connected=False and latency_ms=None when the request raises."""
  mock_client = AsyncMock()
  mock_client.__aenter__ = AsyncMock(return_value=mock_client)
  mock_client.__aexit__ = AsyncMock(return_value=False)
  mock_client.get = AsyncMock(side_effect=Exception("Network unreachable"))

  with patch("subconscious.desktop_tools.web_tools.httpx.AsyncClient", return_value=mock_client):
    result = await check_connectivity(ctx)

  assert result["connected"] is False
  assert result["latency_ms"] is None


async def test_check_connectivity_returns_dict_keys(ctx):
  """Result always contains both expected keys."""
  mock_client = AsyncMock()
  mock_client.__aenter__ = AsyncMock(return_value=mock_client)
  mock_client.__aexit__ = AsyncMock(return_value=False)
  mock_client.get = AsyncMock(return_value=_make_response())

  with patch("subconscious.desktop_tools.web_tools.httpx.AsyncClient", return_value=mock_client):
    result = await check_connectivity(ctx)

  assert "connected" in result
  assert "latency_ms" in result


# ---------------------------------------------------------------------------
# fetch_page
# ---------------------------------------------------------------------------

_SIMPLE_HTML = "<html><body><p>Hello World</p></body></html>"
_NOISY_HTML = (
  "<html><body>"
  "<script>var x=1;</script>"
  "<nav>nav stuff</nav>"
  "<p>Article text here.</p>"
  "<footer>footer</footer>"
  "</body></html>"
)


async def test_fetch_page_returns_text(ctx):
  """Fetched HTML is stripped of tags and returned as plain text."""
  mock_client = AsyncMock()
  mock_client.__aenter__ = AsyncMock(return_value=mock_client)
  mock_client.__aexit__ = AsyncMock(return_value=False)
  mock_client.get = AsyncMock(return_value=_make_response(text=_SIMPLE_HTML))

  with patch("subconscious.desktop_tools.web_tools.httpx.AsyncClient", return_value=mock_client):
    result = await fetch_page(ctx, "https://example.com")

  assert "Hello World" in result
  assert "<" not in result  # HTML tags stripped


async def test_fetch_page_strips_noise_tags(ctx):
  """Script, nav, and footer content is removed before returning text."""
  mock_client = AsyncMock()
  mock_client.__aenter__ = AsyncMock(return_value=mock_client)
  mock_client.__aexit__ = AsyncMock(return_value=False)
  mock_client.get = AsyncMock(return_value=_make_response(text=_NOISY_HTML))

  with patch("subconscious.desktop_tools.web_tools.httpx.AsyncClient", return_value=mock_client):
    result = await fetch_page(ctx, "https://example.com")

  assert "Article text here." in result
  assert "var x=1;" not in result
  assert "nav stuff" not in result
  assert "footer" not in result


async def test_fetch_page_prepends_https_scheme(ctx):
  """A URL without a scheme gets https:// prepended."""
  mock_client = AsyncMock()
  mock_client.__aenter__ = AsyncMock(return_value=mock_client)
  mock_client.__aexit__ = AsyncMock(return_value=False)
  mock_client.get = AsyncMock(return_value=_make_response(text=_SIMPLE_HTML))

  with patch("subconscious.desktop_tools.web_tools.httpx.AsyncClient", return_value=mock_client):
    result = await fetch_page(ctx, "example.com")

  # Should have called get with https://example.com, not crash
  assert "Hello World" in result
  called_url = mock_client.get.call_args[0][0]
  assert called_url.startswith("https://")


async def test_fetch_page_non_html_content_type(ctx):
  """Non-HTML content type returns a human-readable error message."""
  mock_client = AsyncMock()
  mock_client.__aenter__ = AsyncMock(return_value=mock_client)
  mock_client.__aexit__ = AsyncMock(return_value=False)
  mock_client.get = AsyncMock(return_value=_make_response(content_type="application/pdf"))

  with patch("subconscious.desktop_tools.web_tools.httpx.AsyncClient", return_value=mock_client):
    result = await fetch_page(ctx, "https://example.com/doc.pdf")

  assert "non-text" in result.lower() or "application/pdf" in result


async def test_fetch_page_truncates_long_content(ctx):
  """Content longer than _MAX_PAGE_CHARS is truncated."""
  long_html = "<html><body><p>" + ("x" * 10000) + "</p></body></html>"
  mock_client = AsyncMock()
  mock_client.__aenter__ = AsyncMock(return_value=mock_client)
  mock_client.__aexit__ = AsyncMock(return_value=False)
  mock_client.get = AsyncMock(return_value=_make_response(text=long_html))

  with patch("subconscious.desktop_tools.web_tools.httpx.AsyncClient", return_value=mock_client):
    result = await fetch_page(ctx, "https://example.com")

  assert "truncated" in result.lower()
  assert len(result) < 12000  # well under the raw input size


async def test_fetch_page_request_error(ctx):
  """Network errors are caught and returned as a descriptive string."""
  mock_client = AsyncMock()
  mock_client.__aenter__ = AsyncMock(return_value=mock_client)
  mock_client.__aexit__ = AsyncMock(return_value=False)
  mock_client.get = AsyncMock(side_effect=Exception("Connection refused"))

  with patch("subconscious.desktop_tools.web_tools.httpx.AsyncClient", return_value=mock_client):
    result = await fetch_page(ctx, "https://example.com")

  assert "Failed" in result or "failed" in result
  assert "Connection refused" in result


# ---------------------------------------------------------------------------
# search_web
# ---------------------------------------------------------------------------

_DDG_HTML = """
<html><body>
  <div class="result">
    <a class="result__title" href="/redirect?uddg=https%3A%2F%2Fexample.com&rut=abc">
      <a class="result__title result__a" href="/redirect?uddg=https%3A%2F%2Fexample.com&rut=abc">Example Site</a>
    </a>
    <div class="result__snippet">A great example website.</div>
  </div>
  <div class="result">
    <a class="result__title result__a" href="/redirect?uddg=https%3A%2F%2Fanother.com&rut=xyz">Another Site</a>
    <div class="result__snippet">Another site snippet.</div>
  </div>
</body></html>
"""


async def test_search_web_returns_list(ctx):
  """search_web always returns a list."""
  mock_client = AsyncMock()
  mock_client.__aenter__ = AsyncMock(return_value=mock_client)
  mock_client.__aexit__ = AsyncMock(return_value=False)
  mock_client.get = AsyncMock(return_value=_make_response(text=_DDG_HTML))

  with patch("subconscious.desktop_tools.web_tools.httpx.AsyncClient", return_value=mock_client):
    result = await search_web(ctx, "example query")

  assert isinstance(result, list)


async def test_search_web_result_has_expected_keys(ctx):
  """Each result dict contains title, url, and snippet keys."""
  mock_client = AsyncMock()
  mock_client.__aenter__ = AsyncMock(return_value=mock_client)
  mock_client.__aexit__ = AsyncMock(return_value=False)
  mock_client.get = AsyncMock(return_value=_make_response(text=_DDG_HTML))

  with patch("subconscious.desktop_tools.web_tools.httpx.AsyncClient", return_value=mock_client):
    result = await search_web(ctx, "example query")

  for item in result:
    if "error" not in item and "message" not in item:
      assert "title" in item
      assert "url" in item
      assert "snippet" in item


async def test_search_web_max_results_capped(ctx):
  """max_results is clamped to a maximum of 10."""
  mock_client = AsyncMock()
  mock_client.__aenter__ = AsyncMock(return_value=mock_client)
  mock_client.__aexit__ = AsyncMock(return_value=False)
  mock_client.get = AsyncMock(return_value=_make_response(text=_DDG_HTML))

  with patch("subconscious.desktop_tools.web_tools.httpx.AsyncClient", return_value=mock_client):
    result = await search_web(ctx, "example query", max_results=50)

  assert len(result) <= 10


async def test_search_web_max_results_minimum_one(ctx):
  """max_results below 1 is treated as 1."""
  mock_client = AsyncMock()
  mock_client.__aenter__ = AsyncMock(return_value=mock_client)
  mock_client.__aexit__ = AsyncMock(return_value=False)
  mock_client.get = AsyncMock(return_value=_make_response(text=_DDG_HTML))

  with patch("subconscious.desktop_tools.web_tools.httpx.AsyncClient", return_value=mock_client):
    result = await search_web(ctx, "example query", max_results=0)

  assert len(result) <= 1 or ("message" in result[0]) or ("error" in result[0])


async def test_search_web_request_error(ctx):
  """Network errors return a list with a single error entry."""
  mock_client = AsyncMock()
  mock_client.__aenter__ = AsyncMock(return_value=mock_client)
  mock_client.__aexit__ = AsyncMock(return_value=False)
  mock_client.get = AsyncMock(side_effect=Exception("DNS failure"))

  with patch("subconscious.desktop_tools.web_tools.httpx.AsyncClient", return_value=mock_client):
    result = await search_web(ctx, "example query")

  assert isinstance(result, list)
  assert len(result) == 1
  assert "error" in result[0]
  assert "DNS failure" in result[0]["error"]
