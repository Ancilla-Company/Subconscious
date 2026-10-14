"""Hybrid logical clock (webrtc.md 7.3).

A stamp is ``(physical_ms, counter)`` rendered as fixed width text so plain
string comparison orders stamps. Ties between nodes break on the node id, which
callers do by comparing ``(hlc, origin_node_id)`` tuples.
"""

from __future__ import annotations

import threading
import time
from collections.abc import Callable

MAX_DRIFT_MS = 5 * 60 * 1000
_MAX_COUNTER = 99_999
_MAX_MS = 9_999_999_999_999


class ClockSkewError(ValueError):
    """A remote stamp is further ahead of local time than allowed."""


class InvalidStamp(ValueError):
    """Not a well formed clock stamp."""


def format_stamp(physical_ms: int, counter: int) -> str:
    return f"{physical_ms:013d}.{counter:05d}"


def parse_stamp(value: object) -> tuple[int, int]:
    if not isinstance(value, str) or len(value) != 19 or value[13] != ".":
        raise InvalidStamp("Malformed clock stamp.")
    head, tail = value[:13], value[14:]
    if not (head.isascii() and head.isdigit() and tail.isascii() and tail.isdigit()):
        raise InvalidStamp("Malformed clock stamp.")
    return int(head), int(tail)


def order_key(hlc: str, node_id: str | None) -> tuple[str, str]:
    """Total order used for last-writer-wins: clock first, node id second."""
    return hlc, node_id or ""


class HybridClock:
    """Monotonic stamp generator that absorbs remote stamps.

    ``now_ms`` is injectable so tests can control time and skew.
    """

    def __init__(
        self,
        now_ms: Callable[[], int] | None = None,
        *,
        last: str | None = None,
        max_drift_ms: int = MAX_DRIFT_MS,
    ) -> None:
        self._now = now_ms or (lambda: time.time_ns() // 1_000_000)
        self._max_drift = max_drift_ms
        self._lock = threading.Lock()
        self._ms, self._counter = 0, 0
        if last:
            try:
                self._ms, self._counter = parse_stamp(last)
            except InvalidStamp:
                pass

    @property
    def last(self) -> str:
        return format_stamp(self._ms, self._counter)

    def tick(self) -> str:
        """Stamp for a local event; strictly greater than every earlier stamp."""
        with self._lock:
            wall = self._now()
            if wall > self._ms:
                self._ms, self._counter = wall, 0
            else:
                self._counter += 1
                self._normalise()
            return format_stamp(self._ms, self._counter)

    def check(self, remote: str) -> tuple[int, int]:
        """Validate a remote stamp without absorbing it."""
        remote_ms, remote_counter = parse_stamp(remote)
        if remote_ms > self._now() + self._max_drift:
            raise ClockSkewError("The operation's clock is too far ahead of local time.")
        return remote_ms, remote_counter

    def observe(self, remote: str) -> str:
        """Absorb a remote stamp (rejecting skewed ones) and return a newer local one."""
        remote_ms, remote_counter = self.check(remote)
        with self._lock:
            wall = self._now()
            top = max(wall, self._ms, remote_ms)
            if top == self._ms and top == remote_ms:
                self._counter = max(self._counter, remote_counter) + 1
            elif top == self._ms:
                self._counter += 1
            elif top == remote_ms:
                self._counter = remote_counter + 1
            else:
                self._counter = 0
            self._ms = top
            self._normalise()
            return format_stamp(self._ms, self._counter)

    def _normalise(self) -> None:
        if self._counter > _MAX_COUNTER:  # carry into the physical part
            self._ms += 1
            self._counter = 0
        if self._ms > _MAX_MS:
            raise InvalidStamp("Clock overflow.")
