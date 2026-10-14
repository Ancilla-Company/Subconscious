"""SwitchableLink: one stable link object over a replaceable transport.

Everything above the peer layer (``HiveNode.on_link``, sessions, the REST tunnel,
sync, tasks) keeps one reference per remote node. Underneath, the transport may be a
WebRTC link or a socket relay session (``ws-relay``) and can change while the node
stays connected: a background upgrade swaps relay -> direct without dropping in-flight
RPC, because the previous transport stays attached (and keeps delivering inbound
frames) for ``grace`` seconds before it is closed.

Mirrors ``apps/core_business_logic/lib/hive/switchable_link.dart``.
"""

from __future__ import annotations

import asyncio
import time
from collections.abc import Callable
from contextlib import suppress
from typing import Any

from .channels import ChannelError, Envelope

DIRECT_TIER = "direct"
RELAY_TIER = "ws-relay"
DEFAULT_GRACE_SECONDS = 5.0


class SwitchableLink:
    def __init__(
        self,
        initial: Any,
        *,
        on_closed: Callable[["SwitchableLink"], None] | None = None,
        grace: float = DEFAULT_GRACE_SECONDS,
    ) -> None:
        self.node_id: str = initial.node_id
        self.role: str = initial.role
        self.local_id: str = initial.local_id
        self.handler: Callable[[Any, str, Envelope], None] | None = None
        self.closed = asyncio.Event()
        self.created = time.time()
        self._on_closed = on_closed
        self._grace = grace
        self._current = initial
        self._attached: list[Any] = []
        self._timers: set[asyncio.TimerHandle] = set()
        self._tasks: set[asyncio.Task[Any]] = set()
        self._attach(initial)

    # --- introspection ----------------------------------------------------------
    @property
    def tier(self) -> str:
        return str(self._current.tier)

    @property
    def current(self) -> Any:
        return self._current

    @property
    def underlying(self) -> list[Any]:
        return list(self._attached)

    # --- transports -----------------------------------------------------------------
    def _attach(self, inner: Any) -> None:
        if inner in self._attached:
            return
        self._attached.append(inner)
        inner.handler = self._deliver
        inner.on_closed = self.inner_closed

    def _deliver(self, _inner: Any, channel: str, envelope: Envelope) -> None:
        handler = self.handler
        if handler is not None and not self.closed.is_set():
            handler(self, channel, envelope)

    def add(self, inner: Any) -> None:
        """Adopt a new transport. Direct always wins; a second relay session replaces the
        old one (rekey); a relay session next to a live direct link stays as a standby."""
        if inner.tier != RELAY_TIER or self._current.tier == RELAY_TIER:
            self.swap(inner)
        else:
            self._attach(inner)

    def swap(self, nxt: Any) -> None:
        """Make ``nxt`` the sending transport; retire the previous one after ``grace``."""
        if self.closed.is_set() or nxt is self._current:
            return
        previous = self._current
        self._attach(nxt)
        self._current = nxt
        loop = asyncio.get_running_loop()
        holder: list[asyncio.TimerHandle] = []

        def retire() -> None:
            if holder:
                self._timers.discard(holder[0])
            task = asyncio.ensure_future(self._close_inner(previous))
            self._tasks.add(task)
            task.add_done_callback(self._tasks.discard)

        timer = loop.call_later(self._grace, retire)
        holder.append(timer)
        self._timers.add(timer)

    @staticmethod
    async def _close_inner(inner: Any) -> None:
        with suppress(Exception):
            await inner.close()

    def inner_closed(self, inner: Any) -> None:
        """A transport ended: fail over to another open one, or end the link."""
        if inner in self._attached:
            self._attached.remove(inner)
        if self.closed.is_set() or inner is not self._current:
            return
        alternative = next((i for i in reversed(self._attached) if not i.closed.is_set()), None)
        if alternative is not None:
            self._current = alternative
        else:
            self._finish()

    # --- link surface -------------------------------------------------------------
    async def send(self, channel: str, envelope: Envelope) -> None:
        if self.closed.is_set():
            raise ChannelError("The peer link is closed.")
        current = self._current
        try:
            await current.send(channel, envelope)
        except ChannelError:
            # The transport died under us: use a standby once, if there is one.
            alternative = next(
                (i for i in reversed(self._attached) if i is not current and not i.closed.is_set()),
                None,
            )
            if alternative is None or self.closed.is_set():
                raise
            await alternative.send(channel, envelope)

    async def send_frame(
        self, channel: str, frame_type: str, data: Any, identifier: str | None = None
    ) -> None:
        await self.send(channel, Envelope(frame_type, data, identifier))

    async def close(self) -> None:
        if self.closed.is_set():
            return
        for inner in list(self._attached):
            await self._close_inner(inner)
        self._finish()

    def _finish(self) -> None:
        if self.closed.is_set():
            return
        self.closed.set()
        for timer in list(self._timers):
            timer.cancel()
        self._timers.clear()
        callback, self._on_closed = self._on_closed, None
        if callback is not None:
            callback(self)
