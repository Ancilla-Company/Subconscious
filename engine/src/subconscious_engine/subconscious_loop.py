"""Telemetry-triggered and roughly daily subconscious scheduler."""

from __future__ import annotations

import asyncio
import random

from .graph_engine import GraphEngine


class SubconsciousWorker:
    # Each wait varies by +/-10% so many engines don't all reflect at once.
    JITTER_RATIO = 0.1

    def __init__(
        self,
        engine: GraphEngine,
        interval_seconds: float = 86_400,
    ) -> None:
        if interval_seconds <= 0:
            raise ValueError("interval_seconds must be positive")
        self.engine = engine
        self.interval_seconds = interval_seconds

    async def run(self) -> None:
        """Wake on friction or near the daily interval; SQL filtering remains authoritative."""
        while True:
            spread = self.interval_seconds * self.JITTER_RATIO
            timeout = self.interval_seconds + random.uniform(-spread, spread)
            try:
                await asyncio.wait_for(self.engine.reflection_requested.wait(), timeout)
            except TimeoutError:
                pass
            try:
                await self.engine.run_subconscious()
            except asyncio.CancelledError:
                raise
            except Exception:
                # Claims are released by GraphEngine, allowing a later retry.
                await asyncio.sleep(min(60, self.interval_seconds))
