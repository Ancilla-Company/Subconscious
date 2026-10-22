"""PeerManager: one aiortc ``RTCPeerConnection`` per remote node.

Signalling payloads are signed (``sc-sdp-v1``), offers are accepted only from
trusted directory nodes inside a 60 s freshness window and only once (replay
cache), the ``control`` channel runs the channel-binding handshake, and glare is
resolved with the polite-peer rule (lexicographically lower node id is polite).

``sid`` format: ``<unix seconds>.<random>``. The timestamp therefore rides inside
the signed ``sid`` field, which is what makes the freshness window enforceable.

Transport hook: everything above this module talks to :class:`PeerLink` and the
:class:`SignalSender` protocol, so a socket-relay transport (Phase 6) can provide
the same ``PeerLink`` without touching sessions, tunnel or authz.
"""

from __future__ import annotations

import asyncio
import logging
import secrets
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any, Protocol

from .authz import role_for_kind
from .channels import (
    CHANNEL_IDS,
    CHANNEL_NAMES,
    ChannelEndpoint,
    ChannelError,
    Envelope,
)
from .directory import Directory, DirectoryNode
from .handshake import HandshakeError, PeerHandshake, extract_fingerprint
from .identity import (
    NodeIdentity,
    b64u_encode,
    node_ids_equal,
    sdp_message,
    verify_signature,
)
from .relay import RateLimiter, RelayManager, RelaySender, RelaySession
from .switchable import DIRECT_TIER, RELAY_TIER, SwitchableLink
from ..connection_log import connection_event, connection_problem
from ..logging_setup import logged_suppress, spawn_logged
_LOG = logging.getLogger(__name__)

_LOGGER = logging.getLogger("uvicorn.error")
FRESHNESS_WINDOW_SECONDS = 60.0
REPLAY_CACHE_LIMIT = 2048
MAX_SDP_CHARS = 48 * 1024
MAX_REMOTE_CANDIDATES = 32
DEFAULT_DIRECT_TIMEOUT = 8.0  # webrtc.md 6.3: direct attempt timeout before the socket relay
TIER_DIRECT = DIRECT_TIER
# Background relay -> direct upgrade (mirrors the Dart client): first try after 60 s,
# doubling on failure up to 5 min, never more often than the first interval.
DEFAULT_UPGRADE_INTERVAL = 60.0
DEFAULT_UPGRADE_MAX_INTERVAL = 300.0
# After a failed direct attempt, reconnects go straight to the relay for this long.
RELAY_FIRST_SECONDS = 300.0


class SignalSender(Protocol):
    async def send_signal(
        self, sid: str, to: str, kind: str, body: dict[str, Any], sig: str | None
    ) -> None: ...


IceProvider = Callable[[], Awaitable[dict[str, Any]]]
EnvelopeHandler = Callable[["PeerLink", str, Envelope], None]


class PeerTransport(Protocol):
    """What the layers above need from any transport (WebRTC now, relay later)."""

    node_id: str
    tier: str

    async def send(self, channel: str, envelope: Envelope) -> None: ...
    async def close(self) -> None: ...


def new_sid(now: float) -> str:
    return f"{int(now)}.{b64u_encode(secrets.token_bytes(9))}"


def sid_timestamp(sid: Any) -> float | None:
    if not isinstance(sid, str) or len(sid) > 64 or "." not in sid:
        return None
    head = sid.split(".", 1)[0]
    return float(head) if head.isdigit() and len(head) <= 12 else None


class ReplayCache:
    def __init__(self, clock: Callable[[], float], ttl: float = 2 * FRESHNESS_WINDOW_SECONDS) -> None:
        self._clock = clock
        self._ttl = ttl
        self._seen: dict[tuple[str, str, str], float] = {}

    def check_and_add(self, sender: str, sid: str, kind: str) -> bool:
        """``True`` when new; ``False`` when this exact message was seen already."""
        now = self._clock()
        if len(self._seen) >= REPLAY_CACHE_LIMIT or self._seen:
            for key in [k for k, exp in self._seen.items() if exp <= now]:
                del self._seen[key]
        key = (sender, sid, kind)
        if key in self._seen:
            return False
        if len(self._seen) >= REPLAY_CACHE_LIMIT:
            oldest = min(self._seen, key=self._seen.__getitem__)
            del self._seen[oldest]
        self._seen[key] = now + self._ttl
        return True


@dataclass
class PeerLink:
    """An authenticated, open link to one remote node."""

    node_id: str
    role: str
    tier: str
    endpoints: dict[str, ChannelEndpoint]
    close_callback: Callable[[], Awaitable[None]]
    local_id: str
    handler: EnvelopeHandler | None = None
    closed: asyncio.Event = field(default_factory=asyncio.Event)
    created: float = field(default_factory=time.time)
    sid: str = ""
    on_closed: Callable[[Any], None] | None = None  # set by the owning SwitchableLink

    async def send(self, channel: str, envelope: Envelope) -> None:
        endpoint = self.endpoints.get(channel)
        if endpoint is None or self.closed.is_set():
            raise ChannelError("The peer link is closed.")
        await endpoint.send(
            Envelope(envelope.type, envelope.data, envelope.id, self.local_id, self.node_id)
        )

    async def send_frame(
        self, channel: str, frame_type: str, data: Any, identifier: str | None = None
    ) -> None:
        await self.send(channel, Envelope(frame_type, data, identifier))

    async def close(self) -> None:
        await self.close_callback()


@dataclass
class _Attempt:
    sid: str
    remote: DirectoryNode
    offerer: bool
    pc: Any
    endpoints: dict[str, ChannelEndpoint] = field(default_factory=dict)
    handshake: PeerHandshake | None = None
    ready: "asyncio.Future[PeerLink]" = field(default_factory=lambda: asyncio.get_running_loop().create_future())
    answered: bool = False
    candidates: int = 0
    hello_sent: bool = False
    proof_ok: bool = False
    sent_proof: bool = False
    link: PeerLink | None = None
    timeout: asyncio.Task[None] | None = None
    closed: bool = False


class PeerManager:
    def __init__(
        self,
        identity: NodeIdentity,
        directory: Directory,
        signaler: SignalSender,
        ice_provider: IceProvider,
        *,
        on_link: Callable[[PeerLink], None] | None = None,
        on_link_closed: Callable[[str], None] | None = None,
        stun_override: list[str] | None = None,
        clock: Callable[[], float] = time.time,
        direct_timeout: float = DEFAULT_DIRECT_TIMEOUT,
        relay_sender: RelaySender | None = None,
        relay_enabled: bool = True,
        force_relay: bool = False,
        relay_limiter: RateLimiter | None = None,
        relay_handshake_timeout: float | None = None,
        upgrade_interval: float = DEFAULT_UPGRADE_INTERVAL,
        upgrade_max_interval: float = DEFAULT_UPGRADE_MAX_INTERVAL,
        swap_grace: float = 5.0,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    ) -> None:
        """``relay_sender`` (the signalling client) enables the socket relay fallback.

        ``force_relay`` skips the direct attempt, refuses inbound offers and never upgrades:
        a test/diagnostic switch (``hive.force_relay``), not a production setting.
        """
        self._identity = identity
        self._directory = directory
        self._signaler = signaler
        self._ice_provider = ice_provider
        self._on_link = on_link
        self._on_link_closed = on_link_closed
        self._stun_override = stun_override or []
        self._clock = clock
        self._connect_timeout = direct_timeout
        self._force_relay = force_relay
        self._upgrade_interval = upgrade_interval
        self._upgrade_max_interval = upgrade_max_interval
        self._swap_grace = swap_grace
        self._sleep = sleep
        self._replay = ReplayCache(clock)
        self._attempts: dict[str, _Attempt] = {}
        self._links: dict[str, SwitchableLink] = {}
        self._ladders: dict[str, asyncio.Future[SwitchableLink]] = {}
        self._upgrades: dict[str, asyncio.Task[None]] = {}
        self._direct_failed: dict[str, float] = {}
        self._locks: dict[str, asyncio.Lock] = {}
        self._tasks: set[asyncio.Task[Any]] = set()
        self._failed: dict[str, str] = {}
        self._closed_quietly = False
        self._closed = False
        self._relay: RelayManager | None = None
        if relay_sender is not None and relay_enabled:
            options: dict[str, Any] = {}
            if relay_handshake_timeout is not None:
                options["handshake_timeout"] = relay_handshake_timeout
            self._relay = RelayManager(
                identity, directory, relay_sender,
                on_session=self._on_relay_session, limiter=relay_limiter, clock=clock, **options,
            )

    # --- public -------------------------------------------------------------
    @property
    def links(self) -> dict[str, SwitchableLink]:
        return {k: v for k, v in self._links.items() if not v.closed.is_set()}

    def link(self, node_id: str) -> SwitchableLink | None:
        link = self._links.get(node_id)
        return link if link is not None and not link.closed.is_set() else None

    @property
    def relay_enabled(self) -> bool:
        return self._relay is not None

    async def handle_relay(self, data: dict[str, Any]) -> None:
        """Entry point for server ``relay`` frames (never raises)."""
        if self._relay is not None and not self._closed:
            await self._relay.handle_relay(data)

    def is_polite(self, remote_id: str) -> bool:
        return self._identity.node_id < remote_id

    def state_of(self, node_id: str) -> str:
        if self.link(node_id) is not None:
            return "connected"
        if node_id in self._attempts or node_id in self._ladders:
            return "connecting"
        return self._failed.get(node_id, "disconnected")

    async def connect(self, node_id: str) -> SwitchableLink:
        """Open (or reuse) a link to ``node_id``.

        Ladder (webrtc.md 6.3/6.4): direct first (``direct_timeout``), then the encrypted
        relay over the signalling socket when the server allows it. A relay link keeps
        trying to upgrade to direct in the background and swaps underneath callers.
        """
        if self._closed:
            raise ConnectionError("The peer manager is closed.")
        existing = self.link(node_id)
        if existing is not None:
            return existing
        pending = self._ladders.get(node_id)
        if pending is None:
            remote = self._directory.trusted_node(node_id)
            if remote is None or role_for_kind(remote.kind) is None:
                raise ConnectionError("That node is not a trusted member of this hive.")
            pending = spawn_logged(self._ladder(node_id))
            pending.add_done_callback(_mark_retrieved)
            self._ladders[node_id] = pending
            pending.add_done_callback(lambda f, n=node_id: self._ladders.pop(n, None) if self._ladders.get(n) is f else None)
        return await asyncio.shield(pending)

    async def _ladder(self, node_id: str) -> SwitchableLink:
        relay_first = self._relay is not None and (
            self._force_relay or self._recent_direct_failure(node_id)
        )
        if relay_first and await self._relay_allowed():
            try:
                return await self._connect_via_relay(node_id)
            except ConnectionError:
                if self._force_relay or self._closed:
                    raise
        if self._force_relay:
            raise ConnectionError("The socket relay is not available.")
        try:
            await self._connect_direct(node_id)
        except ConnectionError:
            if self._closed:
                raise
            self._direct_failed[node_id] = self._clock()
            if self._relay is None:
                raise
            existing = self.link(node_id)  # an inbound attempt may have won meanwhile
            if existing is not None:
                return existing
            return await self._connect_via_relay(node_id)
        self._direct_failed.pop(node_id, None)
        link = self.link(node_id)
        if link is None:
            raise ConnectionError("The peer link closed immediately.")
        return link

    def _recent_direct_failure(self, node_id: str) -> bool:
        failed = self._direct_failed.get(node_id)
        return failed is not None and 0 <= self._clock() - failed < RELAY_FIRST_SECONDS

    async def _relay_allowed(self) -> bool:
        """The relay is used only when the server reports ``ws_relay_enabled`` in ice-config."""
        if self._relay is None:
            return False
        try:
            config = await self._ice_provider()
        except Exception:
            _LOG.exception("hive.peers.PeerManager._relay_allowed: handled Exception; continuing with fallback")
            return False
        return isinstance(config, dict) and config.get("ws_relay_enabled") is True

    async def _connect_via_relay(self, node_id: str) -> SwitchableLink:
        relay = self._relay
        if relay is None or not await self._relay_allowed():
            raise ConnectionError("Peer connection failed and the socket relay is unavailable.")
        existing = self.link(node_id)
        if existing is not None:
            return existing
        await relay.connect(node_id)  # adoption happens in _on_relay_session
        link = self.link(node_id)
        if link is None:
            raise ConnectionError("The relay link closed immediately.")
        return link

    async def _connect_direct(self, node_id: str, *, upgrade: bool = False) -> PeerLink:
        """One direct WebRTC attempt; we are the offerer. ``upgrade`` ignores existing links."""
        if not upgrade and self.link(node_id) is not None:
            return self._links[node_id].current
        pending = self._attempts.get(node_id)
        if pending is not None:
            return await asyncio.shield(pending.ready)
        remote = self._directory.trusted_node(node_id)
        if remote is None or role_for_kind(remote.kind) is None:
            raise ConnectionError("That node is not a trusted member of this hive.")
        async with self._lock(node_id):
            if not upgrade and self.link(node_id) is not None:
                return self._links[node_id].current
            attempt = await self._begin_offer(remote)
        return await asyncio.shield(attempt.ready)

    # --- relay adoption and upgrade ---------------------------------------------------
    def _on_relay_session(self, session: RelaySession) -> None:
        if self._closed or self._directory.trusted_node(session.node_id) is None:
            self._spawn(session.close())
            return
        self._failed.pop(session.node_id, None)
        self._adopt(session)

    def _adopt(self, inner: Any) -> SwitchableLink:
        """Register ``inner`` as (part of) the link to its node; fires ``on_link`` once."""
        node_id = inner.node_id
        existing = self._links.get(node_id)
        if existing is not None and not existing.closed.is_set():
            existing.add(inner)
            connection_event(
                "peer.link.path_added",
                node_id=node_id,
                tier=getattr(inner, "tier", None),
            )
            return existing
        link = SwitchableLink(inner, on_closed=self._link_closed, grace=self._swap_grace)
        self._links[node_id] = link
        connection_event(
            "peer.link.up",
            node_id=node_id,
            tier=getattr(inner, "tier", None),
            role=getattr(inner, "role", None),
        )
        if self._on_link is not None:
            self._on_link(link)  # type: ignore[arg-type]
        if inner.tier == RELAY_TIER:
            self._start_upgrade(node_id, link)
        return link

    def _link_closed(self, link: SwitchableLink) -> None:
        node_id = link.node_id
        if self._links.get(node_id) is link:
            if self._closed:
                connection_event("peer.link.down", node_id=node_id, reason="engine shutting down")
            else:
                connection_problem(
                    "peer.link.down",
                    node_id=node_id,
                    reason="link closed (remote left, network lost or all paths failed)",
                )
            del self._links[node_id]
            upgrade = self._upgrades.pop(node_id, None)
            if upgrade is not None and upgrade is not asyncio.current_task():
                upgrade.cancel()
            if self._on_link_closed is not None and not self._closed:
                self._on_link_closed(node_id)

    def _start_upgrade(self, node_id: str, link: SwitchableLink) -> None:
        """Only the impolite (higher id) engine dials, as for presence-driven connects."""
        remote = self._directory.get(node_id)
        if (
            self._force_relay
            or self._closed
            or node_id in self._upgrades
            or remote is None
            or role_for_kind(remote.kind) != "hive_peer"
            or self.is_polite(node_id)
        ):
            return
        task = spawn_logged(self._upgrade_loop(node_id, link))
        self._upgrades[node_id] = task
        task.add_done_callback(
            lambda t, n=node_id: self._upgrades.pop(n, None) if self._upgrades.get(n) is t else None
        )

    async def _upgrade_loop(self, node_id: str, link: SwitchableLink) -> None:
        wait = self._upgrade_interval
        while not self._closed and not link.closed.is_set() and link.tier == RELAY_TIER:
            await self._sleep(wait)
            if self._closed or link.closed.is_set() or link.tier != RELAY_TIER:
                return
            try:
                await self._connect_direct(node_id, upgrade=True)  # _complete swaps the link
                return
            except asyncio.CancelledError:
                raise
            except Exception:
                _LOG.exception("hive.peers.PeerManager._upgrade_loop: handled Exception; continuing with fallback")
                wait = min(wait * 2, self._upgrade_max_interval)

    async def handle_signal(self, data: dict[str, Any]) -> None:
        """Entry point for server ``signal`` frames (never raises)."""
        try:
            await self._handle_signal(data)
        except asyncio.CancelledError:
            raise
        except Exception:
            _LOGGER.debug("Ignored an invalid signal frame.", exc_info=True)

    async def on_presence(self, node_id: str, online: bool) -> None:
        """Impolite (higher id) engines dial; the lower id waits. Thin nodes dial."""
        if self._closed or node_id == self._identity.node_id:
            return
        if not online:
            # Nothing can be delivered through the relay to a node with no signalling socket.
            if self._relay is not None:
                await self._relay.close_peer(node_id)
            return
        remote = self._directory.trusted_node(node_id)
        if remote is None or role_for_kind(remote.kind) != "hive_peer":
            return
        if (
            node_id in self._links
            or node_id in self._attempts
            or node_id in self._ladders
            or self.is_polite(node_id)
        ):
            return
        self._spawn(self._safe_connect(node_id))

    async def close_peer(self, node_id: str) -> None:
        attempt = self._attempts.get(node_id)
        if attempt is not None:
            await self._teardown(attempt, "closed")
        link = self._links.get(node_id)
        if link is not None:
            await link.close()
        if self._relay is not None:
            await self._relay.close_peer(node_id)

    async def close(self) -> None:
        self._closed = True
        self._closed_quietly = True  # shutting down: do not signal
        for attempt in list(self._attempts.values()):
            await self._teardown(attempt, "closed")
        for link in list(self._links.values()):
            await link.close()
        if self._relay is not None:
            await self._relay.close()
        for task in [*self._upgrades.values(), *self._ladders.values()]:
            task.cancel()
        for task in list(self._tasks):
            task.cancel()
        for task in list(self._tasks):
            with logged_suppress(asyncio.CancelledError, Exception):
                await task

    # --- internals ------------------------------------------------------------
    def _lock(self, node_id: str) -> asyncio.Lock:
        return self._locks.setdefault(node_id, asyncio.Lock())

    def _spawn(self, coro: Awaitable[Any]) -> None:
        task = spawn_logged(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _safe_connect(self, node_id: str) -> None:
        with logged_suppress(Exception):
            await self.connect(node_id)

    async def _rtc_configuration(self) -> Any:
        from aiortc import RTCConfiguration, RTCIceServer

        servers: list[Any] = []
        if self._stun_override:
            servers.extend(RTCIceServer(urls=url) for url in self._stun_override)
        try:
            config = await self._ice_provider()
        except Exception:
            _LOGGER.info("ICE configuration unavailable; using host candidates only.")
            config = {}
        for entry in config.get("ice_servers", []) if isinstance(config, dict) else []:
            if not isinstance(entry, dict):
                continue
            urls = entry.get("urls")
            urls = [urls] if isinstance(urls, str) else urls
            if not isinstance(urls, list):
                continue
            safe = [
                u for u in urls
                if isinstance(u, str) and u.split(":", 1)[0] in {"stun", "turn", "turns"}
            ]
            if not safe or (self._stun_override and all(u.startswith("stun") for u in safe)):
                continue
            username, credential = entry.get("username"), entry.get("credential")
            servers.append(
                RTCIceServer(
                    urls=safe,
                    username=username if isinstance(username, str) else None,
                    credential=credential if isinstance(credential, str) else None,
                )
            )
        return RTCConfiguration(iceServers=servers)

    async def _new_attempt(self, remote: DirectoryNode, sid: str, offerer: bool) -> _Attempt:
        from aiortc import RTCPeerConnection

        pc = RTCPeerConnection(await self._rtc_configuration())
        attempt = _Attempt(sid=sid, remote=remote, offerer=offerer, pc=pc)
        for name in CHANNEL_NAMES:
            channel = pc.createDataChannel(
                name, ordered=True, negotiated=True, id=CHANNEL_IDS[name]
            )
            endpoint = ChannelEndpoint(
                name,
                channel,
                lambda ch, env, a=attempt: self._on_envelope(a, ch, env),
                lambda ch, err, a=attempt: _LOGGER.debug("Dropped a bad %s message (%s).", ch, err),
            )
            attempt.endpoints[name] = endpoint
            if name == "control":
                channel.on("open", lambda a=attempt: self._on_control_open(a))
                channel.on(
                    "close",
                    lambda a=attempt: self._spawn(self._teardown(a, "closed", notify=False)),
                )

        @pc.on("connectionstatechange")
        def _state() -> None:
            fields = {"node_id": remote.id, "sid": attempt.sid, "state": pc.connectionState}
            if pc.connectionState == "failed":
                connection_problem("peer.connection.state", **fields)
            else:
                connection_event("peer.connection.state", **fields)
            if pc.connectionState in {"failed", "closed"}:
                self._spawn(self._teardown(attempt, pc.connectionState, notify=False))

        attempt.timeout = spawn_logged(self._expire(attempt))
        self._attempts[remote.id] = attempt
        return attempt

    async def _expire(self, attempt: _Attempt) -> None:
        await asyncio.sleep(self._connect_timeout)
        if attempt.link is None and not attempt.closed:
            await self._teardown(attempt, "timeout")

    async def _begin_offer(self, remote: DirectoryNode) -> _Attempt:
        sid = new_sid(self._clock())
        attempt = await self._new_attempt(remote, sid, offerer=True)
        try:
            await attempt.pc.setLocalDescription(await attempt.pc.createOffer())
            sdp = attempt.pc.localDescription.sdp
            sig = self._identity.sign(sdp_message(sid, self._identity.node_id, remote.id, sdp))
            await self._signaler.send_signal(sid, remote.id, "offer", {"type": "offer", "sdp": sdp}, sig)
        except Exception:
            await self._teardown(attempt, "failed")
            raise
        return attempt

    def _verify_signal(
        self, data: dict[str, Any], expected_kind: str
    ) -> tuple[DirectoryNode, str, str] | None:
        sender, sid, body, sig = data.get("from"), data.get("sid"), data.get("body"), data.get("sig")
        if (
            not isinstance(sender, str)
            or not isinstance(body, dict)
            or not isinstance(sig, str)
            or not isinstance(body.get("sdp"), str)
            or len(body["sdp"]) > MAX_SDP_CHARS
        ):
            return None
        stamp = sid_timestamp(sid)
        if (
            not isinstance(sid, str)
            or stamp is None
            or abs(self._clock() - stamp) > FRESHNESS_WINDOW_SECONDS
        ):
            return None
        remote = self._directory.trusted_node(sender)
        if remote is None or role_for_kind(remote.kind) is None:
            return None
        sdp = body["sdp"]
        if not verify_signature(
            remote.public_key, sig, sdp_message(sid, sender, self._identity.node_id, sdp)
        ):
            return None
        if not self._replay.check_and_add(sender, sid, expected_kind):
            return None
        return remote, sid, sdp

    async def _handle_signal(self, data: dict[str, Any]) -> None:
        kind = data.get("kind")
        sender = data.get("from")
        if not isinstance(sender, str) or node_ids_equal(sender, self._identity.node_id):
            return
        if kind == "offer":
            verified = self._verify_signal(data, "offer")
            if verified is not None:
                await self._accept_offer(*verified)
        elif kind == "answer":
            attempt = self._attempts.get(sender)
            if attempt is None or not attempt.offerer or attempt.answered or data.get("sid") != attempt.sid:
                return
            verified = self._verify_signal(data, "answer")
            if verified is not None:
                await self._accept_answer(attempt, verified[2])
        elif kind == "candidate":
            await self._accept_candidate(sender, data)
        elif kind == "bye":
            attempt = self._attempts.get(sender)
            if attempt is not None and data.get("sid") == attempt.sid:
                await self._teardown(attempt, "closed-by-peer", notify=False)
            link = self._links.get(sender)
            if link is not None:
                for inner in link.underlying:  # only the WebRTC transport of that sid
                    if inner.tier == DIRECT_TIER and inner.sid and inner.sid == data.get("sid"):
                        await inner.close()

    async def _accept_offer(self, remote: DirectoryNode, sid: str, sdp: str) -> None:
        from aiortc import RTCSessionDescription

        if self._force_relay:
            return  # diagnostic mode: never answer a direct offer
        async with self._lock(remote.id):
            existing = self._attempts.get(remote.id)
            inherited: asyncio.Future[PeerLink] | None = None
            if existing is not None and existing.offerer and not existing.answered:
                # Glare: both sides offered at once.
                if not self.is_polite(remote.id):
                    _LOGGER.debug("Glare: ignoring the remote offer (we are impolite).")
                    return
            if existing is not None:
                # Whoever awaited the superseded attempt gets the new outcome.
                inherited = existing.ready
                await self._teardown(existing, "replaced", settle=False)
            old = self._links.get(remote.id)
            if old is not None and old.tier != RELAY_TIER:
                await old.close()  # a stale direct link: the peer restarted. A relay link stays
                # up while the offer upgrades it (the new attempt swaps underneath).
            try:
                offer_fp = extract_fingerprint(sdp)
                attempt = await self._new_attempt(remote, sid, offerer=False)
                if inherited is not None:
                    attempt.ready.add_done_callback(lambda f, i=inherited: _chain(f, i))
                await attempt.pc.setRemoteDescription(RTCSessionDescription(sdp=sdp, type="offer"))
                await attempt.pc.setLocalDescription(await attempt.pc.createAnswer())
                answer = attempt.pc.localDescription.sdp
                attempt.handshake = self._handshake(
                    remote, offer_fp, extract_fingerprint(answer), offerer=False
                )
                attempt.answered = True
                sig = self._identity.sign(sdp_message(sid, self._identity.node_id, remote.id, answer))
                await self._signaler.send_signal(sid, remote.id, "answer", {"type": "answer", "sdp": answer}, sig)
            except Exception:
                current = self._attempts.get(remote.id)
                if current is not None:
                    await self._teardown(current, "failed")
                raise

    async def _accept_answer(self, attempt: _Attempt, sdp: str) -> None:
        from aiortc import RTCSessionDescription

        try:
            attempt.answered = True
            local = attempt.pc.localDescription.sdp
            attempt.handshake = self._handshake(
                attempt.remote,
                extract_fingerprint(local),
                extract_fingerprint(sdp),
                offerer=True,
            )
            await attempt.pc.setRemoteDescription(RTCSessionDescription(sdp=sdp, type="answer"))
        except Exception:
            await self._teardown(attempt, "failed")
            raise

    def _handshake(
        self, remote: DirectoryNode, offerer_fp: str, answerer_fp: str, *, offerer: bool
    ) -> PeerHandshake:
        return PeerHandshake(
            self._identity, remote.id, remote.public_key, offerer_fp, answerer_fp, offerer
        )

    async def _accept_candidate(self, sender: str, data: dict[str, Any]) -> None:
        attempt = self._attempts.get(sender)
        body = data.get("body")
        if attempt is None or data.get("sid") != attempt.sid or not isinstance(body, dict):
            return
        text = body.get("candidate")
        if not isinstance(text, str) or not text.startswith("candidate:") or len(text) > 512:
            return
        if attempt.candidates >= MAX_REMOTE_CANDIDATES:
            return
        attempt.candidates += 1
        from aiortc.sdp import candidate_from_sdp

        candidate = candidate_from_sdp(text.split(":", 1)[1])
        mid, index = body.get("sdpMid"), body.get("sdpMLineIndex")
        candidate.sdpMid = mid if isinstance(mid, str) else None
        candidate.sdpMLineIndex = index if isinstance(index, int) else None
        await attempt.pc.addIceCandidate(candidate)

    # --- channel events ---------------------------------------------------------
    def _on_control_open(self, attempt: _Attempt) -> None:
        if attempt.hello_sent or attempt.handshake is None or attempt.closed:
            return
        attempt.hello_sent = True
        self._spawn(self._send_control(attempt, "peer.hello", attempt.handshake.hello()))

    async def _send_control(self, attempt: _Attempt, frame_type: str, data: Any) -> None:
        try:
            await attempt.endpoints["control"].send(
                Envelope(frame_type, data, None, self._identity.node_id, attempt.remote.id)
            )
        except ChannelError:
            _LOG.warning("hive.peers.PeerManager._send_control: handled ChannelError; continuing with fallback", exc_info=True)
            await self._teardown(attempt, "failed")

    def _on_envelope(self, attempt: _Attempt, channel: str, envelope: Envelope) -> None:
        if attempt.closed:
            return
        if envelope.src is not None and not node_ids_equal(envelope.src, attempt.remote.id):
            return
        if envelope.dst is not None and not node_ids_equal(envelope.dst, self._identity.node_id):
            return
        link = attempt.link
        if link is None:
            # Pre-authentication: only the control handshake is processed.
            if channel == "control" and envelope.type in {"peer.hello", "peer.proof"}:
                self._handshake_step(attempt, envelope)
            return
        if channel == "control" and envelope.type in {"peer.hello", "peer.proof"}:
            return
        if link.handler is not None:
            link.handler(link, channel, envelope)

    def _handshake_step(self, attempt: _Attempt, envelope: Envelope) -> None:
        handshake = attempt.handshake
        if handshake is None:
            return
        try:
            if envelope.type == "peer.hello":
                proof = handshake.receive_hello(envelope.data)
                attempt.sent_proof = True
                self._spawn(self._send_control(attempt, "peer.proof", proof))
            else:
                handshake.receive_proof(envelope.data)
        except HandshakeError as error:
            _LOGGER.warning("Peer handshake failed: %s", error)
            self._spawn(self._teardown(attempt, "handshake"))
            return
        if handshake.authenticated and attempt.sent_proof:
            self._complete(attempt)

    def _complete(self, attempt: _Attempt) -> None:
        if attempt.link is not None:
            return
        remote = attempt.remote
        role = role_for_kind(remote.kind)
        if role is None or not self._directory.is_trusted(remote.id):
            self._spawn(self._teardown(attempt, "untrusted"))
            return
        link = PeerLink(
            node_id=remote.id,
            role=role,
            tier=TIER_DIRECT,
            endpoints=attempt.endpoints,
            close_callback=lambda a=attempt: self._teardown(a, "closed"),
            local_id=self._identity.node_id,
            sid=attempt.sid,
        )
        attempt.link = link
        self._attempts.pop(remote.id, None)
        self._failed.pop(remote.id, None)
        if attempt.timeout is not None:
            attempt.timeout.cancel()
        self._adopt(link)  # a new link, or a swap underneath an existing relay link
        if not attempt.ready.done():
            attempt.ready.set_result(link)

    async def _teardown(
        self, attempt: _Attempt, reason: str, *, settle: bool = True, notify: bool = True
    ) -> None:
        if attempt.closed:
            return
        attempt.closed = True
        remote_id = attempt.remote.id
        teardown_fields = {
            "node_id": remote_id,
            "name": attempt.remote.name,
            "sid": attempt.sid,
            "reason": reason,
            "had_link": attempt.link is not None,
            "offerer": attempt.offerer,
        }
        if reason == "closed":
            connection_event("peer.attempt.closed", **teardown_fields)
        else:
            # failed / timeout / error: the remote could not be reached or dropped.
            connection_problem("peer.attempt.failed", **teardown_fields)
        if self._attempts.get(remote_id) is attempt:
            del self._attempts[remote_id]
        link = attempt.link
        if link is not None:
            link.closed.set()
            if link.on_closed is not None:  # the owning SwitchableLink fails over or ends
                link.on_closed(link)
        elif settle and reason not in {"closed"}:
            self._failed[remote_id] = "failed"
        if attempt.timeout is not None and attempt.timeout is not asyncio.current_task():
            attempt.timeout.cancel()
        if notify and not self._closed_quietly:
            with logged_suppress(Exception):
                await self._signaler.send_signal(attempt.sid, remote_id, "bye", {}, None)
        with logged_suppress(Exception):
            await attempt.pc.close()
        if settle and not attempt.ready.done():
            attempt.ready.set_exception(ConnectionError(f"Peer connection {reason}."))
            attempt.ready.exception()  # mark retrieved


def _mark_retrieved(future: "asyncio.Future[Any]") -> None:
    if not future.cancelled():
        future.exception()


def _chain(done: "asyncio.Future[PeerLink]", target: "asyncio.Future[PeerLink]") -> None:
    """Resolve a superseded connect() future with the winning attempt's outcome."""
    if target.done():
        return
    if done.cancelled():
        target.cancel()
    elif done.exception() is not None:
        target.set_exception(done.exception())  # type: ignore[arg-type]
    else:
        target.set_result(done.result())
