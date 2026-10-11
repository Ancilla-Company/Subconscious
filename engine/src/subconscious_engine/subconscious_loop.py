"""Telemetry-triggered and roughly daily subconscious scheduler."""

from __future__ import annotations

import asyncio
import random

from .graph_engine import GraphEngine


class SubconsciousWorker:
    def __init__(
        self,
        engine: GraphEngine,
        interval_seconds: float = 86_400,
        jitter_ratio: float = 0.1,
    ) -> None:
        if interval_seconds <= 0:
            raise ValueError("interval_seconds must be positive")
        if not 0 <= jitter_ratio <= 0.5:
            raise ValueError("jitter_ratio must be between 0 and 0.5")
        self.engine = engine
        self.interval_seconds = interval_seconds
        self.jitter_ratio = jitter_ratio

    async def run(self) -> None:
        """Wake on friction or near the daily interval; SQL filtering remains authoritative."""
        while True:
            spread = self.interval_seconds * self.jitter_ratio
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
