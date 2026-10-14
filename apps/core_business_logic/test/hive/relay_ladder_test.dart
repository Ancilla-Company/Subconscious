import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:test/test.dart';

import 'fakes.dart';
import 'peer_connector_test.dart' show Harness, until;

final class _CaptureSender implements RelaySender {
  final List<(String sid, String to, Uint8List bytes)> sent =
      <(String, String, Uint8List)>[];
  @override
  Future<void> sendRelay({
    required String sid,
    required String to,
    required Object payload,
  }) async => sent.add((sid, to, b64uDecode(payload as String)));
}

/// Builds a connector with the relay fallback on top of the shared harness.
Future<(Harness, RelayManager, _CaptureSender, Completer<void>)> ladder({
  bool relayAllowed = true,
}) async {
  final Harness h = await Harness.create();
  final _CaptureSender sender = _CaptureSender();
  final RelayManager relay = RelayManager(
    identity: h.me,
    directory: h.directory,
    sender: sender,
  );
  final Completer<void> upgradeGate = Completer<void>();
  h.connector = PeerConnector(
    identity: h.me,
    directory: h.directory,
    signaler: h.signaler,
    transportFactory: h.factory,
    iceProvider: () async => const <Map<String, dynamic>>[],
    clock: () => h.now,
    random: Random(1),
    relay: relay,
    relayEnabled: () async => relayAllowed,
    directTimeout: const Duration(milliseconds: 60),
    sleep: (Duration _) => upgradeGate.future,
  );
  return (h, relay, sender, upgradeGate);
}

/// Plays the engine side of a relay handshake against [relay].
Future<RelayResponder> answerRelay(
  Harness h,
  RelayManager relay,
  _CaptureSender sender,
) async {
  await until(() => sender.sent.isNotEmpty);
  final (String sid, String _, Uint8List m1) = sender.sent.first;
  final RelayResponder responder = RelayResponder(
    identity: h.engine,
    remoteNodeId: h.me.nodeId,
    remotePublicKey: h.me.publicKey,
    sid: sid,
  );
  final Uint8List m2 = await responder.receiveM1(m1);
  await relay.handleRelay(<String, dynamic>{
    'from': h.engine.nodeId,
    'sid': sid,
    'payload': b64uEncode(m2),
  });
  return responder;
}

void main() {
  test('falls back to the relay after the direct attempt times out', () async {
    final (Harness h, RelayManager relay, _CaptureSender sender, Completer<void> _) =
        await ladder();
    final Future<PeerLink> connecting = h.connector.connect(h.engine.nodeId);
    await h.offer(); // the direct attempt starts first
    await answerRelay(h, relay, sender);
    final PeerLink link = await connecting;
    expect(link.tier, 'ws-relay');
    expect(link.remoteNodeId, h.engine.nodeId);
    expect(h.connector.linkFor(h.engine.nodeId)!.tier, 'ws-relay');
    expect(h.transport.wasClosed, isTrue, reason: 'the failed direct attempt was torn down');
    await h.connector.close();
  });

  test('does not use the relay when ice-config does not enable it', () async {
    final (Harness h, RelayManager _, _CaptureSender sender, Completer<void> _) =
        await ladder(relayAllowed: false);
    await expectLater(
      h.connector.connect(h.engine.nodeId),
      throwsA(isA<PeerConnectException>()),
    );
    expect(sender.sent, isEmpty);
    await h.connector.close();
  });

  test('a direct success never touches the relay', () async {
    final (Harness h, RelayManager relay, _CaptureSender sender, Completer<void> _) =
        await ladder();
    final Future<PeerLink> connecting = h.connector.connect(h.engine.nodeId);
    final SentSignal offer = await h.offer();
    final PeerHandshake engineSide = h.engineHandshake(offer);
    await h.connector.handleSignal(await h.signedAnswer(offer));
    h.transport.openControl();
    await h.completeHandshake(engineSide);
    final PeerLink link = await connecting;
    expect(link.tier, 'direct');
    expect(sender.sent, isEmpty);
    expect(relay.linkFor(h.engine.nodeId), isNull);
    await h.connector.close();
  });

  test('upgrades a relay link to direct in the background and swaps transparently', () async {
    final (Harness h, RelayManager relay, _CaptureSender sender, Completer<void> gate) =
        await ladder();
    final Future<PeerLink> connecting = h.connector.connect(h.engine.nodeId);
    await answerRelay(h, relay, sender);
    final PeerLink link = await connecting;
    expect(link.tier, 'ws-relay');

    final List<InboundEnvelope> seen = <InboundEnvelope>[];
    link.envelopes.listen(seen.add);

    gate.complete(); // the background upgrade timer fires
    final SentSignal offer = await h.offer(nth: 2);
    final PeerHandshake engineSide = h.engineHandshake(offer);
    await h.connector.handleSignal(await h.signedAnswer(offer));
    h.transport.openControl();
    await h.completeHandshake(engineSide);
    await until(() => link.tier == 'direct');

    // The same object the caller holds now sends over the direct transport
    // and receives from it.
    await link.send('rpc', const Envelope(type: 'http.request', id: 'r1'));
    expect(
      h.transport.sentOn('rpc').single.id,
      'r1',
    );
    h.transport.deliver('rpc', h.fromEngine('http.response', <String, dynamic>{'status': 200}, id: 'r1'));
    await until(() => seen.any((InboundEnvelope e) => e.envelope.type == 'http.response'));
    expect(h.connector.linkFor(h.engine.nodeId), same(link));
    await h.connector.close();
  });

  test('an inbound relay handshake from the peer becomes the node link', () async {
    final (Harness h, RelayManager relay, _CaptureSender sender, Completer<void> _) =
        await ladder();
    final Future<PeerLink> opened = h.connector.linkOpened.first;
    final RelayInitiator initiator = RelayInitiator(
      identity: h.engine,
      remoteNodeId: h.me.nodeId,
      remotePublicKey: h.me.publicKey,
      sid: '1735732800.inbound',
    );
    final Uint8List m1 = await initiator.start();
    await h.connector.handleRelay(<String, dynamic>{
      'from': h.engine.nodeId,
      'sid': '1735732800.inbound',
      'payload': b64uEncode(m1),
    });
    await until(() => sender.sent.isNotEmpty);
    final result = await initiator.receiveM2(sender.sent.first.$3);
    await h.connector.handleRelay(<String, dynamic>{
      'from': h.engine.nodeId,
      'sid': '1735732800.inbound',
      'payload': b64uEncode(result.m3),
    });
    final PeerLink link = await opened;
    expect(link.tier, 'ws-relay');
    expect(h.connector.linkFor(h.engine.nodeId), same(link));
    await h.connector.close();
  });
}
