""" In-process background job registry.

    Long-running, non-chat operations (directory indexing, future sync, bulk
    imports, etc.) are tracked here so the UI can show what's happening in the
    background. Every state change is published on the shared EventBus as a
    ``job.updated`` event so the desktop UI (and any other subscriber) can
    reflect progress live without polling.
"""
from __future__ import annotations

import time
import uuid
import asyncio
import logging
from dataclasses import dataclass, field, asdict
from typing import Optional

from .events import EventBus


logger = logging.getLogger("subconscious")


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
  """Registry of background jobs with EventBus fan-out for the UI."""

  def __init__(self, events: EventBus):
    self._events = events
    self._jobs: dict[str, Job] = {}
    # The main asyncio loop, captured at engine start. Lets mutations made from
    # worker threads (e.g. the indexing thread) still fan out live events.
    self._loop: Optional[asyncio.AbstractEventLoop] = None

  def set_loop(self, loop: "asyncio.AbstractEventLoop") -> None:
    """Register the main event loop so thread-safe publishing works."""
    self._loop = loop

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
    # Publish a generic refresh so the UI re-reads the list.
    self._publish({"type": "job.cleared", "data": {}})

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
    self._publish({"type": "job.updated", "data": job.snapshot()})

  def _publish(self, event: dict) -> None:
    """Fire-and-forget publish; safe from the loop thread or a worker thread."""
    # Fast path: we're on a running loop (the loop thread) → schedule directly.
    try:
      asyncio.get_running_loop()
      asyncio.create_task(self._events.publish(event))
      return
    except RuntimeError:
      pass
    # Worker-thread path: marshal onto the captured main loop, if any.
    loop = self._loop
    if loop is None or loop.is_closed():
      return
    try:
      loop.call_soon_threadsafe(
        lambda: asyncio.ensure_future(self._events.publish(event))
      )
    except RuntimeError:
      # Loop shut down between the check and the call — drop the event.
      pass
