import 'dart:async';
import 'dart:math';

import 'channel_codec.dart';
import 'directory.dart';
import 'encoding.dart';
import 'handshake.dart';
import 'identity.dart';
import 'peer_link.dart';
import 'relay.dart';
import 'switchable_link.dart';

const Duration signalFreshnessWindow = Duration(seconds: 60);
const int maxSdpChars = 48 * 1024;
const int _replayCacheLimit = 2048;

abstract interface class SignalSender {
  Future<void> sendSignal({
    required String sid,
    required String to,
    required String kind,
    required Map<String, dynamic> body,
    String? sig,
  });
}

final class PeerConnectException implements Exception {
  const PeerConnectException(this.message);
  final String message;
  @override
  String toString() => 'PeerConnectException: $message';
}

/// `<unix seconds>.<random>`; the timestamp rides inside the signed sid so the
/// receiver can enforce a freshness window.
String newSid(DateTime now, Random random) =>
    '${now.millisecondsSinceEpoch ~/ 1000}.'
    '${b64uEncode(List<int>.generate(9, (int _) => random.nextInt(256)))}';

DateTime? sidTimestamp(Object? sid) {
  if (sid is! String || sid.length > 64 || !sid.contains('.')) return null;
  final String head = sid.split('.').first;
  final int? seconds = int.tryParse(head);
  if (seconds == null || head.length > 12 || head.startsWith('-')) return null;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

final class _Attempt {
  _Attempt(this.sid, this.remote, this.transport, {this.upgrade = false}) {
    ready.future.ignore();
  }

  /// Background direct attempt replacing a relay link: never registered in
  /// the link table by itself.
  final bool upgrade;
  String? offerSdp;
  final String sid;
  final DirectoryNode remote;
  final PeerTransport transport;
  final Completer<PeerLink> ready = Completer<PeerLink>();
  PeerHandshake? handshake;
  AuthenticatedPeerLink? link;
  bool answered = false;
  bool helloSent = false;
  bool closed = false;
  int candidates = 0;
  StreamSubscription<Map<String, dynamic>>? candidateSubscription;
  Timer? timer;
  final Map<String, Reassembler> reassemblers = <String, Reassembler>{};
}

/// Thin-node side of peer connection setup.
///
/// Dials trusted nodes as the offerer. Offer and answer signatures are checked
/// against the pinned directory key BEFORE any state changes, and every data
/// channel frame is dropped until both hellos verified.
final class PeerConnector {
  PeerConnector({
    required this.identity,
    required this.directory,
    required this.signaler,
    required this.transportFactory,
    required this.iceProvider,
    this.connectTimeout = const Duration(seconds: 15),
    DateTime Function()? clock,
    Random? random,
    this.relay,
    this.relayEnabled,
    this.directTimeout = const Duration(seconds: 8),
    this.upgradeInterval = const Duration(seconds: 60),
    this.upgradeMaxInterval = const Duration(minutes: 5),
    Future<void> Function(Duration)? sleep,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure(),
       _sleep = sleep ?? Future<void>.delayed {
    _relaySubscription = relay?.linkOpened.listen(_onRelayLink);
  }

  final NodeIdentity identity;
  final NodeDirectory directory;
  final SignalSender signaler;
  final PeerTransportFactory transportFactory;
  final Future<List<Map<String, dynamic>>> Function() iceProvider;

  /// Direct attempt timeout when no relay is configured.
  final Duration connectTimeout;
  final DateTime Function() _clock;
  final Random _random;

  /// Socket relay fallback (Appendix B). Null disables the ladder.
  final RelayManager? relay;

  /// True when the server's ice-config reports `ws_relay_enabled`. Evaluated
  /// after the direct attempt failed.
  final Future<bool> Function()? relayEnabled;

  /// How long the direct attempt runs before falling back to the relay.
  final Duration directTimeout;

  /// First wait before a background direct upgrade; doubles on failure up to
  /// [upgradeMaxInterval]. Never more often than this interval.
  final Duration upgradeInterval;
  final Duration upgradeMaxInterval;
  final Future<void> Function(Duration) _sleep;
  StreamSubscription<RelayLink>? _relaySubscription;
  bool _closedFlag = false;

  final Map<String, _Attempt> _attempts = <String, _Attempt>{};
  final Map<String, Future<PeerLink>> _ladders = <String, Future<PeerLink>>{};
  final Map<String, PeerLink> _links = <String, PeerLink>{};
  final Map<String, DateTime> _replay = <String, DateTime>{};
  final StreamController<PeerLink> _linkOpened =
      StreamController<PeerLink>.broadcast();

  Stream<PeerLink> get linkOpened => _linkOpened.stream;
  PeerLink? linkFor(String nodeId) => _links[nodeId];

  /// Entry point for server `relay` frames. Never throws.
  Future<void> handleRelay(Map<String, dynamic> data) =>
      relay?.handleRelay(data) ?? Future<void>.value();

  /// Opens (or reuses) a link: direct first, then (if enabled) the socket
  /// relay, with a background upgrade back to direct.
  Future<PeerLink> connect(String nodeId) {
    final PeerLink? existing = _links[nodeId];
    if (existing != null && existing.isOpen) return Future<PeerLink>.value(existing);
    if (relay == null) return _connectDirect(nodeId, connectTimeout);
    final Future<PeerLink>? running = _ladders[nodeId];
    if (running != null) return running;
    final Future<PeerLink> ladder = _ladder(nodeId);
    _ladders[nodeId] = ladder;
    ladder.then<void>(
      (_) {
        _ladders.remove(nodeId);
      },
      onError: (Object _) {
        _ladders.remove(nodeId);
      },
    );
    return ladder;
  }

  Future<PeerLink> _ladder(String nodeId) async {
    final DirectoryNode? remote = directory.trustedNode(nodeId);
    if (remote == null || (remote.kind != 'engine' && remote.kind != 'thin')) {
      throw const PeerConnectException(
        'That node is not a trusted member of this hive.',
      );
    }
    Object directError;
    try {
      return _adopt(nodeId, await _connectDirect(nodeId, directTimeout));
    } on Object catch (error) {
      directError = error;
    }
    bool allowed = false;
    try {
      allowed = await (relayEnabled?.call() ?? Future<bool>.value(false));
    } on Object {
      allowed = false;
    }
    if (!allowed || _closedFlag) throw directError;
    try {
      return _adopt(nodeId, await relay!.connect(nodeId));
    } on Object catch (error) {
      throw PeerConnectException(
        'Direct connection failed ($directError) and the relay failed ($error).',
      );
    }
  }

  PeerLink _adopt(String nodeId, PeerLink inner) {
    final PeerLink? existing = _links[nodeId];
    if (existing is SwitchablePeerLink && existing.isOpen) {
      existing.swap(inner);
      return existing;
    }
    final SwitchablePeerLink link = SwitchablePeerLink(inner);
    _links[nodeId] = link;
    unawaited(
      link.done.then<void>((_) {
        if (identical(_links[nodeId], link)) _links.remove(nodeId);
      }),
    );
    if (!_linkOpened.isClosed) _linkOpened.add(link);
    if (inner.tier == relayTier) unawaited(_upgradeLoop(nodeId, link));
    return link;
  }

  void _onRelayLink(RelayLink inbound) {
    if (_closedFlag) return;
    final String nodeId = inbound.remoteNodeId;
    if (_ladders.containsKey(nodeId)) return; // the ladder adopts its own link
    final PeerLink? existing = _links[nodeId];
    if (existing != null && existing.isOpen) {
      if (existing.tier == relayTier && existing is SwitchablePeerLink) {
        existing.swap(inbound);
      } else {
        unawaited(inbound.close());
      }
      return;
    }
    _adopt(nodeId, inbound);
  }

  /// Keeps trying to replace a relay link with a direct one (backoff, never
  /// more often than [upgradeInterval]) and swaps transparently.
  Future<void> _upgradeLoop(String nodeId, SwitchablePeerLink link) async {
    Duration wait = upgradeInterval;
    while (!_closedFlag && link.isOpen && link.tier == relayTier) {
      await _sleep(wait);
      if (_closedFlag || !link.isOpen || link.tier != relayTier) return;
      try {
        link.swap(await _connectDirect(nodeId, directTimeout, upgrade: true));
        return;
      } on Object {
        final Duration doubled = wait * 2;
        wait = doubled > upgradeMaxInterval ? upgradeMaxInterval : doubled;
      }
    }
  }

  Future<PeerLink> _connectDirect(
    String nodeId,
    Duration timeout, {
    bool upgrade = false,
  }) async {
    if (!upgrade) {
      final PeerLink? existing = _links[nodeId];
      if (existing != null && existing.isOpen) return existing;
    }
    final _Attempt? pending = _attempts[nodeId];
    if (pending != null) return pending.ready.future;
    final DirectoryNode? remote = directory.trustedNode(nodeId);
    if (remote == null || (remote.kind != 'engine' && remote.kind != 'thin')) {
      throw const PeerConnectException(
        'That node is not a trusted member of this hive.',
      );
    }
    List<Map<String, dynamic>> ice = const <Map<String, dynamic>>[];
    try {
      ice = await iceProvider();
    } on Object {
      // Host candidates only.
    }
    final PeerTransport transport = await transportFactory.create(iceServers: ice);
    final String sid = newSid(_clock(), _random);
    final _Attempt attempt = _Attempt(sid, remote, transport, upgrade: upgrade);
    _attempts[nodeId] = attempt;
    attempt.timer = Timer(timeout, () {
      if (attempt.link == null) {
        unawaited(_teardown(attempt, const PeerConnectException('Connection timed out.')));
      }
    });
    unawaited(_pump(attempt));
    unawaited(
      transport.closed.then<void>(
        (_) => _teardown(attempt, const PeerConnectException('Transport closed.'), notify: false),
        onError: (Object _) => _teardown(attempt, const PeerConnectException('Transport failed.'), notify: false),
      ),
    );
    try {
      final String sdp = await transport.createOffer();
      attempt.offerSdp = sdp;
      final String sig = await identity.sign(
        await sdpMessage(sid, identity.nodeId, remote.id, sdp),
      );
      await signaler.sendSignal(
        sid: sid,
        to: remote.id,
        kind: 'offer',
        body: <String, dynamic>{'type': 'offer', 'sdp': sdp},
        sig: sig,
      );
      attempt.candidateSubscription = transport.localCandidates.listen((
        Map<String, dynamic> candidate,
      ) {
        unawaited(
          signaler
              .sendSignal(
                sid: sid,
                to: remote.id,
                kind: 'candidate',
                body: candidate,
              )
              .catchError((Object _) {}),
        );
      });
    } on Object catch (error) {
      await _teardown(attempt, error);
      rethrow;
    }
    return attempt.ready.future;
  }

  /// Entry point for server `signal` frames. Never throws.
  Future<void> handleSignal(Map<String, dynamic> data) async {
    try {
      await _handleSignal(data);
    } on Object {
      // Invalid or unexpected signals are dropped silently.
    }
  }

  Future<void> closePeer(String nodeId) async {
    final _Attempt? attempt = _attempts[nodeId];
    if (attempt != null) {
      await _teardown(attempt, const PeerConnectException('Closed.'));
    }
    await _links[nodeId]?.close();
    await relay?.closePeer(nodeId);
  }

  Future<void> close() async {
    _closedFlag = true;
    await _relaySubscription?.cancel();
    for (final _Attempt attempt in _attempts.values.toList()) {
      await _teardown(attempt, const PeerConnectException('Closed.'), notify: false);
    }
    for (final PeerLink link in _links.values.toList()) {
      await link.close();
    }
    await relay?.close();
    await _linkOpened.close();
  }

  Future<void> _handleSignal(Map<String, dynamic> data) async {
    final Object? kind = data['kind'];
    final Object? sender = data['from'];
    if (sender is! String || nodeIdsEqual(sender, identity.nodeId)) return;
    final _Attempt? attempt = _attempts[sender];
    if (attempt == null || data['sid'] != attempt.sid) return;
    switch (kind) {
      case 'answer':
        if (attempt.answered) return;
        final String? sdp = await _verifyAnswer(attempt, data);
        if (sdp != null) await _acceptAnswer(attempt, sdp);
      case 'candidate':
        final Object? body = data['body'];
        if (body is! Map || attempt.candidates >= 32) return;
        final Object? text = body['candidate'];
        if (text is! String || !text.startsWith('candidate:') || text.length > 512) {
          return;
        }
        attempt.candidates++;
        await attempt.transport.addRemoteCandidate(body.cast<String, dynamic>());
      case 'bye':
        await _teardown(attempt, const PeerConnectException('Closed by peer.'), notify: false);
    }
  }

  /// Verifies sender, freshness, pinned-key signature and replay. Returns the
  /// SDP only if everything holds; nothing is applied before this returns.
  Future<String?> _verifyAnswer(_Attempt attempt, Map<String, dynamic> data) async {
    final Object? body = data['body'];
    final Object? sig = data['sig'];
    final Object? sid = data['sid'];
    if (body is! Map || sig is! String || sid is! String) return null;
    final Object? sdp = body['sdp'];
    if (sdp is! String || sdp.length > maxSdpChars) return null;
    final DateTime? stamp = sidTimestamp(sid);
    if (stamp == null ||
        _clock().toUtc().difference(stamp).abs() > signalFreshnessWindow) {
      return null;
    }
    // Pinned directory key, not anything carried in the message.
    final DirectoryNode? remote = directory.trustedNode(attempt.remote.id);
    if (remote == null) return null;
    final bool valid = await verifySignature(
      publicKey: remote.publicKey,
      signature: sig,
      message: await sdpMessage(sid, remote.id, identity.nodeId, sdp),
    );
    if (!valid) return null;
    if (!_remember('${remote.id}|$sid|answer')) return null;
    return sdp;
  }

  bool _remember(String key) {
    final DateTime now = _clock();
    _replay.removeWhere((String _, DateTime expiry) => expiry.isBefore(now));
    if (_replay.containsKey(key)) return false;
    if (_replay.length >= _replayCacheLimit) {
      final String oldest = _replay.entries
          .reduce((MapEntry<String, DateTime> a, MapEntry<String, DateTime> b) =>
              a.value.isBefore(b.value) ? a : b)
          .key;
      _replay.remove(oldest);
    }
    _replay[key] = now.add(signalFreshnessWindow * 2);
    return true;
  }

  Future<void> _acceptAnswer(_Attempt attempt, String answerSdp) async {
    try {
      attempt.answered = true;
      final String? offerSdp = attempt.offerSdp;
      if (offerSdp == null) {
        throw const PeerConnectException('Missing local description.');
      }
      final String offerFingerprint = extractFingerprint(offerSdp);
      final String answerFingerprint = extractFingerprint(answerSdp);
      attempt.handshake = PeerHandshake(
        identity: identity,
        remoteNodeId: attempt.remote.id,
        remotePublicKey: attempt.remote.publicKey,
        offererFingerprint: offerFingerprint,
        answererFingerprint: answerFingerprint,
        isOfferer: true,
        random: _random,
      );
      await attempt.transport.setRemoteAnswer(answerSdp);
      unawaited(
        attempt.transport.controlOpen.then<void>(
          (_) => _sendHello(attempt),
          onError: (Object error) => _teardown(attempt, error),
        ),
      );
    } on Object catch (error) {
      await _teardown(attempt, error);
    }
  }

  Future<void> _sendHello(_Attempt attempt) async {
    final PeerHandshake? handshake = attempt.handshake;
    if (attempt.helloSent || attempt.closed || handshake == null) return;
    attempt.helloSent = true;
    await _sendControl(attempt, 'peer.hello', handshake.hello());
  }

  Future<void> _sendControl(_Attempt attempt, String type, Object data) async {
    try {
      final List<String> parts = splitMessage(
        encodeEnvelope(
          Envelope(
            type: type,
            data: data,
            src: identity.nodeId,
            dst: attempt.remote.id,
          ),
        ),
      );
      for (final String part in parts) {
        await attempt.transport.sendText('control', part);
      }
    } on Object catch (error) {
      await _teardown(attempt, error);
    }
  }

  /// Reads transport messages in order. Before the handshake completes only
  /// `peer.hello` / `peer.proof` on `control` are processed; the rest is dropped.
  Future<void> _pump(_Attempt attempt) async {
    await for (final ChannelMessage message in attempt.transport.messages) {
      if (attempt.closed) return;
      final Reassembler reassembler = attempt.reassemblers.putIfAbsent(
        message.channel,
        Reassembler.new,
      );
      final Envelope? envelope;
      try {
        envelope = decodeMessage(reassembler, message.text);
      } on ChannelException {
        continue;
      }
      if (envelope == null) continue;
      if (envelope.src != null && !nodeIdsEqual(envelope.src!, attempt.remote.id)) {
        continue;
      }
      if (envelope.dst != null && !nodeIdsEqual(envelope.dst!, identity.nodeId)) {
        continue;
      }
      final bool isHandshake =
          message.channel == 'control' &&
          (envelope.type == 'peer.hello' || envelope.type == 'peer.proof');
      final AuthenticatedPeerLink? link = attempt.link;
      if (link == null) {
        if (isHandshake && attempt.handshake != null) {
          await _handshakeStep(attempt, envelope);
        }
        continue;
      }
      if (!isHandshake) link.deliver(message.channel, envelope);
    }
  }

  Future<void> _handshakeStep(_Attempt attempt, Envelope envelope) async {
    final PeerHandshake handshake = attempt.handshake!;
    try {
      if (envelope.type == 'peer.hello') {
        final Map<String, dynamic> proof = await handshake.receiveHello(envelope.data);
        await _sendControl(attempt, 'peer.proof', proof);
      } else {
        await handshake.receiveProof(envelope.data);
      }
    } on HandshakeException catch (error) {
      await _teardown(attempt, PeerConnectException(error.message));
      return;
    }
    if (handshake.authenticated) _complete(attempt);
  }

  void _complete(_Attempt attempt) {
    if (attempt.link != null || attempt.closed) return;
    if (!directory.isTrusted(attempt.remote.id)) {
      unawaited(_teardown(attempt, const PeerConnectException('Peer is not trusted.')));
      return;
    }
    final AuthenticatedPeerLink link = AuthenticatedPeerLink(
      remoteNodeId: attempt.remote.id,
      localNodeId: identity.nodeId,
      transport: attempt.transport,
      onClose: () => _linkClosed(attempt),
    );
    attempt.link = link;
    attempt.timer?.cancel();
    _attempts.remove(attempt.remote.id);
    // With a relay configured the ladder (or the upgrade loop) registers the
    // link; without one the connector registers it directly as before.
    if (relay == null && !attempt.upgrade) {
      _links[attempt.remote.id] = link;
      unawaited(
        link.done.then<void>((_) {
          if (identical(_links[attempt.remote.id], link)) {
            _links.remove(attempt.remote.id);
          }
        }),
      );
      if (!_linkOpened.isClosed) _linkOpened.add(link);
    }
    if (!attempt.ready.isCompleted) attempt.ready.complete(link);
  }

  Future<void> _linkClosed(_Attempt attempt) async {
    try {
      await signaler.sendSignal(
        sid: attempt.sid,
        to: attempt.remote.id,
        kind: 'bye',
        body: const <String, dynamic>{},
      );
    } on Object {
      // Best effort.
    }
  }

  Future<void> _teardown(
    _Attempt attempt,
    Object reason, {
    bool notify = true,
  }) async {
    if (attempt.closed) return;
    attempt.closed = true;
    attempt.timer?.cancel();
    await attempt.candidateSubscription?.cancel();
    if (identical(_attempts[attempt.remote.id], attempt)) {
      _attempts.remove(attempt.remote.id);
    }
    if (notify && attempt.link == null) {
      try {
        await signaler.sendSignal(
          sid: attempt.sid,
          to: attempt.remote.id,
          kind: 'bye',
          body: const <String, dynamic>{},
        );
      } on Object {
        // Best effort.
      }
    }
    try {
      await attempt.transport.close();
    } on Object {
      // Already closed.
    }
    if (attempt.link == null && !attempt.ready.isCompleted) {
      attempt.ready.completeError(reason);
    }
  }
}
