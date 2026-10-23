import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:http/http.dart' as http;

import 'extension_host.dart';

const String _sameAccount =
    'Sign this engine in to the same account in the desktop app, then retry.';

/// A pairing step failed; [message] is ready to show to the user.
final class PairingException implements Exception {
  const PairingException(this.message, [this.statusCode]);
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

/// A local engine that answered `GET /api/v1/health`.
final class FoundEngine {
  const FoundEngine({required this.url, required this.nodeId});
  final Uri url;

  /// The hive node id, or null before the engine is signed in.
  final String? nodeId;
}

/// Asks the server for a pairing assertion (bearer = the signed-in account).
typedef PairingAssertionRequester = Future<String> Function({
  required String nodeId,
  required String clientNonce,
  required String origin,
});

/// Pairs this browser extension with a local engine through the account:
/// engine health -> server assertion -> engine `/api/v1/pair` -> stored token.
/// contracts.md section 3.
final class ExtensionPairing {
  ExtensionPairing({
    required http.Client client,
    required this.requestAssertion,
    ExtensionHost? host,
    this.preferDev = false,
    this.probeTimeout = const Duration(seconds: 2),
    this.pairTimeout = const Duration(seconds: 20),
    Random? random,
  }) : _client = client,
       host = host ?? ExtensionHost.instance,
       _random = random ?? Random.secure();

  final http.Client _client;
  final PairingAssertionRequester requestAssertion;
  final ExtensionHost host;
  final bool preferDev;
  final Duration probeTimeout;
  final Duration pairTimeout;
  final Random _random;

  static const String productionEngine = 'http://127.0.0.1:51516';
  static const String developmentEngine = 'http://127.0.0.1:51515';

  /// Engines to try, in order: production then development, or the reverse
  /// when the app is a development build.
  List<Uri> get candidates => <Uri>[
    for (final String url
        in preferDev
            ? const <String>[developmentEngine, productionEngine]
            : const <String>[productionEngine, developmentEngine])
      Uri.parse(url),
  ];

  /// 32 random bytes, base64url without padding (43 chars).
  String newNonce() =>
      b64uEncode(List<int>.generate(32, (int _) => _random.nextInt(256)));

  /// The first reachable local engine, or null.
  Future<FoundEngine?> findEngine() async {
    for (final Uri url in candidates) {
      final FoundEngine? engine = await probe(url);
      if (engine != null) return engine;
    }
    return null;
  }

  /// Reads the public health of the engine at [url]. Never throws.
  Future<FoundEngine?> probe(Uri url) async {
    try {
      final http.Response response = await _client
          .get(url.resolve('/api/v1/health'))
          .timeout(probeTimeout);
      if (response.statusCode != 200) return null;
      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map) return null;
      final Object? nodeId = decoded['node_id'];
      return FoundEngine(
        url: url,
        nodeId: nodeId is String && nodeId.isNotEmpty ? nodeId : null,
      );
    } on Object {
      return null;
    }
  }

  /// Runs the exchange and stores the token with the host. Throws
  /// [PairingException] with a plain-language message.
  Future<ExtensionConnection> pair(
    FoundEngine engine, {
    String? serverUrl,
    String? environment,
  }) async {
    final String? nodeId = engine.nodeId;
    if (nodeId == null) {
      throw const PairingException(
        'This engine is not linked to an account yet. $_sameAccount',
        409,
      );
    }
    final String origin = host.extensionOrigin;
    final String nonce = newNonce();
    final String assertion;
    try {
      assertion = await requestAssertion(
        nodeId: nodeId,
        clientNonce: nonce,
        origin: origin,
      );
    } on HiveApiException catch (error) {
      throw PairingException(_assertionMessage(error), error.statusCode);
    }
    final http.Response response;
    try {
      response = await _client
          .post(
            engine.url.resolve('/api/v1/pair'),
            headers: const <String, String>{
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(<String, dynamic>{
              'assertion': assertion,
              'client_nonce': nonce,
            }),
          )
          .timeout(pairTimeout);
    } on Object {
      throw const PairingException(
        'No engine found. Start the Subconscious desktop app, then retry.',
        0,
      );
    }
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw PairingException(
        _engineMessage(response.statusCode, response.body),
        response.statusCode,
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const PairingException('The engine returned an invalid answer.');
    }
    final Object? token = decoded is Map ? decoded['token'] : null;
    if (token is! String || token.isEmpty) {
      throw const PairingException('The engine did not return a client token.');
    }
    final Map<dynamic, dynamic> body = decoded! as Map;
    final ExtensionConnection connection = ExtensionConnection(
      engineUrl: engine.url.toString(),
      engineToken: token,
      clientId: body['client_id'] is String ? body['client_id'] as String : '',
      expiresAt: body['expires_at']?.toString(),
      serverUrl: serverUrl,
      environment: environment,
    );
    await host.setConnection(connection);
    return connection;
  }

  /// Revokes nothing on the engine (that needs the master token); forgets the
  /// stored pairing on this browser.
  Future<void> unpair() => host.clearConnection();

  static String _assertionMessage(HiveApiException error) {
    switch (error.statusCode) {
      case 404:
        return 'This engine is not registered to your account. $_sameAccount';
      case 403:
        return 'This engine was removed from your account. Sign it in again '
            'in the desktop app.';
      case 429:
        return 'Too many pairing attempts. Wait a minute, then retry.';
      case 401:
        return 'Your session expired. Sign in again.';
    }
    return error.message;
  }

  static String _engineMessage(int status, String body) => switch (status) {
    401 => _sameAccount,
    403 =>
      'The engine refused this extension. Update the desktop app, then retry.',
    404 => 'The pairing code expired or was already used. Retry.',
    429 => 'Too many pairing attempts. Wait a minute, then retry.',
    503 =>
      'The engine could not reach the Subconscious server. Check your '
          'connection, then retry.',
    _ => 'Pairing failed (status $status).',
  };
}
