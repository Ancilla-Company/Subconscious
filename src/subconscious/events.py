""" A tiny in-process async publish/subscribe event bus.

    The engine publishes domain events (new message, new/updated thread, etc.) here.
    Any in-process consumer — the local API's WebSocket fan-out, the Flet UI, or a
    future sync module — can subscribe to receive them. Living in its own module
    keeps it free of engine/api imports so either side can depend on it without a
    circular import.
"""
from __future__ import annotations

import asyncio
import logging
from typing import Any


# Loggin setup
logger = logging.getLogger("subconscious")


class EventBus:
  """ Fan-out async event bus backed by per-subscriber queues """
  def __init__(self, max_queue: int = 1000) -> None:
    self._max_queue = max_queue
    self._subscribers: set[asyncio.Queue] = set()

  def subscribe(self) -> asyncio.Queue:
    """ Register a new subscriber and return its queue """
    q: asyncio.Queue = asyncio.Queue(maxsize=self._max_queue)
    self._subscribers.add(q)
    return q

  def unsubscribe(self, q: asyncio.Queue) -> None:
    """ Remove a subscriber's queue """
    self._subscribers.discard(q)

  async def publish(self, event: dict[str, Any]) -> None:
    """ Deliver *event* to every current subscriber. Never blocks the publisher:
        if a subscriber's queue is full the event is dropped for that subscriber
        (a slow/closed client must not stall engine writes).
    """
    for q in list(self._subscribers):
      try:
        q.put_nowait(event)
      except asyncio.QueueFull:
        logger.warning("EventBus subscriber queue full; dropping event %s", event.get("type"))

  @property
  def subscriber_count(self) -> int:
    return len(self._subscribers)
