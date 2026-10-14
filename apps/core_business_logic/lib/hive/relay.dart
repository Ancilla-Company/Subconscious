import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'channel_codec.dart';
import 'directory.dart';
import 'encoding.dart';
import 'identity.dart';
import 'peer_connector.dart' show newSid;
import 'peer_link.dart';
import 'relay_crypto.dart';

export 'relay_crypto.dart';

/// Connection tier reported for relay links.
const String relayTier = 'ws-relay';
const int _maxConsecutiveAuthFailures = 5;
const int _maxPendingResponders = 8;
const int _seenSidLimit = 512;

/// Sends relay frames over the signalling socket (`SignalingClient`).
abstract interface class RelaySender {
  Future<void> sendRelay({
    required String sid,
    required String to,
    required Object payload,
  });
}

/// One established relay session to a trusted node. Implements [PeerLink], so
/// `PeerEngineSocket` and `DataChannelHttpClient` work unchanged.
final class RelayLink implements PeerLink {
  RelayLink({
    required this.remoteNodeId,
    required this.localNodeId,
    required this.sid,
    required Uint8List sendKey,
    required Uint8List receiveKey,
    required Uint8List aad,
    required Future<void> Function(Uint8List record) transmit,
    Future<void> Function()? onClosed,
  }) : _sendKey = sendKey,
       _receiveKey = receiveKey,
       _aad = aad,
       _transmit = transmit,
       _onClosed = onClosed;

  @override
  final String remoteNodeId;
  final String localNodeId;
  final String sid;
  final Uint8List _sendKey;
  final Uint8List _receiveKey;
  final Uint8List _aad;
  final Future<void> Function(Uint8List record) _transmit;
  final Future<void> Function()? _onClosed;

  final StreamController<InboundEnvelope> _inbound =
      StreamController<InboundEnvelope>.broadcast();
  final Completer<void> _done = Completer<void>();
  final Map<String, Reassembler> _reassemblers = <String, Reassembler>{};
  Future<void> _sendQueue = Future<void>.value();
  Future<void> _receiveQueue = Future<void>.value();
  int _sendCounter = 0;
  int _lastReceived = -1;
  int _authFailures = 0;
  bool _closed = false;

  @override
  String get tier => relayTier;
  @override
  bool get isOpen => !_closed;
  @override
  Stream<InboundEnvelope> get envelopes => _inbound.stream;
  @override
  Future<void> get done => _done.future;

  /// Records are processed strictly in arrival order.
  void onRecord(Uint8List record) {
    if (_closed) return;
    _receiveQueue = _receiveQueue
        .then<void>((_) => _process(record))
        .catchError((Object _) {});
  }

  Future<void> _process(Uint8List record) async {
    if (_closed || record.isEmpty) return;
    final int type = record[0];
    if (type == relayMsgClose) {
      // Only an authenticated close record ends the link. A bare 0x20 is ignored so a
      // forged frame cannot kill the relay (Appendix B).
      if (record.length == 1) return;
      if (await _accept(record) != null) _finish();
      return;
    }
    if (type != relayMsgData) return;
    final Uint8List? plaintext = await _accept(record);
    if (plaintext == null) return;
    _deliver(plaintext);
  }

  /// Checks the counter, decrypts and then advances the counter. A replayed
  /// or reordered counter is dropped before any decryption.
  Future<Uint8List?> _accept(Uint8List record) async {
    if (record.length < 1 + 8 + relayTagBytes) return null;
    final int? counter = relayParseCounter(record.sublist(1, 9));
    if (counter == null || counter <= _lastReceived) return null;
    final Uint8List? clear = await relayOpen(
      key: _receiveKey,
      record: record,
      aad: _aad,
    );
    if (clear == null) {
      _authFailures++;
      if (_authFailures >= _maxConsecutiveAuthFailures) {
        unawaited(close());
      }
      return null;
    }
    _authFailures = 0;
    _lastReceived = counter;
    return clear;
  }

  void _deliver(Uint8List plaintext) {
    try {
      final Object? decoded = jsonDecode(utf8.decode(plaintext));
      if (decoded is! Map) return;
      final Object? channel = decoded['ch'];
      if (channel is! String || !channelIds.containsKey(channel)) return;
      final Reassembler reassembler = _reassemblers.putIfAbsent(
        channel,
        Reassembler.new,
      );
      final Envelope? envelope = decodeMessage(
        reassembler,
        jsonEncode(decoded['env']),
      );
      if (envelope == null) return;
      if (envelope.src != null && !nodeIdsEqual(envelope.src!, remoteNodeId)) {
        return;
      }
      if (envelope.dst != null && !nodeIdsEqual(envelope.dst!, localNodeId)) {
        return;
      }
      if (!_inbound.isClosed) _inbound.add(InboundEnvelope(channel, envelope));
    } on Object {
      // Authenticated but malformed content is dropped.
    }
  }

  @override
  Future<void> send(String channel, Envelope envelope) {
    if (_closed) {
      return Future<void>.error(const ChannelException('The peer link is closed.'));
    }
    if (!channelIds.containsKey(channel)) {
      return Future<void>.error(ChannelException('Unknown channel: $channel'));
    }
    final List<String> parts = splitMessage(
      encodeEnvelope(
        Envelope(
          type: envelope.type,
          data: envelope.data,
          id: envelope.id,
          src: localNodeId,
          dst: remoteNodeId,
        ),
      ),
    );
    final Future<void> next = _sendQueue.catchError((Object _) {}).then((_) async {
      for (final String part in parts) {
        if (_closed) throw const ChannelException('The peer link is closed.');
        final List<int> plaintext = utf8.encode(
          '{"ch":${jsonEncode(channel)},"env":$part}',
        );
        final Uint8List record = await relaySeal(
          key: _sendKey,
          counter: _sendCounter,
          aad: _aad,
          plaintext: plaintext,
        );
        if (record.length > relayRawLimit) {
          throw const ChannelException('Relay record exceeds 24 KiB.');
        }
        _sendCounter++;
        await _transmit(record);
      }
    });
    _sendQueue = next;
    return next.catchError((Object error) {
      if (error is RelayException) unawaited(close());
      throw error;
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    final bool canSend = _sendCounter <= relayMaxCounter;
    _finish();
    if (canSend) {
      try {
        final Uint8List record = await relaySeal(
          key: _sendKey,
          counter: _sendCounter,
          aad: _aad,
          plaintext: const <int>[],
          type: relayMsgClose,
        );
        _sendCounter++;
        await _transmit(record);
      } on Object {
        // Best effort.
      }
    }
    await _onClosed?.call();
  }

  void _finish() {
    if (_closed) return;
    _closed = true;
    if (!_done.isCompleted) _done.complete();
    unawaited(_inbound.close());
  }
}

final class _Handshake {
  _Handshake({
    required this.peer,
    required this.sid,
    this.initiator,
    this.responder,
  });
  final String peer;
  final String sid;
  final RelayInitiator? initiator;
  final RelayResponder? responder;
  Timer? timer;
  bool get isInitiator => initiator != null;
}

final class _Connecting {
  final Completer<RelayLink> completer = Completer<RelayLink>();

  /// Set when our own attempt lost the simultaneous-initiator tie-break.
  bool abandoned = false;
}

/// Runs relay handshakes and sessions for one node.
///
/// Feed it every server `relay` frame via [handleRelay]. The peer must be an
/// active, verified member of the account (pinned directory key).
final class RelayManager {
  RelayManager({
    required this.identity,
    required this.directory,
    required this.sender,
    this.handshakeTimeout = const Duration(seconds: 10),
    DateTime Function()? clock,
    Random? random,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  final NodeIdentity identity;
  final NodeDirectory directory;
  final RelaySender sender;
  final Duration handshakeTimeout;
  final DateTime Function() _clock;
  final Random _random;

  final Map<String, _Handshake> _handshakes = <String, _Handshake>{};
  final Map<String, RelayLink> _links = <String, RelayLink>{};
  final Map<String, _Connecting> _connecting = <String, _Connecting>{};
  final Set<String> _seenSids = <String>{};
  final StreamController<RelayLink> _linkOpened =
      StreamController<RelayLink>.broadcast();
  bool _closed = false;

  /// Links created by a peer-initiated handshake (or any new link).
  Stream<RelayLink> get linkOpened => _linkOpened.stream;

  RelayLink? linkFor(String nodeId) {
    for (final MapEntry<String, RelayLink> e in _links.entries) {
      if (e.value.isOpen && nodeIdsEqual(e.value.remoteNodeId, nodeId)) {
        return e.value;
      }
    }
    return null;
  }

  static String _key(String peer, String sid) => '${peer.toLowerCase()}|$sid';

  /// Starts a relay attempt as the initiator.
  Future<RelayLink> connect(String nodeId) {
    final RelayLink? existing = linkFor(nodeId);
    if (existing != null) return Future<RelayLink>.value(existing);
    final _Connecting? pending = _connecting[nodeId];
    if (pending != null) return pending.completer.future;
    final DirectoryNode? remote = directory.trustedNode(nodeId);
    if (remote == null) {
      return Future<RelayLink>.error(
        const RelayException('That node is not a trusted member of this hive.'),
      );
    }
    final _Connecting connecting = _Connecting();
    connecting.completer.future.ignore();
    _connecting[nodeId] = connecting;
    unawaited(_startInitiator(remote, connecting));
    return connecting.completer.future;
  }

  Future<void> _startInitiator(DirectoryNode remote, _Connecting connecting) async {
    final String sid = newSid(_clock(), _random);
    final RelayInitiator initiator = RelayInitiator(
      identity: identity,
      remoteNodeId: remote.id,
      remotePublicKey: remote.publicKey,
      sid: sid,
      random: _random,
    );
    final _Handshake handshake = _Handshake(
      peer: remote.id,
      sid: sid,
      initiator: initiator,
    );
    final String key = _key(remote.id, sid);
    _handshakes[key] = handshake;
    handshake.timer = Timer(handshakeTimeout, () {
      if (_handshakes[key] == handshake) {
        _drop(key);
        _failConnecting(remote.id, const RelayException('Relay handshake timed out.'));
      }
    });
    try {
      final Uint8List m1 = await initiator.start();
      await _transmit(remote.id, sid, m1);
    } on Object catch (error) {
      _drop(key);
      _failConnecting(remote.id, error);
    }
  }

  /// Entry point for server `relay` frames. Never throws.
  Future<void> handleRelay(Map<String, dynamic> data) async {
    try {
      await _handle(data);
    } on Object {
      // Anything invalid is dropped silently.
    }
  }

  Future<void> _handle(Map<String, dynamic> data) async {
    if (_closed) return;
    final Object? from = data['from'];
    final Object? sid = data['sid'];
    final Object? payload = data['payload'];
    if (from is! String || sid is! String || payload is! String) return;
    if (sid.isEmpty || sid.length > 64 || payload.length > 40 * 1024) return;
    if (nodeIdsEqual(from, identity.nodeId)) return;
    final DirectoryNode? remote = directory.trustedNode(from);
    if (remote == null) return;
    final Uint8List bytes = b64uDecode(payload);
    if (bytes.isEmpty || bytes.length > relayRawLimit) return;
    final String key = _key(remote.id, sid);
    final RelayLink? link = _links[key];
    if (link != null) {
      link.onRecord(bytes);
      return;
    }
    final _Handshake? handshake = _handshakes[key];
    if (handshake != null) {
      if (handshake.isInitiator && bytes[0] == relayMsgM2) {
        await _finishInitiator(handshake, remote, bytes);
      } else if (!handshake.isInitiator && bytes[0] == relayMsgM3) {
        await _finishResponder(handshake, remote, bytes);
      }
      return;
    }
    if (bytes[0] == relayMsgM1) await _startResponder(remote, sid, bytes);
  }

  Future<void> _startResponder(DirectoryNode remote, String sid, Uint8List m1) async {
    final String key = _key(remote.id, sid);
    // Tie-break: both sides started at once. The lower node id keeps its own
    // attempt as initiator; the other abandons theirs.
    _Handshake? own;
    for (final _Handshake h in _handshakes.values) {
      if (h.isInitiator && nodeIdsEqual(h.peer, remote.id)) own = h;
    }
    if (own != null) {
      if (identity.nodeId.toLowerCase().compareTo(remote.id.toLowerCase()) < 0) {
        return; // we win; ignore their M1
      }
      _drop(_key(own.peer, own.sid));
      _connecting[remote.id]?.abandoned = true;
    }
    // At most one attempt per peer pair and sid; one responder per peer.
    if (_seenSids.contains(key)) return;
    for (final _Handshake h in _handshakes.values) {
      if (!h.isInitiator && nodeIdsEqual(h.peer, remote.id)) return;
    }
    if (_handshakes.values.where((_Handshake h) => !h.isInitiator).length >=
        _maxPendingResponders) {
      return;
    }
    if (_seenSids.length >= _seenSidLimit) _seenSids.remove(_seenSids.first);
    _seenSids.add(key);
    final RelayResponder responder = RelayResponder(
      identity: identity,
      remoteNodeId: remote.id,
      remotePublicKey: remote.publicKey,
      sid: sid,
      random: _random,
    );
    final _Handshake handshake = _Handshake(
      peer: remote.id,
      sid: sid,
      responder: responder,
    );
    _handshakes[key] = handshake;
    handshake.timer = Timer(handshakeTimeout, () {
      if (_handshakes[key] == handshake) {
        _drop(key);
        _failConnecting(remote.id, const RelayException('Relay handshake timed out.'), onlyIfAbandoned: true);
      }
    });
    try {
      final Uint8List m2 = await responder.receiveM1(m1);
      await _transmit(remote.id, sid, m2);
    } on Object {
      _drop(key);
      _failConnecting(remote.id, const RelayException('Relay handshake failed.'), onlyIfAbandoned: true);
    }
  }

  Future<void> _finishInitiator(
    _Handshake handshake,
    DirectoryNode remote,
    Uint8List m2,
  ) async {
    final String key = _key(handshake.peer, handshake.sid);
    try {
      final ({Uint8List m3, RelayKeys keys}) result =
          await handshake.initiator!.receiveM2(m2);
      if (_handshakes[key] != handshake) return; // abandoned meanwhile
      _drop(key);
      // Register the session before M3 leaves so early data is not lost.
      final RelayLink link = _establish(
        remote.id,
        handshake.sid,
        sendKey: result.keys.initiatorToResponder,
        receiveKey: result.keys.responderToInitiator,
        aad: result.keys.aad,
      );
      try {
        await _transmit(remote.id, handshake.sid, result.m3);
      } on Object {
        await link.close();
        rethrow;
      }
    } on Object catch (error) {
      _drop(key);
      _failConnecting(remote.id, error);
    }
  }

  Future<void> _finishResponder(
    _Handshake handshake,
    DirectoryNode remote,
    Uint8List m3,
  ) async {
    final String key = _key(handshake.peer, handshake.sid);
    try {
      final RelayKeys keys = await handshake.responder!.receiveM3(m3);
      if (_handshakes[key] != handshake) return;
      _drop(key);
      _establish(
        remote.id,
        handshake.sid,
        sendKey: keys.responderToInitiator,
        receiveKey: keys.initiatorToResponder,
        aad: keys.aad,
      );
    } on Object {
      _drop(key);
      _failConnecting(remote.id, const RelayException('Relay handshake failed.'), onlyIfAbandoned: true);
    }
  }

  RelayLink _establish(
    String peer,
    String sid, {
    required Uint8List sendKey,
    required Uint8List receiveKey,
    required Uint8List aad,
  }) {
    final String key = _key(peer, sid);
    final RelayLink link = RelayLink(
      remoteNodeId: peer,
      localNodeId: identity.nodeId,
      sid: sid,
      sendKey: sendKey,
      receiveKey: receiveKey,
      aad: aad,
      transmit: (Uint8List record) => _transmit(peer, sid, record),
      onClosed: () async => _links.remove(key),
    );
    // A new session replaces any older one with the same peer.
    for (final MapEntry<String, RelayLink> e in _links.entries.toList()) {
      if (nodeIdsEqual(e.value.remoteNodeId, peer)) {
        unawaited(e.value.close());
        _links.remove(e.key);
      }
    }
    _links[key] = link;
    unawaited(link.done.then<void>((_) => _links.remove(key)));
    final _Connecting? connecting = _connecting.remove(peer);
    if (connecting != null && !connecting.completer.isCompleted) {
      connecting.completer.complete(link);
    }
    if (!_linkOpened.isClosed) _linkOpened.add(link);
    return link;
  }

  Future<void> _transmit(String peer, String sid, Uint8List bytes) =>
      sender.sendRelay(sid: sid, to: peer, payload: b64uEncode(bytes));

  void _drop(String key) {
    _handshakes.remove(key)?.timer?.cancel();
  }

  void _failConnecting(String peer, Object error, {bool onlyIfAbandoned = false}) {
    final _Connecting? connecting = _connecting[peer];
    if (connecting == null) return;
    if (onlyIfAbandoned && !connecting.abandoned) return;
    _connecting.remove(peer);
    if (!connecting.completer.isCompleted) {
      connecting.completer.completeError(error);
    }
  }

  Future<void> closePeer(String nodeId) async {
    for (final RelayLink link in _links.values.toList()) {
      if (nodeIdsEqual(link.remoteNodeId, nodeId)) await link.close();
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final String key in _handshakes.keys.toList()) {
      _drop(key);
    }
    for (final String peer in _connecting.keys.toList()) {
      _failConnecting(peer, const RelayException('Closed.'));
    }
    for (final RelayLink link in _links.values.toList()) {
      await link.close();
    }
    await _linkOpened.close();
  }
}
