""" Workspace directory indexing for retrieval (RAG Phase 1 + storage) """
from __future__ import annotations

import hashlib
import logging
import pathlib

from sqlalchemy import select, delete

from .jobs import Job, JobManager
from .db.models import IndexedDocument, DocumentChunk


logger = logging.getLogger("subconscious")


# File types we can extract text from.
_PLAIN_EXTS = {
  ".txt", ".md", ".markdown", ".rst", ".py", ".js", ".ts", ".tsx", ".jsx",
  ".json", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".csv", ".html", ".htm",
  ".css", ".scss", ".java", ".c", ".cc", ".cpp", ".h", ".hpp", ".go", ".rs",
  ".rb", ".php", ".sh", ".bat", ".ps1", ".sql", ".xml", ".log", ".tex",
}
_STRUCTURED_EXTS = {".pdf", ".docx", ".xlsx"}

_CHUNK_CHARS = 1500          # target characters per chunk
_CHUNK_OVERLAP = 200         # overlap between consecutive chunks
_MAX_FILE_BYTES = 20_000_000  # skip files larger than 20 MB
_HASH_LIMIT = 5_000_000       # only content-hash files up to 5 MB; larger rely on size+mtime


class WorkspaceIndexer:
  """Ingests workspace directories into the chunk store."""

  def __init__(self, db, jobs: JobManager):
    self.db = db
    self.jobs = jobs

  # ------------------------------------------------------------------
  # Public
  # ------------------------------------------------------------------

  async def reindex(self, workspace_id: int, directories: list, job: Job) -> None:
    """Incrementally (re)index every indexable file under *directories*."""
    files: list[tuple[str, pathlib.Path]] = []
    for d in directories:
      root = pathlib.Path(d)
      if not root.exists() or not root.is_dir():
        continue
      for p in root.rglob("*"):
        if p.is_file() and self._is_indexable(p):
          files.append((str(root), p))

    self.jobs.update(job, total=len(files), current=0, message=f"Found {len(files)} files")

    seen_paths: set[str] = set()
    indexed = 0
    for i, (root, p) in enumerate(files):
      seen_paths.add(str(p))
      try:
        if await self._index_file(workspace_id, root, p):
          indexed += 1
      except Exception as exc:  # never let one bad file kill the whole run
        logger.warning(f"Indexing error for {p}: {exc}")
        await self._mark_error(workspace_id, str(p), str(exc))
      self.jobs.update(job, current=i + 1, message=p.name)

    # Drop documents whose files were removed or whose directory was detached.
    await self._prune(workspace_id, seen_paths)
    job.message = f"Indexed {indexed} of {len(files)} files"

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  @staticmethod
  def _is_indexable(p: pathlib.Path) -> bool:
    ext = p.suffix.lower()
    if ext not in _PLAIN_EXTS and ext not in _STRUCTURED_EXTS:
      return False
    try:
      return p.stat().st_size <= _MAX_FILE_BYTES
    except OSError:
      return False

  async def _index_file(self, workspace_id: int, root: str, p: pathlib.Path) -> bool:
    """Index a single file. Returns True when (re)chunked, False when skipped."""
    stat = p.stat()
    size = stat.st_size
    mtime = int(stat.st_mtime)
    path_str = str(p)

    async with self.db.get_session() as session:
      existing = await session.scalar(
        select(IndexedDocument).where(
          IndexedDocument.workspace_id == workspace_id,
          IndexedDocument.path == path_str,
        )
      )

      content_hash = self._hash_file(p) if size <= _HASH_LIMIT else None

      # Unchanged since last index → skip.
      if existing and existing.status == "indexed" and existing.mtime == mtime and existing.size == size:
        if content_hash is None or existing.content_hash == content_hash:
          return False

      text = self._extract_text(p)
      chunks = self._chunk_text(text)

      if existing:
        doc = existing
        # Remove stale chunks before re-inserting.
        await session.execute(
          delete(DocumentChunk).where(DocumentChunk.document_id == doc.id)
        )
        doc.size = size
        doc.mtime = mtime
        doc.content_hash = content_hash
        doc.directory = root
        doc.chunk_count = len(chunks)
        doc.status = "indexed"
        doc.error = None
      else:
        doc = IndexedDocument(
          workspace_id=workspace_id,
          path=path_str,
          directory=root,
          size=size,
          mtime=mtime,
          content_hash=content_hash,
          chunk_count=len(chunks),
          status="indexed",
        )
        session.add(doc)
        await session.flush()  # assign doc.id

      for ordinal, (content, start_line, end_line) in enumerate(chunks):
        session.add(
          DocumentChunk(
            document_id=doc.id,
            workspace_id=workspace_id,
            ordinal=ordinal,
            content=content,
            start_line=start_line,
            end_line=end_line,
            token_estimate=max(1, len(content) // 4),
            # Phase 2 extension point: compute and store an embedding here.
            embedding=None,
          )
        )
      await session.commit()
    return True

  async def _mark_error(self, workspace_id: int, path_str: str, error: str) -> None:
    async with self.db.get_session() as session:
      existing = await session.scalar(
        select(IndexedDocument).where(
          IndexedDocument.workspace_id == workspace_id,
          IndexedDocument.path == path_str,
        )
      )
      if existing:
        existing.status = "error"
        existing.error = error[:2000]
      else:
        session.add(
          IndexedDocument(
            workspace_id=workspace_id,
            path=path_str,
            status="error",
            error=error[:2000],
            chunk_count=0,
          )
        )
      await session.commit()

  async def _prune(self, workspace_id: int, seen_paths: set) -> None:
    """Delete documents (and their chunks) no longer present on disk."""
    async with self.db.get_session() as session:
      docs = await session.scalars(
        select(IndexedDocument).where(IndexedDocument.workspace_id == workspace_id)
      )
      stale_ids = [d.id for d in docs.all() if d.path not in seen_paths]
      if stale_ids:
        await session.execute(
          delete(DocumentChunk).where(DocumentChunk.document_id.in_(stale_ids))
        )
        await session.execute(
          delete(IndexedDocument).where(IndexedDocument.id.in_(stale_ids))
        )
        await session.commit()

  # ------------------------------------------------------------------
  # Text extraction & chunking
  # ------------------------------------------------------------------

  @staticmethod
  def _hash_file(p: pathlib.Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
      for block in iter(lambda: f.read(65536), b""):
        h.update(block)
    return h.hexdigest()

  @staticmethod
  def _extract_text(p: pathlib.Path) -> str:
    ext = p.suffix.lower()
    if ext == ".docx":
      import docx as _docx
      doc = _docx.Document(p)
      return "\n".join(para.text for para in doc.paragraphs)
    if ext == ".xlsx":
      import openpyxl as _openpyxl
      wb = _openpyxl.load_workbook(p, data_only=True, read_only=True)
      rows = []
      for sheet in wb.worksheets:
        rows.append(f"--- Sheet: {sheet.title} ---")
        for row in sheet.iter_rows(values_only=True):
          if any(cell is not None for cell in row):
            rows.append("\t".join(str(c) if c is not None else "" for c in row))
      return "\n".join(rows)
    if ext == ".pdf":
      import pypdf as _pypdf
      reader = _pypdf.PdfReader(p)
      pages = []
      for i, page in enumerate(reader.pages):
        t = page.extract_text()
        if t:
          pages.append(f"--- Page {i + 1} ---\n{t}")
      return "\n".join(pages)
    # Plain text (best-effort decode).
    return p.read_bytes().decode("utf-8", errors="replace")

  @staticmethod
  def _chunk_text(text: str) -> list:
    """Split text into overlapping character chunks with 1-based line ranges."""
    if not text.strip():
      return []

    # Build a sorted list of char offsets at the start of each line so a chunk's
    # char span can be mapped back to 1-based line numbers.
    offsets = [0]
    for i, ch in enumerate(text):
      if ch == "\n":
        offsets.append(i + 1)

    def line_of(offset: int) -> int:
      # Binary-ish search over sorted offsets.
      lo, hi = 0, len(offsets) - 1
      while lo < hi:
        mid = (lo + hi + 1) // 2
        if offsets[mid] <= offset:
          lo = mid
        else:
          hi = mid - 1
      return lo + 1  # 1-based

    chunks = []
    n = len(text)
    start = 0
    step = max(1, _CHUNK_CHARS - _CHUNK_OVERLAP)
    while start < n:
      end = min(n, start + _CHUNK_CHARS)
      content = text[start:end].strip()
      if content:
        chunks.append((content, line_of(start), line_of(max(start, end - 1))))
      start += step
    return chunks
