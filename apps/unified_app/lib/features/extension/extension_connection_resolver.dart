import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'extension_host.dart';

/// How the extension identifies itself to the engine.
ClientIdentity extensionClientIdentity(ExtensionHost host) => ClientIdentity(
  type: ClientType.browserExtension,
  name: 'Chromium extension',
  version: host.extensionVersion,
);

/// True when [url] points at this machine (`localhost`, `127.x.x.x`, `::1`).
bool isLoopbackEngineUrl(String? url) {
  final String? host = url == null ? null : Uri.tryParse(url)?.host;
  if (host == null || host.isEmpty) return false;
  final String name = host.toLowerCase();
  return name == 'localhost' ||
      name == '::1' ||
      name == '[::1]' ||
      name.startsWith('127.');
}

/// True when the extension holds a pairing with an engine on this machine.
Future<bool> hasLoopbackPairing(ExtensionHost host) async {
  if (!host.isExtension) return false;
  final ExtensionConnection? stored = await host.getConnection();
  return stored != null &&
      stored.isPaired &&
      isLoopbackEngineUrl(stored.engineUrl);
}

/// True when the paired local engine answers its public health route.
Future<bool> pairedLocalEngineReachable(
  ExtensionHost host, {
  http.Client? httpClient,
}) async {
  final ExtensionConnection? stored = await host.getConnection();
  if (stored == null ||
      !stored.isPaired ||
      !isLoopbackEngineUrl(stored.engineUrl)) {
    return false;
  }
  final http.Client client = httpClient ?? http.Client();
  try {
    final Uri health = Uri.parse(stored.engineUrl!)
        .replace(path: '/api/v1/health', queryParameters: const {});
    final http.Response response = await client
        .get(health)
        .timeout(const Duration(seconds: 3));
    return response.statusCode == 200;
  } on Object {
    return false;
  } finally {
    if (httpClient == null) client.close();
  }
}

/// Builds a repository for a paired engine connection.
EngineRepository repositoryForConnection(
  ExtensionConnection connection,
  ExtensionHost host, {
  http.Client? httpClient,
}) {
  final Uri engine = Uri.parse(connection.engineUrl!);
  final String token = connection.engineToken!;
  return EngineRepository(
    rest: RestEngineClient(
      baseUri: engine.replace(
        path: '/api/v1/',
        queryParameters: const <String, String>{},
      ),
      token: token,
      client: httpClient,
    ),
    socket: WebSocketEngineClient(
      endpoint: engine.replace(
        scheme: engine.scheme == 'https' ? 'wss' : 'ws',
        path: '/api/v1/events',
        queryParameters: <String, String>{'token': token},
      ),
      identity: extensionClientIdentity(host),
    ),
  );
}

/// Extension-mode connection order (contracts.md section 5):
///
/// 1. the paired engine token stored by the host, verified with the public
///    health route and then an authenticated call; a 401 clears the token and,
///    when [rePair] is given (a server session exists), pairs again;
/// 2. [hive]: a remote home engine through the signed-in account;
/// 3. null, so the UI shows the Account page.
///
/// Never throws.
Future<EngineRepository?> resolveExtensionRepository({
  required ExtensionHost host,
  required Future<EngineRepository?> Function() hive,
  Future<ExtensionConnection?> Function()? rePair,
  void Function()? onLocalEngine,
  http.Client? httpClient,
}) async {
  final ExtensionConnection? connection = await host.getConnection();
  if (connection != null && connection.isPaired) {
    bool rejected = false;
    final EngineRepository? paired = await _verified(
      connection,
      host,
      httpClient,
      onUnauthorized: () async {
        rejected = true;
        await host.clearConnection();
      },
    );
    if (paired != null) {
      // Reaching the engine over loopback means it runs on this very device:
      // this browser is a client of that engine, not a separate device.
      if (isLoopbackEngineUrl(connection.engineUrl)) onLocalEngine?.call();
      return paired;
    }
    final Future<ExtensionConnection?> Function()? again = rePair;
    if (rejected && again != null) {
      ExtensionConnection? fresh;
      try {
        fresh = await again();
      } on Object catch (error) {
        debugPrint('Re-pairing the extension failed: $error');
      }
      if (fresh != null && fresh.isPaired) {
        final EngineRepository? repository = await _verified(
          fresh,
          host,
          httpClient,
        );
        if (repository != null) {
          if (isLoopbackEngineUrl(fresh.engineUrl)) onLocalEngine?.call();
          return repository;
        }
      }
    }
  }
  try {
    return await hive();
  } on Object catch (error) {
    debugPrint('Hive connection unavailable: $error');
    return null;
  }
}

Future<EngineRepository?> _verified(
  ExtensionConnection connection,
  ExtensionHost host,
  http.Client? httpClient, {
  Future<void> Function()? onUnauthorized,
}) async {
  final EngineRepository repository = repositoryForConnection(
    connection,
    host,
    httpClient: httpClient,
  );
  try {
    await repository.rest.health().timeout(const Duration(seconds: 5));
    await repository.rest.listWorkspaces().timeout(const Duration(seconds: 5));
    return repository;
  } on EngineApiException catch (error) {
    if (error.statusCode == 401) await onUnauthorized?.call();
  } on Object {
    // Engine not running: the caller falls back to the account path.
  }
  if (httpClient == null) {
    await repository.rest.close();
  }
  return null;
}
