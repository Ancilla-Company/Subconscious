import 'dart:async';
import 'dart:math';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:test/test.dart';

import 'fakes.dart';

Future<void> until(bool Function() condition) async {
  for (int i = 0; i < 400 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: 'condition not reached in time');
}

final class Harness {
  late NodeIdentity me;
  late NodeIdentity engine;
  late NodeDirectory directory;
  final RecordingSignaler signaler = RecordingSignaler();
  final FakeTransportFactory factory = FakeTransportFactory();
  late PeerConnector connector;
  DateTime now = DateTime.utc(2025, 1, 1, 12);

  static Future<Harness> create({Duration timeout = const Duration(seconds: 5)}) async {
    final Harness h = Harness();
    h.me = await seededIdentity(40);
    h.engine = await seededIdentity(1);
    h.directory = NodeDirectory(userId: 'u1', localNodeId: h.me.nodeId);
    await h.directory.update(<Object?>[
      nodeJson(h.engine),
      nodeJson(
        h.me,
        kind: 'thin',
        approvedBy: h.engine.nodeId,
        approvalSig: await h.engine.sign(approvalMessage('u1', h.me.publicKeyB64u)),
      ),
    ]);
    h.connector = PeerConnector(
      identity: h.me,
      directory: h.directory,
      signaler: h.signaler,
      transportFactory: h.factory,
      iceProvider: () async => const <Map<String, dynamic>>[],
      connectTimeout: timeout,
      clock: () => h.now,
      random: Random(1),
    );
    return h;
  }

  FakeTransport get transport => factory.created.last;

  /// The [nth] (1-based) offer sent so far, waiting for it if necessary.
  Future<SentSignal> offer({int nth = 1}) async {
    Iterable<SentSignal> offers() =>
        signaler.signals.where((SentSignal s) => s.kind == 'offer');
    await until(() => offers().length >= nth);
    return offers().elementAt(nth - 1);
  }

  Future<Map<String, dynamic>> signedAnswer(
    SentSignal offer, {
    NodeIdentity? signer,
    String? from,
    String? sid,
  }) async {
    final String sdp = sdpWithFingerprint(answerFingerprintHex);
    final String useSid = sid ?? offer.sid;
    return <String, dynamic>{
      'from': from ?? engine.nodeId,
      'sid': useSid,
      'kind': 'answer',
      'body': <String, dynamic>{'type': 'answer', 'sdp': sdp},
      'sig': await (signer ?? engine).sign(
        await sdpMessage(useSid, engine.nodeId, me.nodeId, sdp),
      ),
    };
  }

  PeerHandshake engineHandshake(SentSignal offer, {String? answererFingerprint}) =>
      PeerHandshake(
        identity: engine,
        remoteNodeId: me.nodeId,
        remotePublicKey: me.publicKey,
        offererFingerprint: extractFingerprint(offer.body['sdp'] as String),
        answererFingerprint: answererFingerprint ??
            extractFingerprint(sdpWithFingerprint(answerFingerprintHex)),
        isOfferer: false,
      );

  Envelope fromEngine(String type, Object? data, {String? id}) =>
      Envelope(type: type, data: data, id: id, src: engine.nodeId, dst: me.nodeId);

  /// Runs the engine side of the hello/proof exchange.
  Future<void> completeHandshake(PeerHandshake engineSide) async {
    await until(() => transport.sentOn('control').any((Envelope e) => e.type == 'peer.hello'));
    final Envelope myHello = transport.sentOn('control').firstWhere((Envelope e) => e.type == 'peer.hello');
    transport.deliver('control', fromEngine('peer.hello', engineSide.hello()));
    final Map<String, dynamic> proof = await engineSide.receiveHello(myHello.data);
    transport.deliver('control', fromEngine('peer.proof', proof));
  }
}

void main() {
  test('dials, verifies the answer and authenticates the channel', () async {
    final Harness h = await Harness.create();
    final Future<PeerLink> connecting = h.connector.connect(h.engine.nodeId);
    final SentSignal offer = await h.offer();

    // The offer is signed with our key over the exact SDP.
    expect(offer.to, h.engine.nodeId);
    expect(
      await verifySignature(
        publicKey: h.me.publicKey,
        signature: offer.sig!,
        message: await sdpMessage(offer.sid, h.me.nodeId, h.engine.nodeId, offer.body['sdp'] as String),
      ),
      isTrue,
    );

    await h.connector.handleSignal(await h.signedAnswer(offer));
    await until(() => h.transport.remoteAnswer != null);
    h.transport.openControl();

    // Frames before both hellos verified never reach the application.
    h.transport.deliver('events', h.fromEngine('chat.delta', <String, dynamic>{'delta': 'early'}));
    h.transport.deliver('control', h.fromEngine('chat.delta', <String, dynamic>{'delta': 'early'}));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await h.completeHandshake(h.engineHandshake(offer));
    final PeerLink link = await connecting;
    expect(link.remoteNodeId, h.engine.nodeId);
    expect(link.tier, 'direct');

    final List<InboundEnvelope> got = <InboundEnvelope>[];
    link.envelopes.listen(got.add);
    h.transport.deliver('events', h.fromEngine('chat.delta', <String, dynamic>{'delta': 'ok'}));
    // Spoofed src and handshake frames after auth are ignored.
    h.transport.deliver('events', Envelope(type: 'chat.delta', src: 'n_evil', dst: h.me.nodeId, data: <String, dynamic>{}));
    h.transport.deliver('control', h.fromEngine('peer.hello', <String, dynamic>{}));
    await until(() => got.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(got, hasLength(1));
    expect(got.single.channel, 'events');
    expect(got.single.envelope.dataMap!['delta'], 'ok');

    // Outbound frames carry src and dst.
    await link.send('control', const Envelope(type: 'client.hello', id: 'a', data: <String, dynamic>{}));
    final Envelope sent = h.transport.sentOn('control').last;
    expect(sent.type, 'client.hello');
    expect(sent.src, h.me.nodeId);
    expect(sent.dst, h.engine.nodeId);
    expect(h.connector.linkFor(h.engine.nodeId), same(link));
    await h.connector.close();
  });

  test('large outbound messages are chunked on the channel', () async {
    final Harness h = await Harness.create();
    final Future<PeerLink> connecting = h.connector.connect(h.engine.nodeId);
    final SentSignal offer = await h.offer();
    await h.connector.handleSignal(await h.signedAnswer(offer));
    await until(() => h.transport.remoteAnswer != null);
    h.transport.openControl();
    await h.completeHandshake(h.engineHandshake(offer));
    final PeerLink link = await connecting;
    await link.send('rpc', Envelope(type: 'x', data: <String, dynamic>{'p': 'a' * 50000}));
    final List<ChannelMessage> rpc = h.transport.sent.where((ChannelMessage m) => m.channel == 'rpc').toList();
    expect(rpc.length, greaterThan(3));
    expect(h.transport.sentOn('rpc').single.dataMap!['p'], hasLength(50000));
    await h.connector.close();
  });

  test('an answer signed by the wrong key is dropped before any action', () async {
    final Harness h = await Harness.create(timeout: const Duration(milliseconds: 200));
    final Future<PeerLink> connecting = h.connector.connect(h.engine.nodeId);
    final Future<void> expectation = expectLater(connecting, throwsA(isA<PeerConnectException>()));
    final SentSignal offer = await h.offer();
    final NodeIdentity attacker = await seededIdentity(100);
    await h.connector.handleSignal(await h.signedAnswer(offer, signer: attacker));
    await expectation;
    expect(h.transport.remoteAnswer, isNull);
    expect(h.transport.wasClosed, isTrue);
  });

  test('a stale answer is rejected by the freshness window', () async {
    final Harness h = await Harness.create(timeout: const Duration(milliseconds: 200));
    final Future<PeerLink> connecting = h.connector.connect(h.engine.nodeId);
    final Future<void> expectation = expectLater(connecting, throwsA(isA<PeerConnectException>()));
    final SentSignal offer = await h.offer();
    h.now = h.now.add(const Duration(minutes: 5));
    await h.connector.handleSignal(await h.signedAnswer(offer));
    await expectation;
    expect(h.transport.remoteAnswer, isNull);
  });

  test('answers for another sid or from another sender are ignored', () async {
    final Harness h = await Harness.create(timeout: const Duration(milliseconds: 200));
    final Future<PeerLink> connecting = h.connector.connect(h.engine.nodeId);
    final Future<void> expectation = expectLater(connecting, throwsA(isA<PeerConnectException>()));
    final SentSignal offer = await h.offer();
    await h.connector.handleSignal(await h.signedAnswer(offer, sid: '${h.now.millisecondsSinceEpoch ~/ 1000}.other'));
    await h.connector.handleSignal(await h.signedAnswer(offer, from: 'n_someoneelse'));
    await expectation;
    expect(h.transport.remoteAnswer, isNull);
  });

  test('a failed channel binding tears the link down', () async {
    final Harness h = await Harness.create();
    final Future<PeerLink> connecting = h.connector.connect(h.engine.nodeId);
    final Future<void> expectation = expectLater(connecting, throwsA(isA<PeerConnectException>()));
    final SentSignal offer = await h.offer();
    await h.connector.handleSignal(await h.signedAnswer(offer));
    await until(() => h.transport.remoteAnswer != null);
    h.transport.openControl();
    // The "engine" signed over a different answer fingerprint than we saw.
    await h.completeHandshake(
      h.engineHandshake(offer, answererFingerprint: 'sha-256 DE:AD'),
    );
    await expectation;
    expect(h.transport.wasClosed, isTrue);
    expect(h.connector.linkFor(h.engine.nodeId), isNull);
  });

  test('refuses to dial a node that is not trusted', () async {
    final Harness h = await Harness.create();
    final NodeIdentity stranger = await seededIdentity(100);
    expect(
      h.connector.connect(stranger.nodeId),
      throwsA(isA<PeerConnectException>()),
    );
    expect(h.factory.created, isEmpty);
  });

  test('local ICE candidates are relayed after the offer, remote ones applied', () async {
    final Harness h = await Harness.create();
    final Future<PeerLink> connecting = h.connector.connect(h.engine.nodeId);
    unawaited(connecting.then<void>((_) {}, onError: (Object _) {}));
    final SentSignal offer = await h.offer();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    h.transport.candidates.add(<String, dynamic>{
      'candidate': 'candidate:1 1 udp 1 1.2.3.4 5 typ host',
      'sdpMid': '0',
      'sdpMLineIndex': 0,
    });
    await until(() => h.signaler.signals.any((SentSignal s) => s.kind == 'candidate'));
    await h.connector.handleSignal(<String, dynamic>{
      'from': h.engine.nodeId,
      'sid': offer.sid,
      'kind': 'candidate',
      'body': <String, dynamic>{'candidate': 'candidate:2 1 udp 1 5.6.7.8 9 typ host', 'sdpMid': '0', 'sdpMLineIndex': 0},
    });
    await h.connector.handleSignal(<String, dynamic>{
      'from': h.engine.nodeId,
      'sid': offer.sid,
      'kind': 'candidate',
      'body': <String, dynamic>{'candidate': 'javascript:evil'},
    });
    expect(h.transport.remoteCandidates, hasLength(1));
    await h.connector.close();
  });

  test('newSid embeds a parseable timestamp', () {
    final DateTime now = DateTime.utc(2025, 1, 1);
    final String sid = newSid(now, Random(3));
    expect(sidTimestamp(sid), now);
    expect(sidTimestamp('x.y'), isNull);
    expect(sidTimestamp(5), isNull);
  });
}
