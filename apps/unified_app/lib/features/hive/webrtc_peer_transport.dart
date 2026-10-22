import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

const int _highWater = 1024 * 1024;
const int _lowWater = 256 * 1024;
const Duration _stallTimeout = Duration(seconds: 30);

/// flutter_webrtc implementation of [PeerTransportFactory].
///
/// Pinned `flutter_webrtc` 1.6.2+hotfix.4. Data channels only: no media.
final class WebRtcPeerTransportFactory implements PeerTransportFactory {
  const WebRtcPeerTransportFactory();

  @override
  Future<PeerTransport> create({
    required List<Map<String, dynamic>> iceServers,
  }) async {
    final RTCPeerConnection connection = await createPeerConnection(
      <String, dynamic>{
        'iceServers': iceServers,
        'sdpSemantics': 'unified-plan',
      },
    );
    return WebRtcPeerTransport._(connection);
  }
}

final class WebRtcPeerTransport implements PeerTransport {
  WebRtcPeerTransport._(this._connection) {
    _connection.onIceCandidate = (RTCIceCandidate candidate) {
      final String? text = candidate.candidate;
      if (text == null || text.isEmpty || _candidates.isClosed) return;
      _candidates.add(<String, dynamic>{
        'candidate': text,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    _connection.onConnectionState = (RTCPeerConnectionState state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _markClosed();
      }
    };
  }

  final RTCPeerConnection _connection;
  final Map<String, RTCDataChannel> _channels = <String, RTCDataChannel>{};
  final Map<String, Completer<void>> _drained = <String, Completer<void>>{};
  final StreamController<ChannelMessage> _messages =
      StreamController<ChannelMessage>();
  final StreamController<Map<String, dynamic>> _candidates =
      StreamController<Map<String, dynamic>>.broadcast();
  final Completer<void> _controlOpen = Completer<void>();
  final Completer<void> _closed = Completer<void>();
  String _tier = 'direct';

  @override
  String get tier => _tier;
  @override
  Stream<Map<String, dynamic>> get localCandidates => _candidates.stream;
  @override
  Stream<ChannelMessage> get messages => _messages.stream;
  @override
  Future<void> get controlOpen => _controlOpen.future;
  @override
  Future<void> get closed => _closed.future;

  @override
  Future<String> createOffer() async {
    // Negotiated channels with fixed ids, created before the offer so the SDP
    // carries the SCTP section (webrtc.md Appendix A).
    for (final MapEntry<String, int> entry in channelIds.entries) {
      final RTCDataChannelInit init = RTCDataChannelInit()
        ..ordered = true
        ..negotiated = true
        ..id = entry.value;
      final RTCDataChannel channel = await _connection.createDataChannel(
        entry.key,
        init,
      );
      _attach(entry.key, channel);
    }
    final RTCSessionDescription offer = await _connection.createOffer();
    await _connection.setLocalDescription(offer);
    final String? sdp = offer.sdp;
    if (sdp == null || sdp.isEmpty) {
      throw StateError('WebRTC produced an empty offer.');
    }
    return sdp;
  }

  void _attach(String name, RTCDataChannel channel) {
    _channels[name] = channel;
    channel.bufferedAmountLowThreshold = _lowWater;
    channel.onMessage = (RTCDataChannelMessage message) {
      if (message.isBinary || _messages.isClosed) return;
      _messages.add(ChannelMessage(name, message.text));
    };
    channel.onBufferedAmountLow = (int _) {
      final Completer<void>? waiter = _drained.remove(name);
      if (waiter != null && !waiter.isCompleted) waiter.complete();
    };
    channel.onDataChannelState = (RTCDataChannelState state) {
      if (name == 'control' &&
          state == RTCDataChannelState.RTCDataChannelOpen &&
          !_controlOpen.isCompleted) {
        _controlOpen.complete();
        unawaited(_detectTier());
      }
      if (name == 'control' &&
          (state == RTCDataChannelState.RTCDataChannelClosed ||
              state == RTCDataChannelState.RTCDataChannelClosing)) {
        _markClosed();
      }
    };
  }

  @override
  Future<void> setRemoteAnswer(String sdp) =>
      _connection.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));

  @override
  Future<void> addRemoteCandidate(Map<String, dynamic> candidate) =>
      _connection.addCandidate(
        RTCIceCandidate(
          candidate['candidate'] as String?,
          candidate['sdpMid'] as String?,
          candidate['sdpMLineIndex'] as int?,
        ),
      );

  @override
  Future<void> sendText(String channel, String text) async {
    final RTCDataChannel? dc = _channels[channel];
    if (dc == null || dc.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('The $channel data channel is not open.');
    }
    // Backpressure: pause above the high-water mark, resume on bufferedamountlow.
    while (await dc.getBufferedAmount() > _highWater) {
      final Completer<void> waiter = _drained[channel] = Completer<void>();
      await waiter.future.timeout(
        _stallTimeout,
        onTimeout: () => throw StateError('The $channel data channel stalled.'),
      );
    }
    await dc.send(RTCDataChannelMessage(text));
  }

  /// Best-effort: `relay-udp` when the selected pair uses a TURN candidate.
  Future<void> _detectTier() async {
    try {
      final List<StatsReport> reports = await _connection.getStats();
      final Map<String, StatsReport> byId = <String, StatsReport>{
        for (final StatsReport r in reports) r.id: r,
      };
      for (final StatsReport report in reports) {
        if (report.type != 'candidate-pair') continue;
        final Map<dynamic, dynamic> values = report.values;
        if (values['nominated'] != true && '${values['nominated']}' != 'true') {
          continue;
        }
        final StatsReport? local = byId['${values['localCandidateId']}'];
        if (local?.values['candidateType'] == 'relay') _tier = 'relay-udp';
        return;
      }
    } on Object {
      // Stats are optional; keep the default tier.
    }
  }

  void _markClosed() {
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> close() async {
    _markClosed();
    for (final Completer<void> waiter in _drained.values) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _drained.clear();
    for (final RTCDataChannel channel in _channels.values) {
      try {
        await channel.close();
      } on Object {
        // Already closed.
      }
    }
    try {
      await _connection.close();
      await _connection.dispose();
    } on Object {
      // Already disposed.
    }
    if (!_messages.isClosed) unawaited(_messages.close());
    if (!_candidates.isClosed) unawaited(_candidates.close());
  }
}
