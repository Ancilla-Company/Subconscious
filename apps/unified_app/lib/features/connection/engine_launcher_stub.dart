import 'engine_bootstrap.dart';

/// Web has no local engine to start.
final class PlatformEngineLauncher implements EngineProcessLauncher {
  PlatformEngineLauncher({String? executableOverride});

  @override
  bool get isSupported => false;

  @override
  String? get expectedExecutable => null;

  @override
  String? resolveExecutable() => null;

  @override
  Future<EngineLaunchLock?> tryAcquireLock() async => null;

  @override
  Future<void> start(String executable) async {
    throw UnsupportedError('Starting the engine is unavailable.');
  }
}
