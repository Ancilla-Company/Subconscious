""" Indexer ignore rules — a gitignore-style skip system.

Users can exclude files/directories from indexing by dropping a
``.subconsciousignore`` file:

  * **Globally** — at ``<data_dir>/.subconsciousignore`` (applies to every
    workspace/directory).
  * **Per directory** — a ``.subconsciousignore`` in an attached directory root,
    or in *any* subdirectory. Rules cascade: a file's patterns apply to that
    directory and everything beneath it.

Syntax is a pragmatic subset of ``.gitignore``:

  * blank lines and lines starting with ``#`` are ignored;
  * ``name``            → matches ``name`` at any depth (file or dir);
  * ``*.log``           → glob match on the basename at any depth;
  * ``build/``          → trailing slash: matches directories only;
  * ``/secret``         → leading slash: anchored to the file's directory;
  * ``docs/*.tmp``      → a slash makes the pattern path-relative (anchored);
  * ``!keep.log``       → leading ``!`` re-includes a previously excluded path.

Later rules win (gitignore semantics), so a negation can rescue a path excluded
by an earlier pattern.
"""
from __future__ import annotations

import fnmatch
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


logger = logging.getLogger("subconscious")

IGNORE_FILENAME = ".subconsciousignore"


@dataclass
class _Rule:
  base: str          # posix dir (relative to root) the rule is scoped to ("" = root)
  pattern: str       # glob pattern (no trailing slash, no leading slash)
  negate: bool       # leading '!' — re-include
  dir_only: bool     # trailing '/' — matches directories only
  anchored: bool     # contained a '/' — match path relative to base, not basename


class IgnoreMatcher:
  """Ordered set of ignore rules evaluated with gitignore-style precedence."""

  def __init__(self) -> None:
    self._rules: list[_Rule] = []

  # ------------------------------------------------------------------
  # Building
  # ------------------------------------------------------------------

  def add_patterns(self, lines, base: str = "") -> None:
    """Add raw pattern *lines*, scoped to directory *base* (posix, rel to root)."""
    base = base.strip("/")
    for raw in lines:
      line = raw.rstrip("\n").rstrip()
      if not line or line.startswith("#"):
        continue
      negate = line.startswith("!")
      if negate:
        line = line[1:]
      if not line:
        continue
      dir_only = line.endswith("/")
      if dir_only:
        line = line[:-1]
      # A slash anywhere (after stripping a trailing one) anchors the pattern
      # to *base*; strip a single leading slash used purely for anchoring.
      anchored = "/" in line
      if line.startswith("/"):
        line = line[1:]
      if not line:
        continue
      self._rules.append(_Rule(base=base, pattern=line, negate=negate,
                               dir_only=dir_only, anchored=anchored))

  def add_file(self, path: Path, base: str = "") -> bool:
    """Load a ``.subconsciousignore`` file if it exists. Returns True if loaded."""
    try:
      if not path.is_file():
        return False
      lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
      return False
    self.add_patterns(lines, base=base)
    return True

  def clone(self) -> "IgnoreMatcher":
    """Return a shallow copy so a subtree can extend rules without leaking back."""
    m = IgnoreMatcher()
    m._rules = list(self._rules)
    return m

  # ------------------------------------------------------------------
  # Matching
  # ------------------------------------------------------------------

  def is_ignored(self, rel_path: str, is_dir: bool) -> bool:
    """Return True if *rel_path* (posix, relative to root) should be skipped."""
    rel_path = rel_path.replace("\\", "/").strip("/")
    result = False
    for rule in self._rules:
      if rule.dir_only and not is_dir:
        continue
      sub = self._relative_to_base(rel_path, rule.base)
      if sub is None:
        continue
      if self._match(sub, rule):
        result = not rule.negate
    return result

  @staticmethod
  def _relative_to_base(rel_path: str, base: str) -> Optional[str]:
    if not base:
      return rel_path
    if rel_path == base:
      return ""
    prefix = base + "/"
    if rel_path.startswith(prefix):
      return rel_path[len(prefix):]
    return None

  @staticmethod
  def _match(sub: str, rule: _Rule) -> bool:
    if not sub:
      return False
    parts = sub.split("/")
    if rule.anchored:
      # Segment-wise match anchored at base. Unlike raw fnmatch, a ``*`` does
      # not cross ``/`` (gitignore semantics). Matching all pattern segments
      # against the leading path segments ignores both the exact path and
      # anything beneath it (so "a/b" also excludes "a/b/c.txt"). ``**`` matches
      # any remaining segments.
      pat_parts = rule.pattern.split("/")
      if len(parts) < len(pat_parts):
        return False
      for pp, sp in zip(pat_parts, parts):
        if pp == "**":
          return True
        if not fnmatch.fnmatch(sp, pp):
          return False
      return True
    # Unanchored: match the basename, or any single path component.
    if fnmatch.fnmatch(parts[-1], rule.pattern):
      return True
    return any(fnmatch.fnmatch(part, rule.pattern) for part in parts)

  def __len__(self) -> int:
    return len(self._rules)
