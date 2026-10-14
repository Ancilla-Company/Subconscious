import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';

String sdpWithFingerprint(String hex) =>
    'v=0\r\na=fingerprint:sha-256 $hex\r\na=setup:actpass\r\n';

const String offerFingerprintHex =
    'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:'
    'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99';
const String answerFingerprintHex =
    '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:'
    '11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00';

/// In-memory [PeerTransport] driven by the test.
final class FakeTransport implements PeerTransport {
  FakeTransport({this.tier = 'direct'});

  @override
  final String tier;
  final StreamController<ChannelMessage> incoming =
      StreamController<ChannelMessage>();
  final StreamController<Map<String, dynamic>> candidates =
      StreamController<Map<String, dynamic>>.broadcast();
  final Completer<void> _controlOpen = Completer<void>();
  final Completer<void> _closed = Completer<void>();
  final List<ChannelMessage> sent = <ChannelMessage>[];
  String? remoteAnswer;
  final List<Map<String, dynamic>> remoteCandidates = <Map<String, dynamic>>[];
  bool wasClosed = false;

  @override
  Future<String> createOffer() async => sdpWithFingerprint(offerFingerprintHex);

  @override
  Future<void> setRemoteAnswer(String sdp) async => remoteAnswer = sdp;

  @override
  Future<void> addRemoteCandidate(Map<String, dynamic> candidate) async =>
      remoteCandidates.add(candidate);

  @override
  Stream<Map<String, dynamic>> get localCandidates => candidates.stream;
  @override
  Stream<ChannelMessage> get messages => incoming.stream;
  @override
  Future<void> get controlOpen => _controlOpen.future;
  @override
  Future<void> get closed => _closed.future;

  @override
  Future<void> sendText(String channel, String text) async {
    sent.add(ChannelMessage(channel, text));
  }

  @override
  Future<void> close() async {
    wasClosed = true;
    if (!_closed.isCompleted) _closed.complete();
    // Not awaited: the done event waits for the pump, which may be the caller.
    if (!incoming.isClosed) unawaited(incoming.close());
  }

  void openControl() {
    if (!_controlOpen.isCompleted) _controlOpen.complete();
  }

  /// Delivers [envelope] as the remote side would, chunked if large.
  void deliver(String channel, Envelope envelope) {
    for (final String part in splitMessage(encodeEnvelope(envelope))) {
      incoming.add(ChannelMessage(channel, part));
    }
  }

  /// Envelopes this side sent on [channel] (reassembled).
  List<Envelope> sentOn(String channel) {
    final Reassembler r = Reassembler();
    final List<Envelope> out = <Envelope>[];
    for (final ChannelMessage m in sent.where((ChannelMessage m) => m.channel == channel)) {
      final Envelope? e = decodeMessage(r, m.text);
      if (e != null) out.add(e);
    }
    return out;
  }
}

final class FakeTransportFactory implements PeerTransportFactory {
  final List<FakeTransport> created = <FakeTransport>[];
  @override
  Future<PeerTransport> create({
    required List<Map<String, dynamic>> iceServers,
  }) async {
    final FakeTransport t = FakeTransport();
    created.add(t);
    return t;
  }
}

final class SentSignal {
  SentSignal(this.sid, this.to, this.kind, this.body, this.sig);
  final String sid;
  final String to;
  final String kind;
  final Map<String, dynamic> body;
  final String? sig;
}

final class RecordingSignaler implements SignalSender {
  final List<SentSignal> signals = <SentSignal>[];
  final StreamController<SentSignal> stream = StreamController<SentSignal>.broadcast();
  @override
  Future<void> sendSignal({
    required String sid,
    required String to,
    required String kind,
    required Map<String, dynamic> body,
    String? sig,
  }) async {
    final SentSignal s = SentSignal(sid, to, kind, body, sig);
    signals.add(s);
    stream.add(s);
  }
}

/// Raw node JSON as returned by `GET /nodes`.
Map<String, dynamic> nodeJson(
  NodeIdentity identity, {
  String kind = 'engine',
  String status = 'active',
  String? approvedBy,
  String? approvalSig,
  bool online = true,
  String name = 'node',
}) => <String, dynamic>{
  'id': identity.nodeId,
  'kind': kind,
  'name': name,
  'platform': 'test',
  'app_version': '1',
  'protocol_version': 1,
  'public_key': identity.publicKeyB64u,
  'status': status,
  'approved_by': approvedBy,
  'approval_sig': approvalSig,
  'capabilities': <String, dynamic>{},
  'online': online,
};

Future<NodeIdentity> seededIdentity(int start) =>
    NodeIdentity.fromSeed(List<int>.generate(32, (int i) => start + i));
