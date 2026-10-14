import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Base64url without padding (webrtc.md Appendix A).
String b64uEncode(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Decodes base64url with or without padding; throws [FormatException].
Uint8List b64uDecode(String text) {
  if (text.isEmpty || text.codeUnits.any((int c) => c > 127)) {
    throw const FormatException('Invalid base64url value.');
  }
  final String padded = text + '=' * ((4 - text.length % 4) % 4);
  return Uint8List.fromList(base64Url.decode(padded));
}

Future<Uint8List> sha256Bytes(List<int> data) async =>
    Uint8List.fromList((await Sha256().hash(data)).bytes);

String hexOf(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

Future<String> sha256Hex(String value) async =>
    hexOf(await sha256Bytes(utf8.encode(value)));

const String _base32Alphabet = 'abcdefghijklmnopqrstuvwxyz234567';

/// Lowercase RFC 4648 base32 without padding.
String base32LowerNoPad(List<int> bytes) {
  final StringBuffer out = StringBuffer();
  int buffer = 0;
  int bits = 0;
  for (final int byte in bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out.write(_base32Alphabet[(buffer >> (bits - 5)) & 31]);
      bits -= 5;
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(_base32Alphabet[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

/// `n_` + base32(first 16 bytes of SHA-256(raw public key)).
Future<String> deriveNodeId(List<int> publicKey) async =>
    'n_${base32LowerNoPad((await sha256Bytes(publicKey)).sublist(0, 16))}';

bool nodeIdsEqual(String a, String b) => a.toLowerCase() == b.toLowerCase();
