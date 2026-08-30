import 'dart:io';

import 'package:core_business_logic/core_business_logic.dart';

import 'package:engine_app/dart_engine_host.dart';

Future<void> main() async {
  const String configuredToken = String.fromEnvironment('SUBCONSCIOUS_ENGINE_TOKEN');
  const String configuredModelUrl = String.fromEnvironment('GENKIT_MODEL_URL');
  const String configuredPort = String.fromEnvironment('SUBCONSCIOUS_ENGINE_PORT');
  final EngineModelProvider provider = configuredModelUrl.isEmpty
      ? const EchoModelProvider()
      : GenkitModelProvider.remote(endpoint: Uri.parse(configuredModelUrl), modelName: Platform.environment['GENKIT_MODEL'] ?? 'subconscious');
  final DartEngineHost host = DartEngineHost(
    token: configuredToken.isEmpty ? 'subconscious-dev-token' : configuredToken,
    modelProvider: provider,
    port: int.tryParse(configuredPort) ?? 0,
    runtimeDirectory: Platform.environment['SUBCONSCIOUS_RUNTIME_DIRECTORY'],
  );
  await host.start();
  stdout.writeln('Subconscious Dart engine listening on ${host.address}');
  await ProcessSignal.sigint.watch().first;
  await host.close();
}
