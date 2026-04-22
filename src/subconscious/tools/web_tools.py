"""
Web tools — fetch pages, search the web (DuckDuckGo), connectivity check.
Requires: httpx, beautifulsoup4
Optional for speed test: speedtest-cli
"""

import re
import time
import httpx
import logging
import asyncio
import urllib.parse
# import speedtest as st  # speedtest-cli package
from . import EngineContext
from bs4 import BeautifulSoup
from pydantic_ai import RunContext


logger = logging.getLogger("subconscious")

# Max characters returned from a fetched page to avoid token flooding
_MAX_PAGE_CHARS = 8000
_REQUEST_TIMEOUT = 15  # seconds


async def fetch_page(ctx: RunContext[EngineContext], url: str) -> str:
  """
  Fetch the main text content of a web page.
  Returns cleaned plain text (HTML tags stripped), truncated to 8000 characters.
  Handles redirects automatically.

  Args:
    url: The full URL to fetch, e.g. 'https://example.com/article'.
  """
  if not url.startswith(("http://", "https://")):
    url = "https://" + url

  try:
    async with httpx.AsyncClient(follow_redirects=True, timeout=_REQUEST_TIMEOUT) as client:
      response = await client.get(url, headers={"User-Agent": "Subconscious/1.0"})
      response.raise_for_status()

    content_type = response.headers.get("content-type", "")
    if "text/html" not in content_type and "text/plain" not in content_type:
      return f"Page returned non-text content ({content_type}). Cannot extract text."

    soup = BeautifulSoup(response.text, "html.parser")
    # Remove script, style, nav, header, footer noise
    for tag in soup(["script", "style", "nav", "header", "footer", "aside", "noscript"]):
      tag.decompose()

    text = soup.get_text(separator="\n")
    # Collapse excessive blank lines
    text = re.sub(r'\n{3,}', '\n\n', text).strip()

    if len(text) > _MAX_PAGE_CHARS:
      text = text[:_MAX_PAGE_CHARS] + f"\n\n[... content truncated at {_MAX_PAGE_CHARS} chars]"

    return text or "Page fetched but no readable text content found."

  except Exception as exc:
    return f"Failed to fetch '{url}': {exc}"


async def search_web(ctx: RunContext[EngineContext], query: str, max_results: int = 5) -> list[dict]:
  """
  Search the web using DuckDuckGo (no API key required) and return a list
  of results. Each result has 'title', 'url', and 'snippet' keys.

  Args:
    query: The search query string.
    max_results: Number of results to return (1–10, default 5).
  """
  max_results = max(1, min(max_results, 10))
  encoded = urllib.parse.quote_plus(query)
  url = f"https://html.duckduckgo.com/html/?q={encoded}"

  try:
    async with httpx.AsyncClient(follow_redirects=True, timeout=_REQUEST_TIMEOUT) as client:
      response = await client.get(url, headers={"User-Agent": "Mozilla/5.0"})
      response.raise_for_status()

    soup = BeautifulSoup(response.text, "html.parser")
    results = []
    for result in soup.select(".result")[:max_results]:
      title_el = result.select_one(".result__title a")
      snippet_el = result.select_one(".result__snippet")
      if not title_el:
        continue
      href = title_el.get("href", "")
      # DuckDuckGo wraps links — extract the real URL
      if "uddg=" in href:
        href = urllib.parse.unquote(href.split("uddg=")[-1].split("&")[0])
      results.append({
        "title": title_el.get_text(strip=True),
        "url": href,
        "snippet": snippet_el.get_text(strip=True) if snippet_el else "",
      })

    return results or [{"message": "No results found for that query."}]

  except Exception as exc:
    return [{"error": f"Search failed: {exc}"}]


async def check_connectivity(ctx: RunContext[EngineContext]) -> dict:
  """
  Check whether the machine has a working internet connection.
  Returns a dict with 'connected' (bool) and 'latency_ms' (float or None).
  """
  try:
    start = time.monotonic()
    async with httpx.AsyncClient(timeout=5) as client:
      await client.get("https://www.google.com")
    latency_ms = round((time.monotonic() - start) * 1000, 1)
    return {"connected": True, "latency_ms": latency_ms}
  except Exception:
    return {"connected": False, "latency_ms": None}


async def speed_test(ctx: RunContext[EngineContext]) -> dict:
  """
  Run a basic internet speed test and return download/upload speeds in Mbps.
  This can take 10–30 seconds to complete.
  Returns a dict with 'download_mbps', 'upload_mbps', and 'ping_ms'.
  """
  try:
    loop = asyncio.get_event_loop()

    def _run():
      s = st.Speedtest(secure=True)
      s.get_best_server()
      s.download()
      s.upload(pre_allocate=False)
      return s.results.dict()

    results = await loop.run_in_executor(None, _run)
    return {
      "download_mbps": round(results["download"] / 1_000_000, 2),
      "upload_mbps":   round(results["upload"]   / 1_000_000, 2),
      "ping_ms":       round(results["ping"], 1),
      "server":        results.get("server", {}).get("sponsor", "unknown"),
    }
  except ImportError:
    return {"error": "speedtest-cli not installed. Run: pip install speedtest-cli"}
  except Exception as exc:
    return {"error": f"Speed test failed: {exc}"}


TOOLS = [fetch_page, search_web, check_connectivity, speed_test]
