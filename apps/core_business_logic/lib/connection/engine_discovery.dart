import '../models/engine_models.dart';

/// Platform adapters provide runtime.json access without coupling core to dart:io or Flutter.
abstract interface class RuntimeInfoLoader {
  Future<EngineRuntimeInfo?> load();
}

final class EngineDiscovery {
  const EngineDiscovery({required this.loader, required this.healthProbe});
  final RuntimeInfoLoader loader;
  final Future<bool> Function(EngineRuntimeInfo info) healthProbe;

  Future<EngineRuntimeInfo> discover() async {
    final info = await loader.load();
    if (info == null) {
      throw StateError('Subconscious engine runtime.json was not found.');
    }
    if (!await healthProbe(info)) {
      throw StateError('Subconscious engine runtime.json is stale.');
    }
    return info;
  }
}

final class EnvironmentRuntimeInfoLoader implements RuntimeInfoLoader {
  const EnvironmentRuntimeInfoLoader({required this.endpoint, required this.token});
  final Uri? endpoint;
  final String token;

  @override
  Future<EngineRuntimeInfo?> load() async {
    final value = endpoint;
    if (value == null || token.isEmpty) return null;
    return EngineRuntimeInfo(host: value.host, port: value.port, token: token, pid: 0, version: 'external');
  }
}
