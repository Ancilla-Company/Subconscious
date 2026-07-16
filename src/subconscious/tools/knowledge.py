"""
Knowledge retrieval tools — search a workspace's indexed directories (RAG).

These let the agent pull relevant passages from the files attached to the
current workspace. Content is indexed into per-directory sidecar stores; these
tools query them:

  * ``search_knowledge``       — hybrid keyword + vector retrieval of chunks.
  * ``search_knowledge_graph`` — GraphRAG: retrieve seed chunks, then expand
                                 along the knowledge graph to surface connected
                                 context (related passages + graph facts).

Both are read-only (query) operations scoped to the current workspace.
"""

from . import EngineContext
from pydantic_ai import RunContext


def _format_hit(hit: dict) -> dict:
  """Trim a retrieval hit to a compact, model-friendly shape."""
  return {
    "path": hit.get("path", ""),
    "start_line": hit.get("start_line"),
    "end_line": hit.get("end_line"),
    "score": round(float(hit.get("score", 0.0)), 4),
    "content": hit.get("content", ""),
  }


async def search_knowledge(
  ctx: RunContext[EngineContext],
  query: str,
  limit: int = 6,
  mode: str = "hybrid",
) -> list[dict]:
  """
  Search the current workspace's indexed files for passages relevant to a query.

  Use this to ground answers in the user's own documents and code rather than
  guessing. Returns the most relevant chunks with their file path and line range.

  Args:
    query: What to look for, in natural language or keywords.
    limit: Maximum number of passages to return (default 6).
    mode:  Retrieval strategy — "hybrid" (default, keyword + semantic vector),
           "keyword" (exact substring), or "vector" (semantic similarity only).
  """
  engine = ctx.deps.engine
  if engine is None:
    return [{"error": "Retrieval is unavailable (no engine context)."}]
  if mode not in ("hybrid", "keyword", "vector"):
    mode = "hybrid"
  results = await engine.search_workspace(
    ctx.deps.workspace_id, query, limit=max(1, min(limit, 25)), mode=mode
  )
  if not results:
    return [{"message": "No indexed content matched. The workspace may have no "
                        "attached directories, or nothing relevant was found."}]
  return [_format_hit(r) for r in results]


async def search_knowledge_graph(
  ctx: RunContext[EngineContext],
  query: str,
  limit: int = 6,
) -> dict:
  """
  GraphRAG search over the current workspace: find passages relevant to the
  query, then follow the knowledge graph (imports/definitions for code, and
  extracted entity relationships for prose) to gather connected context.

  Prefer this over plain search when a question spans multiple files or needs
  the relationships between things (e.g. "how does X connect to Y", "what
  depends on Z"). Returns seed passages, related passages reached via the graph,
  and the graph facts (nodes + edges) that connected them.

  Args:
    query: What to investigate, in natural language.
    limit: Maximum seed/related passages to return (default 6).
  """
  engine = ctx.deps.engine
  if engine is None:
    return {"error": "Retrieval is unavailable (no engine context)."}
  data = await engine.graph_search_workspace(
    ctx.deps.workspace_id, query, limit=max(1, min(limit, 25))
  )
  seeds = [_format_hit(s) for s in data.get("seeds", [])]
  related = [_format_hit(r) for r in data.get("related", [])]
  graph = data.get("graph", {"nodes": [], "edges": []})

  # Summarise edges as readable "subject —rel→ object" facts using node labels.
  nodes_by_id = {n["id"]: n for n in graph.get("nodes", [])}
  facts: list[str] = []
  for e in graph.get("edges", []):
    src = nodes_by_id.get(e.get("src"), {})
    dst = nodes_by_id.get(e.get("dst"), {})
    if src and dst:
      facts.append(f"{src.get('label', '?')} —{e.get('rel', 'related')}→ {dst.get('label', '?')}")

  if not seeds and not related:
    return {"message": "No indexed content matched for graph search."}
  return {
    "seeds": seeds,
    "related": related,
    "facts": facts[:40],
  }


TOOLS = [search_knowledge, search_knowledge_graph]
