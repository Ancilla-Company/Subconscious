import 'dart:math';

import 'encoding.dart';
import 'identity.dart';

final class HandshakeException implements Exception {
  const HandshakeException(this.message);
  final String message;
  @override
  String toString() => 'HandshakeException: $message';
}

final RegExp _fingerprint = RegExp(
  r'^a=fingerprint:([A-Za-z0-9-]+)\s+((?:[0-9A-Fa-f]{2}:)*[0-9A-Fa-f]{2})\s*$',
  multiLine: true,
);

/// Returns `"<alg> <HEX:..>"` (lower-case alg, upper-case hex), exactly as the
/// engine does, so both sides sign identical text.
String extractFingerprint(String sdp) {
  final Set<String> matches = <String>{
    for (final RegExpMatch m in _fingerprint.allMatches(sdp))
      '${m.group(1)!.toLowerCase()} ${m.group(2)!.toUpperCase()}',
  };
  if (matches.length != 1) {
    throw const HandshakeException(
      'The description must carry exactly one DTLS fingerprint.',
    );
  }
  return matches.single;
}

/// Channel binding over the `control` channel (webrtc.md 5.2).
///
/// Each side sends `peer.hello {node_id, nonce}`; after receiving the other
/// hello it answers `peer.proof {sig}` over both fingerprints and nonces. The
/// link is authenticated only after the remote proof verifies AND our own
/// proof was sent, i.e. both hellos were processed.
final class PeerHandshake {
  PeerHandshake({
    required this.identity,
    required this.remoteNodeId,
    required this.remotePublicKey,
    required this.offererFingerprint,
    required this.answererFingerprint,
    required this.isOfferer,
    Random? random,
  }) : nonce = _newNonce(random ?? Random.secure());

  static String _newNonce(Random rng) =>
      b64uEncode(List<int>.generate(16, (int _) => rng.nextInt(256)));

  final NodeIdentity identity;
  final String remoteNodeId;
  final List<int> remotePublicKey;
  final String offererFingerprint;
  final String answererFingerprint;
  final bool isOfferer;
  final String nonce;
  String? _remoteNonce;
  bool _proofSent = false;
  bool _remoteVerified = false;

  bool get authenticated => _remoteVerified && _proofSent;

  Map<String, dynamic> hello() => <String, dynamic>{
    'node_id': identity.nodeId,
    'nonce': nonce,
  };

  /// Validates the remote hello and returns the `peer.proof` payload.
  Future<Map<String, dynamic>> receiveHello(Object? data) async {
    if (data is! Map || _remoteNonce != null) {
      throw const HandshakeException('Unexpected hello.');
    }
    final Object? nodeId = data['node_id'];
    final Object? remoteNonce = data['nonce'];
    if (nodeId is! String || !nodeIdsEqual(nodeId, remoteNodeId)) {
      throw const HandshakeException('Hello came from an unexpected node.');
    }
    if (remoteNonce is! String ||
        remoteNonce.length < 8 ||
        remoteNonce.length > 64) {
      throw const HandshakeException('Hello nonce is invalid.');
    }
    if (remoteNonce == nonce) throw const HandshakeException('Reflected nonce.');
    _remoteNonce = remoteNonce;
    final String sig = await identity.sign(_message());
    _proofSent = true;
    return <String, dynamic>{'sig': sig};
  }

  Future<void> receiveProof(Object? data) async {
    if (_remoteNonce == null) {
      throw const HandshakeException('Proof arrived before hello.');
    }
    final Object? sig = data is Map ? data['sig'] : null;
    if (sig is! String ||
        !await verifySignature(
          publicKey: remotePublicKey,
          signature: sig,
          message: _message(),
        )) {
      throw const HandshakeException('Channel binding failed.');
    }
    _remoteVerified = true;
  }

  String _message() {
    final String remote = _remoteNonce!;
    return helloMessage(
      offererFingerprint,
      answererFingerprint,
      isOfferer ? nonce : remote,
      isOfferer ? remote : nonce,
    );
  }
}
