import 'package:http/http.dart' as http;

import '../hive/hive_runtime.dart';
import 'extension_host.dart';
import 'extension_pairing.dart';
import 'extension_pairing_controller.dart';

const bool _preferDev = bool.fromEnvironment('SUBCONSCIOUS_ENGINE_DEV');

/// Wires [ExtensionPairing] to the app's one server session.
ExtensionPairing buildExtensionPairing({
  HiveRuntime? runtime,
  ExtensionHost? host,
  http.Client? client,
}) {
  final HiveRuntime hive = runtime ?? HiveRuntime.shared;
  return ExtensionPairing(
    // A plain client: pairing bodies carry one-time secrets.
    client: client ?? http.Client(),
    host: host,
    preferDev: _preferDev,
    requestAssertion:
        ({
          required String nodeId,
          required String clientNonce,
          required String origin,
        }) => hive.account.requestPairingAssertion(
          nodeId: nodeId,
          clientNonce: clientNonce,
          origin: origin,
        ),
  );
}

/// Controller behind the Account page "Engine" section.
ExtensionPairingController buildExtensionPairingController({
  required Future<void> Function() onConnectionChanged,
  HiveRuntime? runtime,
  ExtensionHost? host,
}) {
  final HiveRuntime hive = runtime ?? HiveRuntime.shared;
  return ExtensionPairingController(
    pairing: buildExtensionPairing(runtime: hive, host: host),
    host: host,
    serverUrl: hive.account.baseUri.toString(),
    environment: _preferDev ? 'development' : 'production',
    onConnectionChanged: onConnectionChanged,
  );
}

/// Pairs again without user interaction after the engine rejected the stored
/// token. Only possible while a server session exists and the browser already
/// allows the engine address (no gesture is available here).
Future<ExtensionConnection?> rePairExtension({
  HiveRuntime? runtime,
  ExtensionHost? host,
}) async {
  final HiveRuntime hive = runtime ?? HiveRuntime.shared;
  final ExtensionHost extensionHost = host ?? ExtensionHost.instance;
  await hive.restore();
  if (!hive.isSignedIn) return null;
  if (!await extensionHost.hasOrigins(const <String>['http://127.0.0.1/*'])) {
    return null;
  }
  final ExtensionPairing pairing = buildExtensionPairing(
    runtime: hive,
    host: extensionHost,
  );
  final FoundEngine? engine = await pairing.findEngine();
  if (engine == null) return null;
  try {
    return await pairing.pair(
      engine,
      serverUrl: hive.account.baseUri.toString(),
      environment: _preferDev ? 'development' : 'production',
    );
  } on PairingException {
    return null;
  }
}
