import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'encoding.dart';
import 'identity.dart';

/// Signalling socket relay cryptography (webrtc.md Appendix B).
///
/// Handshake: SIGMA style. X25519 ephemeral exchange, Ed25519 signatures over
/// the transcript `T`, HKDF-SHA256 key schedule, ChaCha20-Poly1305 records.
/// Only primitives from the `cryptography` package are used.

/// Raw (pre base64) message limit so the encoded payload fits the server cap.
const int relayRawLimit = 24 * 1024;
const int relayTagBytes = 16;
const int relayMsgM1 = 0x01;
const int relayMsgM2 = 0x02;
const int relayMsgM3 = 0x03;
const int relayMsgData = 0x10;
const int relayMsgClose = 0x20;

/// A counter must stay below 2^32 per key.
const int relayMaxCounter = 4294967295;

final class RelayException implements Exception {
  const RelayException(this.message);
  final String message;
  @override
  String toString() => 'RelayException: $message';
}

/// `T = "sc-relay-v1\n" + sid + "\n" + I + "\n" + R + "\n" + eph_i + nonce_i + eph_r + nonce_r`
Uint8List relayTranscript({
  required String sid,
  required String initiatorId,
  required String responderId,
  required List<int> ephI,
  required List<int> nonceI,
  required List<int> ephR,
  required List<int> nonceR,
}) => Uint8List.fromList(<int>[
  ...utf8.encode('sc-relay-v1\n$sid\n$initiatorId\n$responderId\n'),
  ...ephI,
  ...nonceI,
  ...ephR,
  ...nonceR,
]);

Uint8List relayResponderSignedBytes(List<int> transcript) =>
    Uint8List.fromList(<int>[...utf8.encode('sc-relay-resp-v1\n'), ...transcript]);

Uint8List relayInitiatorSignedBytes(List<int> transcript) =>
    Uint8List.fromList(<int>[...utf8.encode('sc-relay-init-v1\n'), ...transcript]);

/// Directional keys and the AAD for one relay session.
final class RelayKeys {
  const RelayKeys({
    required this.initiatorToResponder,
    required this.responderToInitiator,
    required this.aad,
  });
  final Uint8List initiatorToResponder;
  final Uint8List responderToInitiator;

  /// `SHA-256(T)`: also the HKDF salt.
  final Uint8List aad;
}

/// `okm = HKDF-SHA256(ikm = shared, salt = SHA-256(T), info, 64)`.
Future<RelayKeys> deriveRelayKeys(List<int> shared, List<int> transcript) async {
  final Uint8List salt = await sha256Bytes(transcript);
  final SecretKey okm = await Hkdf(
    hmac: Hmac.sha256(),
    outputLength: 64,
  ).deriveKey(
    secretKey: SecretKey(shared),
    nonce: salt,
    info: utf8.encode('sc-relay-keys-v1'),
  );
  final List<int> bytes = await okm.extractBytes();
  return RelayKeys(
    initiatorToResponder: Uint8List.fromList(bytes.sublist(0, 32)),
    responderToInitiator: Uint8List.fromList(bytes.sublist(32, 64)),
    aad: salt,
  );
}

Uint8List relayCounterBytes(int counter) {
  final Uint8List out = Uint8List(8);
  final ByteData view = ByteData.view(out.buffer);
  view.setUint32(0, counter ~/ 4294967296);
  view.setUint32(4, counter % 4294967296);
  return out;
}

/// Returns the counter or null when it is outside `0 .. 2^32 - 1`.
int? relayParseCounter(List<int> bytes) {
  if (bytes.length != 8) return null;
  final ByteData view = ByteData.view(Uint8List.fromList(bytes).buffer);
  if (view.getUint32(0) != 0) return null;
  return view.getUint32(4);
}

final Chacha20 _aead = Chacha20.poly1305Aead();

Uint8List _nonce(Uint8List counterBytes) =>
    Uint8List.fromList(<int>[0, 0, 0, 0, ...counterBytes]);

/// `0x10 | counter | ciphertext | tag`.
Future<Uint8List> relaySeal({
  required List<int> key,
  required int counter,
  required List<int> aad,
  required List<int> plaintext,
  int type = relayMsgData,
}) async {
  if (counter < 0 || counter > relayMaxCounter) {
    throw const RelayException('Relay counter exhausted.');
  }
  final Uint8List counterBytes = relayCounterBytes(counter);
  final SecretBox box = await _aead.encrypt(
    plaintext,
    secretKey: SecretKey(key),
    nonce: _nonce(counterBytes),
    aad: aad,
  );
  return Uint8List.fromList(<int>[
    type,
    ...counterBytes,
    ...box.cipherText,
    ...box.mac.bytes,
  ]);
}

/// Decrypts the body of a record (everything after the type byte). Returns
/// null on authentication failure.
Future<Uint8List?> relayOpen({
  required List<int> key,
  required List<int> record,
  required List<int> aad,
}) async {
  if (record.length < 1 + 8 + relayTagBytes) return null;
  final Uint8List counterBytes = Uint8List.fromList(record.sublist(1, 9));
  final List<int> sealed = record.sublist(9);
  try {
    final List<int> clear = await _aead.decrypt(
      SecretBox(
        sealed.sublist(0, sealed.length - relayTagBytes),
        nonce: _nonce(counterBytes),
        mac: Mac(sealed.sublist(sealed.length - relayTagBytes)),
      ),
      secretKey: SecretKey(key),
      aad: aad,
    );
    return Uint8List.fromList(clear);
  } on Object {
    return null;
  }
}

Future<Uint8List> _sharedSecret(SimpleKeyPair mine, List<int> peerPublic) async {
  if (peerPublic.length != 32) {
    throw const RelayException('Invalid ephemeral key.');
  }
  final SecretKey shared = await X25519().sharedSecretKey(
    keyPair: mine,
    remotePublicKey: SimplePublicKey(peerPublic, type: KeyPairType.x25519),
  );
  final List<int> bytes = await shared.extractBytes();
  // Reject low-order points (all-zero output).
  if (bytes.every((int b) => b == 0)) {
    throw const RelayException('Invalid ephemeral key.');
  }
  return Uint8List.fromList(bytes);
}

Uint8List _randomBytes(Random random, int length) =>
    Uint8List.fromList(List<int>.generate(length, (int _) => random.nextInt(256)));

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  int diff = 0;
  for (int i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Initiator half of the handshake.
final class RelayInitiator {
  RelayInitiator({
    required this.identity,
    required this.remoteNodeId,
    required this.remotePublicKey,
    required this.sid,
    Random? random,
    List<int>? ephemeralSeed,
    List<int>? nonce,
  }) : _random = random ?? Random.secure(),
       _seed = ephemeralSeed,
       nonceI = Uint8List.fromList(nonce ?? _randomBytes(random ?? Random.secure(), 16));

  final NodeIdentity identity;
  final String remoteNodeId;
  final List<int> remotePublicKey;
  final String sid;
  final Random _random;
  final List<int>? _seed;
  final Uint8List nonceI;
  SimpleKeyPair? _ephemeral;
  Uint8List? _ephI;

  /// M1 = `0x01 | eph_i | nonce_i`.
  Future<Uint8List> start() async {
    final List<int> seed = _seed ?? _randomBytes(_random, 32);
    final SimpleKeyPair pair = await X25519().newKeyPairFromSeed(seed);
    _ephemeral = pair;
    _ephI = Uint8List.fromList((await pair.extractPublicKey()).bytes);
    return Uint8List.fromList(<int>[relayMsgM1, ..._ephI!, ...nonceI]);
  }

  /// Verifies M2 against the pinned key; returns M3 and the session keys.
  Future<({Uint8List m3, RelayKeys keys})> receiveM2(List<int> m2) async {
    final SimpleKeyPair? pair = _ephemeral;
    final Uint8List? ephI = _ephI;
    if (pair == null || ephI == null) {
      throw const RelayException('Handshake not started.');
    }
    if (m2.length != 1 + 32 + 16 + 64 || m2[0] != relayMsgM2) {
      throw const RelayException('Malformed M2.');
    }
    final List<int> ephR = m2.sublist(1, 33);
    final List<int> nonceR = m2.sublist(33, 49);
    final List<int> sigR = m2.sublist(49, 113);
    final Uint8List transcript = relayTranscript(
      sid: sid,
      initiatorId: identity.nodeId,
      responderId: remoteNodeId,
      ephI: ephI,
      nonceI: nonceI,
      ephR: ephR,
      nonceR: nonceR,
    );
    if (!await verifySignatureBytes(
      publicKey: remotePublicKey,
      signature: sigR,
      message: relayResponderSignedBytes(transcript),
    )) {
      throw const RelayException('Responder signature invalid.');
    }
    final Uint8List shared = await _sharedSecret(pair, ephR);
    final RelayKeys keys = await deriveRelayKeys(shared, transcript);
    final Uint8List sigI = await identity.signBytes(
      relayInitiatorSignedBytes(transcript),
    );
    _ephemeral = null; // discard the ephemeral private key
    return (
      m3: Uint8List.fromList(<int>[relayMsgM3, ...sigI]),
      keys: keys,
    );
  }
}

/// Responder half of the handshake.
final class RelayResponder {
  RelayResponder({
    required this.identity,
    required this.remoteNodeId,
    required this.remotePublicKey,
    required this.sid,
    Random? random,
    List<int>? ephemeralSeed,
    List<int>? nonce,
  }) : _random = random ?? Random.secure(),
       _seed = ephemeralSeed,
       _nonceR = nonce == null ? null : Uint8List.fromList(nonce);

  final NodeIdentity identity;
  final String remoteNodeId;
  final List<int> remotePublicKey;
  final String sid;
  final Random _random;
  final List<int>? _seed;
  final Uint8List? _nonceR;
  Uint8List? _transcript;
  RelayKeys? _keys;

  /// Validates M1 and returns M2 (`0x02 | eph_r | nonce_r | sig_r`).
  Future<Uint8List> receiveM1(List<int> m1) async {
    if (_transcript != null) throw const RelayException('Duplicate M1.');
    if (m1.length != 1 + 32 + 16 || m1[0] != relayMsgM1) {
      throw const RelayException('Malformed M1.');
    }
    final List<int> ephI = m1.sublist(1, 33);
    final List<int> nonceI = m1.sublist(33, 49);
    final SimpleKeyPair pair = await X25519().newKeyPairFromSeed(
      _seed ?? _randomBytes(_random, 32),
    );
    final Uint8List ephR = Uint8List.fromList(
      (await pair.extractPublicKey()).bytes,
    );
    final Uint8List nonceR = _nonceR ?? _randomBytes(_random, 16);
    final Uint8List shared = await _sharedSecret(pair, ephI);
    final Uint8List transcript = relayTranscript(
      sid: sid,
      initiatorId: remoteNodeId,
      responderId: identity.nodeId,
      ephI: ephI,
      nonceI: nonceI,
      ephR: ephR,
      nonceR: nonceR,
    );
    final Uint8List sigR = await identity.signBytes(
      relayResponderSignedBytes(transcript),
    );
    _keys = await deriveRelayKeys(shared, transcript);
    _transcript = transcript;
    return Uint8List.fromList(<int>[relayMsgM2, ...ephR, ...nonceR, ...sigR]);
  }

  /// Verifies M3 against the pinned key; returns the session keys.
  Future<RelayKeys> receiveM3(List<int> m3) async {
    final Uint8List? transcript = _transcript;
    final RelayKeys? keys = _keys;
    if (transcript == null || keys == null) {
      throw const RelayException('M3 before M1.');
    }
    if (m3.length != 1 + 64 || m3[0] != relayMsgM3) {
      throw const RelayException('Malformed M3.');
    }
    if (!await verifySignatureBytes(
      publicKey: remotePublicKey,
      signature: m3.sublist(1),
      message: relayInitiatorSignedBytes(transcript),
    )) {
      throw const RelayException('Initiator signature invalid.');
    }
    _keys = null;
    return keys;
  }
}

/// Constant-time comparison helper, exposed for tests.
bool relayBytesEqual(List<int> a, List<int> b) => _bytesEqual(a, b);
