import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'encoding.dart';

/// Ed25519 node identity (webrtc.md 5.4). Only the 32 byte seed is persisted.
final class NodeIdentity {
  NodeIdentity._(this._keyPair, this.publicKey, this.nodeId);

  final SimpleKeyPair _keyPair;
  final Uint8List publicKey;
  final String nodeId;

  String get publicKeyB64u => b64uEncode(publicKey);

  static final Ed25519 _algorithm = Ed25519();

  static Future<NodeIdentity> generate() async {
    final SimpleKeyPair pair = await _algorithm.newKeyPair();
    return _fromPair(pair);
  }

  static Future<NodeIdentity> fromSeed(List<int> seed) async {
    if (seed.length != 32) {
      throw const FormatException('The node identity seed must be 32 bytes.');
    }
    return _fromPair(await _algorithm.newKeyPairFromSeed(seed));
  }

  static Future<NodeIdentity> _fromPair(SimpleKeyPair pair) async {
    final SimplePublicKey key = await pair.extractPublicKey();
    final Uint8List bytes = Uint8List.fromList(key.bytes);
    return NodeIdentity._(pair, bytes, await deriveNodeId(bytes));
  }

  Future<Uint8List> seed() async =>
      Uint8List.fromList(await _keyPair.extractPrivateKeyBytes());

  /// Signs the UTF-8 [message]; returns base64url without padding.
  Future<String> sign(String message) async {
    final Signature signature = await _algorithm.sign(
      utf8.encode(message),
      keyPair: _keyPair,
    );
    return b64uEncode(signature.bytes);
  }

  /// Signs raw [message] bytes (used where the signed text embeds binary
  /// data, e.g. the relay transcript).
  Future<Uint8List> signBytes(List<int> message) async {
    final Signature signature = await _algorithm.sign(
      message,
      keyPair: _keyPair,
    );
    return Uint8List.fromList(signature.bytes);
  }

  @override
  String toString() => 'NodeIdentity($nodeId)';
}

/// Verifies an Ed25519 signature over raw bytes; malformed input is `false`.
Future<bool> verifySignatureBytes({
  required List<int> publicKey,
  required List<int> signature,
  required List<int> message,
}) async {
  try {
    if (publicKey.length != 32 || signature.length != 64) return false;
    return await Ed25519().verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
  } on Object {
    return false;
  }
}

/// Verifies an Ed25519 signature; malformed input is simply `false`.
Future<bool> verifySignature({
  required List<int> publicKey,
  required String signature,
  required String message,
}) async {
  try {
    if (publicKey.length != 32) return false;
    final Uint8List sig = b64uDecode(signature);
    if (sig.length != 64) return false;
    return await Ed25519().verify(
      utf8.encode(message),
      signature: Signature(
        sig,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
  } on Object {
    return false;
  }
}

// --- signing contexts (webrtc.md Appendix A) --------------------------------

String registerMessage(String userId, String publicKeyB64u) =>
    'sc-register-v1\n$userId\n$publicKeyB64u';

Future<String> signalAuthMessage(
  String challenge,
  String ticket,
  String nodeId,
) async => 'sc-signal-v1\n$challenge\n${await sha256Hex(ticket)}\n$nodeId';

Future<String> sdpMessage(
  String sid,
  String from,
  String to,
  String sdp,
) async => 'sc-sdp-v1\n$sid\n$from\n$to\n${await sha256Hex(sdp)}';

String approvalMessage(String userId, String newPublicKeyB64u) =>
    'sc-approve-v1\n$userId\n$newPublicKeyB64u';

/// Fingerprints and nonces are ordered (offerer, answerer).
String helloMessage(
  String offererFingerprint,
  String answererFingerprint,
  String offererNonce,
  String answererNonce,
) =>
    'sc-hello-v1\n$offererFingerprint\n$answererFingerprint\n'
    '$offererNonce\n$answererNonce';

/// Six digit string both users compare on screen.
///
/// Matches the engine (`identity.short_authentication_string`): SHA-256 over
/// `sc-sas-v1\n` plus the two raw public keys sorted lexicographically, first
/// four bytes big-endian, mod 1,000,000.
Future<String> shortAuthenticationString(List<int> keyA, List<int> keyB) async {
  final List<int> first = _compareBytes(keyA, keyB) <= 0 ? keyA : keyB;
  final List<int> second = identical(first, keyA) ? keyB : keyA;
  final Uint8List digest = await sha256Bytes(<int>[
    ...utf8.encode('sc-sas-v1\n'),
    ...first,
    ...second,
  ]);
  final int value =
      digest[0] * 16777216 + digest[1] * 65536 + digest[2] * 256 + digest[3];
  return (value % 1000000).toString().padLeft(6, '0');
}

int _compareBytes(List<int> a, List<int> b) {
  final int length = a.length < b.length ? a.length : b.length;
  for (int i = 0; i < length; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}
