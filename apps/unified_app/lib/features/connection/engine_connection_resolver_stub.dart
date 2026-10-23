import 'package:core_business_logic/core_business_logic.dart';

import '../extension/extension_connection_resolver.dart';
import '../extension/extension_host.dart';
import '../extension/extension_runtime.dart';
import '../hive/hive_repository_resolver.dart';
import '../hive/hive_runtime.dart';

Future<EngineRepository?> resolveEngineRepository({
  required Uri? explicitEndpoint,
  required String explicitToken,
  required bool preferDev,
}) async {
  final ExtensionHost extensionHost = ExtensionHost.instance;
  if (extensionHost.isExtension) {
    // Paired local engine first, then a remote home engine through the
    // account; null shows the Account page.
    return resolveExtensionRepository(
      host: extensionHost,
      hive: resolveHiveRepository,
      rePair: rePairExtension,
      // The engine is on this device: the hive runtime then lists devices
      // through it and registers no separate device for this browser.
      onLocalEngine: HiveRuntime.shared.markLocalEngineFound,
    );
  }
  final Uri? endpoint = explicitEndpoint;
  if (endpoint == null || endpoint.host.isEmpty || explicitToken.isEmpty) {
    // Web has no local engine: use a home engine over WebRTC when signed in
    // (reduced trust, see HiveRuntime).
    return resolveHiveRepository();
  }
  final Uri baseUri = endpoint.replace(
    path: '/api/v1/',
    queryParameters: const <String, String>{},
  );
  final Uri webSocketUri = endpoint.replace(
    scheme: endpoint.scheme == 'https' ? 'wss' : 'ws',
    path: '/api/v1/events',
    queryParameters: <String, String>{'token': explicitToken},
  );
  return EngineRepository(
    rest: RestEngineClient(baseUri: baseUri, token: explicitToken),
    socket: WebSocketEngineClient(
      endpoint: webSocketUri,
      identity: const ClientIdentity(type: ClientType.web),
    ),
  );
}

Future<int?> discoverLocalEnginePort({required bool preferDev}) async => null;

Future<Uri?> discoverLocalEngineLanEndpoint({required bool preferDev}) async =>
    null;

String? engineDataDirectory({required bool preferDev}) => null;

/// Web and other platforms without a local engine have no profiles.
Future<void> setActiveEngineProfile({
  required bool preferDev,
  required String? profileId,
}) async {}

Future<void> openEngineDataDirectory(String path) async {
  throw UnsupportedError('Opening the engine data directory is unavailable.');
}
