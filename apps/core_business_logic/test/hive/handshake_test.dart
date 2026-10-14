import 'package:core_business_logic/core_business_logic.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  const String offerFp = 'sha-256 AA:BB';
  const String answerFp = 'sha-256 CC:DD';

  Future<(PeerHandshake, PeerHandshake)> pair() async {
    final NodeIdentity a = await seededIdentity(1);
    final NodeIdentity b = await seededIdentity(40);
    return (
      PeerHandshake(
        identity: a,
        remoteNodeId: b.nodeId,
        remotePublicKey: b.publicKey,
        offererFingerprint: offerFp,
        answererFingerprint: answerFp,
        isOfferer: true,
      ),
      PeerHandshake(
        identity: b,
        remoteNodeId: a.nodeId,
        remotePublicKey: a.publicKey,
        offererFingerprint: offerFp,
        answererFingerprint: answerFp,
        isOfferer: false,
      ),
    );
  }

  test('extracts one normalised fingerprint', () {
    expect(
      extractFingerprint('a=fingerprint:SHA-256 ab:cd\r\nm=application'),
      'sha-256 AB:CD',
    );
    expect(() => extractFingerprint('v=0'), throwsA(isA<HandshakeException>()));
    expect(
      () => extractFingerprint(
        'a=fingerprint:sha-256 AA:BB\r\na=fingerprint:sha-256 CC:DD\r\n',
      ),
      throwsA(isA<HandshakeException>()),
    );
  });

  test('both sides authenticate only after hello and proof', () async {
    final (PeerHandshake o, PeerHandshake a) = await pair();
    expect(o.authenticated, isFalse);
    final Map<String, dynamic> proofFromA = await a.receiveHello(o.hello());
    final Map<String, dynamic> proofFromO = await o.receiveHello(a.hello());
    expect(o.authenticated, isFalse);
    await o.receiveProof(proofFromA);
    await a.receiveProof(proofFromO);
    expect(o.authenticated, isTrue);
    expect(a.authenticated, isTrue);
  });

  test('a proof that arrives before the hello is refused', () async {
    final (PeerHandshake o, PeerHandshake _) = await pair();
    expect(
      () => o.receiveProof(<String, dynamic>{'sig': 'x'}),
      throwsA(isA<HandshakeException>()),
    );
  });

  test('wrong fingerprints break channel binding (MITM)', () async {
    final (PeerHandshake o, PeerHandshake _) = await pair();
    final NodeIdentity b = await seededIdentity(40);
    final NodeIdentity a = await seededIdentity(1);
    // A middlebox terminates DTLS with its own fingerprint on the answerer leg.
    final PeerHandshake mitmAnswerer = PeerHandshake(
      identity: b,
      remoteNodeId: a.nodeId,
      remotePublicKey: a.publicKey,
      offererFingerprint: offerFp,
      answererFingerprint: 'sha-256 EE:EE',
      isOfferer: false,
    );
    final Map<String, dynamic> proof = await mitmAnswerer.receiveHello(o.hello());
    await o.receiveHello(mitmAnswerer.hello());
    expect(() => o.receiveProof(proof), throwsA(isA<HandshakeException>()));
    expect(o.authenticated, isFalse);
  });

  test('hello from an unexpected node, reflected or bad nonce is refused', () async {
    final (PeerHandshake o, PeerHandshake _) = await pair();
    expect(
      () => o.receiveHello(<String, dynamic>{'node_id': 'n_other', 'nonce': 'abcdefgh12'}),
      throwsA(isA<HandshakeException>()),
    );
    final NodeIdentity b = await seededIdentity(40);
    expect(
      () => o.receiveHello(<String, dynamic>{'node_id': b.nodeId, 'nonce': 'short'}),
      throwsA(isA<HandshakeException>()),
    );
    expect(
      () => o.receiveHello(<String, dynamic>{'node_id': b.nodeId, 'nonce': o.nonce}),
      throwsA(isA<HandshakeException>()),
    );
    expect(() => o.receiveHello('nope'), throwsA(isA<HandshakeException>()));
  });

  test('a second hello is refused', () async {
    final (PeerHandshake o, PeerHandshake a) = await pair();
    await o.receiveHello(a.hello());
    expect(() => o.receiveHello(a.hello()), throwsA(isA<HandshakeException>()));
  });
}
