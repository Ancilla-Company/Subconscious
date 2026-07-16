""" Knowledge-graph extraction.

Two tiers, both emitting the same triple shape so the sidecar can store them
uniformly:

  * :func:`extract_structural` — deterministic, dependency-free, runs inside the
    indexing worker thread. Python files are parsed with the stdlib :mod:`ast`
    (imports / class / function definitions); other languages fall back to a
    light regex for definitions. Produces ``file -> imports -> module`` and
    ``file -> defines -> symbol`` edges with line-level provenance.

  * :func:`parse_semantic_triples` — parses the JSON a language model returns
    for Tier-2 semantic ``(subject, predicate, object)`` extraction. The LLM
    call itself lives on the engine (it is async); this module only builds the
    prompt and validates the response so it can run anywhere.

A "triple" is a dict::

    {subj, subj_type, pred, obj, obj_type, line?, document_id?, chunk_id?}
"""
from __future__ import annotations

import ast
import re
import json
import logging
from typing import Optional


logger = logging.getLogger("subconscious")

# Languages we understand structurally beyond plain Python.
_DEF_PATTERNS = {
  ".js":  re.compile(r"^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)", re.M),
  ".ts":  re.compile(r"^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)", re.M),
  ".jsx": re.compile(r"^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)", re.M),
  ".tsx": re.compile(r"^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)", re.M),
  ".go":  re.compile(r"^\s*func\s+([A-Za-z_]\w*)", re.M),
  ".rs":  re.compile(r"^\s*(?:pub\s+)?fn\s+([A-Za-z_]\w*)", re.M),
  ".java": re.compile(r"^\s*(?:public|private|protected)\s+(?:class|interface)\s+([A-Za-z_]\w*)", re.M),
  ".c":   re.compile(r"^\s*[A-Za-z_][\w\s\*]*\s+([A-Za-z_]\w*)\s*\(", re.M),
  ".cpp": re.compile(r"^\s*[A-Za-z_][\w\s\*:]*\s+([A-Za-z_]\w*)\s*\(", re.M),
}
_CLASS_PATTERN = re.compile(r"^\s*(?:export\s+)?(?:abstract\s+)?class\s+([A-Za-z_]\w*)", re.M)


def extract_structural(rel_path: str, text: str, ext: str) -> list[dict]:
  """Return structural triples for a single file (no provenance ids yet)."""
  triples: list[dict] = []
  file_key = rel_path.replace("\\", "/")

  def add(pred: str, obj: str, obj_type: str, line: Optional[int]) -> None:
    if not obj:
      return
    triples.append({
      "subj": file_key, "subj_type": "file",
      "pred": pred, "obj": obj, "obj_type": obj_type,
      "line": line,
    })

  if ext == ".py":
    try:
      tree = ast.parse(text)
    except SyntaxError:
      return triples
    for node in ast.walk(tree):
      if isinstance(node, ast.Import):
        for alias in node.names:
          add("imports", alias.name.split(".")[0], "module", getattr(node, "lineno", None))
      elif isinstance(node, ast.ImportFrom):
        if node.module:
          add("imports", node.module.split(".")[0], "module", getattr(node, "lineno", None))
      elif isinstance(node, ast.ClassDef):
        add("defines", node.name, "class", getattr(node, "lineno", None))
      elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        add("defines", node.name, "function", getattr(node, "lineno", None))
    return triples

  # Non-Python: regex definitions + classes with 1-based line numbers.
  for m in _CLASS_PATTERN.finditer(text):
    line = text.count("\n", 0, m.start()) + 1
    add("defines", m.group(1), "class", line)
  pat = _DEF_PATTERNS.get(ext)
  if pat:
    for m in pat.finditer(text):
      line = text.count("\n", 0, m.start()) + 1
      add("defines", m.group(1), "function", line)
  return triples


# ---------------------------------------------------------------------------
# Tier 2 — semantic (LLM) triple extraction
# ---------------------------------------------------------------------------

SEMANTIC_SYSTEM_PROMPT = (
  "You extract a knowledge graph from text. Given a passage, return ONLY a JSON "
  "array of triples. Each triple is an object with keys \"subject\", "
  "\"predicate\", \"object\" using concise noun phrases for subject/object and a "
  "short verb phrase for predicate. Extract at most 8 of the most salient facts. "
  "Return [] if there are no clear facts. Do not include any prose outside the JSON."
)


def build_semantic_prompt(content: str, max_chars: int = 4000) -> str:
  snippet = content[:max_chars]
  return f"Extract knowledge-graph triples from the following passage:\n\n{snippet}"


def parse_semantic_triples(
  raw: str,
  document_id: int,
  chunk_id: int,
  max_triples: int = 8,
) -> list[dict]:
  """Parse and validate the model's JSON triple response into store triples."""
  text = (raw or "").strip()
  if not text:
    return []
  # Tolerate models that wrap JSON in code fences or add stray text.
  if "```" in text:
    parts = text.split("```")
    for part in parts:
      part = part.strip()
      if part.startswith("json"):
        part = part[4:].strip()
      if part.startswith("[") or part.startswith("{"):
        text = part
        break
  start = text.find("[")
  end = text.rfind("]")
  if start != -1 and end != -1 and end > start:
    text = text[start:end + 1]
  try:
    data = json.loads(text)
  except json.JSONDecodeError:
    return []
  if not isinstance(data, list):
    return []

  triples: list[dict] = []
  for item in data[:max_triples]:
    if not isinstance(item, dict):
      continue
    subj = str(item.get("subject", "")).strip()[:200]
    pred = str(item.get("predicate", "")).strip()[:120]
    obj = str(item.get("object", "")).strip()[:200]
    if not subj or not pred or not obj:
      continue
    triples.append({
      "subj": subj, "subj_type": "entity",
      "pred": pred, "obj": obj, "obj_type": "entity",
      "document_id": document_id, "chunk_id": chunk_id,
    })
  return triples
