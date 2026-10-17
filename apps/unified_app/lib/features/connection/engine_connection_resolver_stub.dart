import 'package:core_business_logic/core_business_logic.dart';

import '../hive/hive_repository_resolver.dart';

Future<EngineRepository?> resolveEngineRepository({
  required Uri? explicitEndpoint,
  required String explicitToken,
  required bool preferDev,
}) async {
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

Future<void> openEngineDataDirectory(String path) async {
  throw UnsupportedError('Opening the engine data directory is unavailable.');
}
