"""
Mobile web-search tool — lightweight HTTP-only variant.

Uses only httpx (available on pypi.flet.dev for all mobile architectures).
Does NOT import beautifulsoup4 / lxml (wheel availability on mobile varies).
Returns raw text extracts rather than parsed HTML.
"""

from __future__ import annotations

import httpx
from pydantic_ai import RunContext

from ..tools import EngineContext

_USER_AGENT = "Subconscious/1.0 (Mobile; +https://github.com/Ancilla-Company/Subconscious)"
_TIMEOUT = 15.0


async def web_fetch(ctx: RunContext[EngineContext], url: str) -> dict:
  """
  Fetch a URL and return its raw text content (first 8 KB).

  Args:
    url: The fully-qualified URL to fetch.
  Returns:
    dict with 'url', 'status_code', and 'text' (up to 8 KB), or 'error'.
  """
  try:
    async with httpx.AsyncClient(
      timeout=_TIMEOUT,
      follow_redirects=True,
      headers={"User-Agent": _USER_AGENT},
    ) as client:
      resp = await client.get(url)
      resp.raise_for_status()
      text = resp.text[:8192]
      return {"url": url, "status_code": resp.status_code, "text": text}
  except httpx.HTTPStatusError as e:
    return {"error": f"HTTP {e.response.status_code}: {e.request.url}"}
  except Exception as e:
    return {"error": f"Request failed: {e}"}


async def web_search_ddg(ctx: RunContext[EngineContext], query: str, max_results: int = 5) -> dict:
  """
  Perform a DuckDuckGo Lite search and return plain-text result snippets.
  Uses only httpx — no JS rendering or HTML parsing libraries required.

  Args:
    query:       The search query string.
    max_results: Maximum number of results to return (1-10).
  Returns:
    dict with 'query' and 'results' list of {title, url, snippet} dicts, or 'error'.
  """
  max_results = max(1, min(max_results, 10))
  try:
    async with httpx.AsyncClient(
      timeout=_TIMEOUT,
      follow_redirects=True,
      headers={"User-Agent": _USER_AGENT},
    ) as client:
      resp = await client.post(
        "https://lite.duckduckgo.com/lite/",
        data={"q": query},
        headers={"Content-Type": "application/x-www-form-urlencoded"},
      )
      resp.raise_for_status()
      # Parse result links from the plain HTML response using basic string ops
      # to avoid needing beautifulsoup4.
      lines = resp.text.splitlines()
      results = []
      i = 0
      while i < len(lines) and len(results) < max_results:
        line = lines[i].strip()
        if 'class="result-link"' in line or 'uddg=' in line:
          # Extract href / uddg URL
          url_start = line.find('href="')
          if url_start == -1:
            url_start = line.find("uddg=")
          if url_start != -1:
            url_val = line[url_start:].split('"')[1] if 'href="' in line else ""
            # Extract visible text between tags
            text_start = line.find(">")
            text_end = line.rfind("<")
            snippet = line[text_start + 1:text_end].strip() if text_start != -1 and text_end != -1 else ""
            if url_val:
              results.append({"title": snippet, "url": url_val, "snippet": ""})
        i += 1
      return {"query": query, "results": results}
  except httpx.HTTPStatusError as e:
    return {"error": f"HTTP {e.response.status_code}"}
  except Exception as e:
    return {"error": f"Search failed: {e}"}


TOOLS = [web_fetch, web_search_ddg]
