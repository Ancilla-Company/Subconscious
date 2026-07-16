""" In-process background job registry """
from __future__ import annotations

import time
import uuid
import asyncio
import logging
from typing import Callable, Optional
from dataclasses import dataclass, field, asdict


logger = logging.getLogger("subconscious")

# A job listener receives the changed job's snapshot (or None for bulk changes
# like clear_finished). It should be cheap and non-blocking.
JobListener = Callable[[Optional[dict]], None]


class JobStatus:
  """Lifecycle states for a background job."""
  RUNNING   = "running"
  COMPLETED = "completed"
  FAILED    = "failed"
  CANCELLED = "cancelled"


@dataclass
class Job:
  """A single tracked background job."""
  id: str
  type: str                       # e.g. "index"
  title: str
  status: str = JobStatus.RUNNING
  progress: float = 0.0           # 0.0 – 1.0 (best-effort; may be indeterminate)
  total: int = 0                  # total units of work (0 = unknown/indeterminate)
  current: int = 0                # units completed so far
  message: str = ""               # latest human-readable status line
  error: Optional[str] = None
  created_at: float = field(default_factory=time.time)
  updated_at: float = field(default_factory=time.time)

  def snapshot(self) -> dict:
    return asdict(self)


class JobManager:
  """Registry of background jobs with direct listener callbacks for the UI."""

  def __init__(self):
    self._jobs: dict[str, Job] = {}
    # In-process listeners notified on any job change (the UI registers here).
    self._listeners: list[JobListener] = []
    # The main asyncio loop, captured at engine start. Lets mutations made from
    # worker threads (e.g. the indexing thread) marshal listener calls back
    # onto the loop so UI state updates are thread-safe.
    self._loop: Optional[asyncio.AbstractEventLoop] = None

  def set_loop(self, loop: "asyncio.AbstractEventLoop") -> None:
    """Register the main event loop so listener dispatch is thread-safe."""
    self._loop = loop

  # ------------------------------------------------------------------
  # Listeners
  # ------------------------------------------------------------------

  def add_listener(self, callback: JobListener) -> None:
    """Register a callback invoked (on the main loop) whenever a job changes."""
    if callback not in self._listeners:
      self._listeners.append(callback)

  def remove_listener(self, callback: JobListener) -> None:
    """Remove a previously registered listener."""
    try:
      self._listeners.remove(callback)
    except ValueError:
      pass

  # ------------------------------------------------------------------
  # Mutations
  # ------------------------------------------------------------------

  def create(self, type: str, title: str, total: int = 0) -> Job:
    """Create and register a new running job."""
    job = Job(id=str(uuid.uuid4()), type=type, title=title, total=total)
    self._jobs[job.id] = job
    self._emit(job)
    return job

  def update(
    self,
    job: Job,
    *,
    current: Optional[int] = None,
    total: Optional[int] = None,
    message: Optional[str] = None,
    progress: Optional[float] = None,
  ) -> None:
    """Update progress/message for a running job and notify subscribers."""
    if current is not None:
      job.current = current
    if total is not None:
      job.total = total
    if message is not None:
      job.message = message
    if progress is not None:
      job.progress = max(0.0, min(1.0, progress))
    elif job.total:
      job.progress = max(0.0, min(1.0, job.current / job.total))
    job.updated_at = time.time()
    self._emit(job)

  def complete(self, job: Job, message: str = "") -> None:
    job.status = JobStatus.COMPLETED
    job.progress = 1.0
    if message:
      job.message = message
    job.updated_at = time.time()
    self._emit(job)

  def fail(self, job: Job, error: str) -> None:
    job.status = JobStatus.FAILED
    job.error = error
    job.message = error
    job.updated_at = time.time()
    self._emit(job)

  def clear_finished(self) -> None:
    """Drop completed/failed/cancelled jobs, keeping only running ones."""
    self._jobs = {
      k: v for k, v in self._jobs.items() if v.status == JobStatus.RUNNING
    }
    # Notify listeners to re-read the list (bulk change → no single job).
    self._notify(None)

  # ------------------------------------------------------------------
  # Queries
  # ------------------------------------------------------------------

  def list(self) -> list[dict]:
    """Return job snapshots, most recent first."""
    return [
      j.snapshot()
      for j in sorted(self._jobs.values(), key=lambda j: j.created_at, reverse=True)
    ]

  def active_count(self) -> int:
    """Number of jobs currently running."""
    return sum(1 for j in self._jobs.values() if j.status == JobStatus.RUNNING)

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  def _emit(self, job: Job) -> None:
    self._notify(job.snapshot())

  def _notify(self, data: Optional[dict]) -> None:
    """Deliver a job change to every listener, on the main loop thread."""
    if not self._listeners:
      return
    for cb in list(self._listeners):
      self._dispatch(cb, data)

  def _dispatch(self, cb: JobListener, data: Optional[dict]) -> None:
    # Already on the loop thread → call directly. Otherwise (worker thread)
    # marshal onto the captured main loop so UI state updates stay thread-safe.
    try:
      asyncio.get_running_loop()
      self._safe_call(cb, data)
      return
    except RuntimeError:
      pass
    loop = self._loop
    if loop is None or loop.is_closed():
      return
    try:
      loop.call_soon_threadsafe(self._safe_call, cb, data)
    except RuntimeError:
      # Loop shut down between the check and the call — drop the notification.
      pass

  @staticmethod
  def _safe_call(cb: JobListener, data: Optional[dict]) -> None:
    try:
      cb(data)
    except Exception as exc:
      logger.warning("Job listener error: %s", exc)
