import 'dart:async';

import 'channel_codec.dart';

/// One raw text message received on a named data channel.
final class ChannelMessage {
  const ChannelMessage(this.channel, this.text);
  final String channel;
  final Object? text;
}

/// An authenticated envelope received from a peer.
final class InboundEnvelope {
  const InboundEnvelope(this.channel, this.envelope);
  final String channel;
  final Envelope envelope;
}

/// One transport session to a remote node (a WebRTC peer connection in the
/// app, a fake in tests). Everything above it is transport independent, so a
/// signalling-socket relay can later provide the same contract.
abstract interface class PeerTransport {
  /// Connection tier for the node list: `direct`, `relay-udp`, `ws-relay`, ...
  String get tier;

  /// Creates the negotiated data channels (ids from [channelIds]), sets the
  /// local description and returns its SDP.
  Future<String> createOffer();
  Future<void> setRemoteAnswer(String sdp);
  Future<void> addRemoteCandidate(Map<String, dynamic> candidate);

  /// Locally gathered ICE candidates: `{candidate, sdpMid, sdpMLineIndex}`.
  Stream<Map<String, dynamic>> get localCandidates;

  /// Messages from every data channel.
  Stream<ChannelMessage> get messages;

  /// Completes when the `control` channel is open.
  Future<void> get controlOpen;

  /// Sends one text message (<= 16 KiB); implementations apply backpressure.
  Future<void> sendText(String channel, String text);

  /// Completes when the transport has closed or failed.
  Future<void> get closed;
  Future<void> close();
}

abstract interface class PeerTransportFactory {
  /// [iceServers] use the `ice-config` shape: `{urls, username?, credential?}`.
  Future<PeerTransport> create({required List<Map<String, dynamic>> iceServers});
}

/// An open, channel-bound link to one trusted node.
abstract interface class PeerLink {
  String get remoteNodeId;
  String get tier;
  bool get isOpen;
  Stream<InboundEnvelope> get envelopes;
  Future<void> send(String channel, Envelope envelope);
  Future<void> get done;
  Future<void> close();
}

/// [PeerLink] produced by the connector after both hellos verified.
final class AuthenticatedPeerLink implements PeerLink {
  AuthenticatedPeerLink({
    required this.remoteNodeId,
    required this.localNodeId,
    required PeerTransport transport,
    Future<void> Function()? onClose,
  }) : _transport = transport,
       _onClose = onClose {
    unawaited(
      transport.closed.then<void>(
        (_) => _finish(),
        onError: (Object _) => _finish(),
      ),
    );
  }

  @override
  final String remoteNodeId;
  final String localNodeId;
  final PeerTransport _transport;
  final Future<void> Function()? _onClose;
  final StreamController<InboundEnvelope> _inbound =
      StreamController<InboundEnvelope>.broadcast();
  final Completer<void> _done = Completer<void>();
  Future<void> _sendQueue = Future<void>.value();
  bool _closed = false;

  @override
  String get tier => _transport.tier;
  @override
  bool get isOpen => !_closed;
  @override
  Stream<InboundEnvelope> get envelopes => _inbound.stream;
  @override
  Future<void> get done => _done.future;

  /// Called by the connector for envelopes that arrive after authentication.
  void deliver(String channel, Envelope envelope) {
    if (!_closed && !_inbound.isClosed) {
      _inbound.add(InboundEnvelope(channel, envelope));
    }
  }

  @override
  Future<void> send(String channel, Envelope envelope) {
    if (_closed) {
      return Future<void>.error(const ChannelException('The peer link is closed.'));
    }
    final List<String> messages = splitMessage(
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
    // Serialise so the chunks of one message stay contiguous on the channel.
    final Future<void> next = _sendQueue.catchError((Object _) {}).then((_) async {
      for (final String message in messages) {
        if (_closed) throw const ChannelException('The peer link is closed.');
        await _transport.sendText(channel, message);
      }
    });
    _sendQueue = next;
    return next;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _finish();
    await _onClose?.call();
    await _transport.close();
  }

  void _finish() {
    if (_closed) return;
    _closed = true;
    if (!_done.isCompleted) _done.complete();
    unawaited(_inbound.close());
  }
}
