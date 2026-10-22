import 'dart:async';

/// What [EngineBootstrap.ensureRunning] did.
enum EngineStartOutcome {
  /// Nothing to do: development build, explicit endpoint or unsupported
  /// platform.
  skipped,

  /// A healthy engine was already listening, so nothing was launched.
  alreadyRunning,

  /// The engine was started (or another process started it) and is healthy.
  started,
}

/// The engine could not be started. [message] is safe to show to the user.
final class EngineStartException implements Exception {
  const EngineStartException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// Held while this process is the one launching the engine.
abstract interface class EngineLaunchLock {
  Future<void> release();
}

/// Platform access used by [EngineBootstrap]; faked in tests.
abstract interface class EngineProcessLauncher {
  /// Whether this platform can start the packaged engine.
  bool get isSupported;

  /// Where the engine executable is expected, whether or not it exists.
  String? get expectedExecutable;

  /// The engine executable, or null when it is missing.
  String? resolveExecutable();

  /// Takes the cross-process launch lock. Null means another process holds it.
  Future<EngineLaunchLock?> tryAcquireLock();

  /// Starts [executable] detached from this process.
  Future<void> start(String executable);
}

/// Resolves `<root>/engine/subconscious-desktop.exe` from the path of
/// `<root>/gui/gui.exe`. Returns null when [guiExecutable] has no parent
/// directory to go up from.
String? desktopExecutablePathFor(
  String guiExecutable, {
  required String separator,
}) {
  final int fileSeparator = guiExecutable.lastIndexOf(separator);
  if (fileSeparator <= 0) return null;
  final String guiDirectory = guiExecutable.substring(0, fileSeparator);
  final int directorySeparator = guiDirectory.lastIndexOf(separator);
  if (directorySeparator < 0) return null;
  final String root = guiDirectory.substring(0, directorySeparator);
  return '$root${separator}engine${separator}subconscious-desktop.exe';
}

/// Starts the local engine when the app is a production desktop build and no
/// healthy engine is found. Development builds, explicit endpoints and
/// unsupported platforms never launch anything.
final class EngineBootstrap {
  EngineBootstrap({
    required this.launcher,
    required this.isEngineHealthy,
    required this.preferDev,
    this.hasExplicitEndpoint = false,
    this.pollInterval = const Duration(milliseconds: 500),
    this.startupTimeout = const Duration(seconds: 45),
    this.engineLogPath,
    Future<void> Function(Duration)? delay,
  }) : _delay = delay ?? Future<void>.delayed;

  final EngineProcessLauncher launcher;
  final Future<bool> Function() isEngineHealthy;
  final bool preferDev;
  final bool hasExplicitEndpoint;
  final Duration pollInterval;
  final Duration startupTimeout;

  /// Engine log file named in start failures so users can find the cause.
  final String? engineLogPath;
  final Future<void> Function(Duration) _delay;

  String get _details =>
      engineLogPath == null ? '' : ' Details: $engineLogPath';

  Future<EngineStartOutcome>? _inFlight;

  /// Makes sure an engine is running. Concurrent calls share one attempt.
  /// Throws [EngineStartException] when the engine cannot be started or does
  /// not become healthy in [startupTimeout].
  Future<EngineStartOutcome> ensureRunning() {
    if (preferDev || hasExplicitEndpoint) {
      return Future<EngineStartOutcome>.value(EngineStartOutcome.skipped);
    }
    if (!launcher.isSupported) {
      return Future<EngineStartOutcome>.value(EngineStartOutcome.skipped);
    }
    final Future<EngineStartOutcome>? running = _inFlight;
    if (running != null) return running;
    final Future<EngineStartOutcome> attempt = _ensureRunning().whenComplete(
      () => _inFlight = null,
    );
    _inFlight = attempt;
    return attempt;
  }

  Future<EngineStartOutcome> _ensureRunning() async {
    if (await isEngineHealthy()) return EngineStartOutcome.alreadyRunning;

    final String? executable = launcher.resolveExecutable();
    if (executable == null) {
      final String? expected = launcher.expectedExecutable;
      final String where = expected == null ? '' : ' (expected $expected)';
      throw EngineStartException(
        'The Subconscious engine could not be found next to the app$where. '
        "Reinstall Subconscious or start 'Subconscious Engine' from the "
        'Start menu.',
      );
    }

    final EngineLaunchLock? lock = await launcher.tryAcquireLock();
    try {
      // With the lock held, another process may have finished launching.
      // Without it, another process is launching right now: only wait.
      if (lock != null) {
        if (await isEngineHealthy()) return EngineStartOutcome.alreadyRunning;
        try {
          await launcher.start(executable);
        } on Object catch (error) {
          throw EngineStartException(
            'The Subconscious engine could not be started: $error$_details',
            cause: error,
          );
        }
      }
      // Exponential backoff from pollInterval up to 2s keeps startup quick
      // without probing the engine several times per second.
      const Duration maxInterval = Duration(seconds: 2);
      Duration wait = pollInterval.inMicroseconds < 1
          ? const Duration(microseconds: 1)
          : pollInterval;
      Duration waited = Duration.zero;
      while (waited < startupTimeout) {
        await _delay(wait);
        waited += wait;
        if (await isEngineHealthy()) return EngineStartOutcome.started;
        wait = wait * 2 > maxInterval ? maxInterval : wait * 2;
        if (wait < pollInterval) wait = pollInterval;
      }
      throw EngineStartException(
        'The Subconscious engine did not start within '
        '${startupTimeout.inSeconds} seconds. '
        "Start 'Subconscious Engine' from the Start menu.$_details",
      );
    } finally {
      await lock?.release();
    }
  }
}
