import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/connection/engine_bootstrap.dart';

final class _FakeLock implements EngineLaunchLock {
  int releases = 0;

  @override
  Future<void> release() async => releases++;
}

final class _FakeLauncher implements EngineProcessLauncher {
  _FakeLauncher({
    this.supported = true,
    this.executable = r'C:\App\engine\subconscious-desktop.exe',
    this.lockHeldElsewhere = false,
    this.startError,
  });

  final bool supported;
  final String? executable;
  final bool lockHeldElsewhere;
  final Object? startError;
  final List<String> started = <String>[];
  final List<_FakeLock> locks = <_FakeLock>[];
  int lockAttempts = 0;
  int resolveCalls = 0;

  @override
  bool get isSupported => supported;

  @override
  String? get expectedExecutable => r'C:\App\engine\subconscious-desktop.exe';

  @override
  String? resolveExecutable() {
    resolveCalls++;
    return executable;
  }

  @override
  Future<EngineLaunchLock?> tryAcquireLock() async {
    lockAttempts++;
    if (lockHeldElsewhere) return null;
    final _FakeLock lock = _FakeLock();
    locks.add(lock);
    return lock;
  }

  @override
  Future<void> start(String executable) async {
    started.add(executable);
    final Object? error = startError;
    if (error != null) throw error;
  }
}

void main() {
  late int healthChecks;
  late bool healthy;
  late int delays;

  Future<bool> isHealthy() async {
    healthChecks++;
    return healthy;
  }

  Future<void> noDelay(Duration _) async => delays++;

  EngineBootstrap bootstrap(
    _FakeLauncher launcher, {
    bool preferDev = false,
    bool hasExplicitEndpoint = false,
  }) => EngineBootstrap(
    launcher: launcher,
    isEngineHealthy: isHealthy,
    preferDev: preferDev,
    hasExplicitEndpoint: hasExplicitEndpoint,
    delay: noDelay,
  );

  setUp(() {
    healthChecks = 0;
    healthy = false;
    delays = 0;
  });

  test('development never launches and never touches the launcher', () async {
    final _FakeLauncher launcher = _FakeLauncher();
    final EngineStartOutcome outcome = await bootstrap(
      launcher,
      preferDev: true,
    ).ensureRunning();
    expect(outcome, EngineStartOutcome.skipped);
    expect(launcher.started, isEmpty);
    expect(launcher.lockAttempts, 0);
    expect(launcher.resolveCalls, 0);
    expect(healthChecks, 0);
  });

  test('an unsupported platform is skipped', () async {
    final _FakeLauncher launcher = _FakeLauncher(supported: false);
    expect(
      await bootstrap(launcher).ensureRunning(),
      EngineStartOutcome.skipped,
    );
    expect(launcher.started, isEmpty);
    expect(healthChecks, 0);
  });

  test('an explicit endpoint is skipped', () async {
    final _FakeLauncher launcher = _FakeLauncher();
    expect(
      await bootstrap(launcher, hasExplicitEndpoint: true).ensureRunning(),
      EngineStartOutcome.skipped,
    );
    expect(launcher.started, isEmpty);
    expect(healthChecks, 0);
  });

  test('a healthy engine is not launched again', () async {
    healthy = true;
    final _FakeLauncher launcher = _FakeLauncher();
    expect(
      await bootstrap(launcher).ensureRunning(),
      EngineStartOutcome.alreadyRunning,
    );
    expect(launcher.started, isEmpty);
    expect(launcher.lockAttempts, 0);
  });

  test('an unhealthy engine is launched once, then polled', () async {
    final _FakeLauncher launcher = _FakeLauncher();
    // The engine answers on the third poll after it was started.
    int pollsAfterStart = 0;
    final EngineBootstrap subject = EngineBootstrap(
      launcher: launcher,
      preferDev: false,
      isEngineHealthy: () async {
        if (launcher.started.isEmpty) return false;
        pollsAfterStart++;
        return pollsAfterStart >= 3;
      },
      delay: noDelay,
    );
    expect(await subject.ensureRunning(), EngineStartOutcome.started);
    expect(launcher.started, <String>[r'C:\App\engine\subconscious-desktop.exe']);
    expect(pollsAfterStart, 3);
    expect(delays, 3);
    expect(launcher.locks.single.releases, 1);
  });

  test('an engine that never comes up throws after the timeout', () async {
    final _FakeLauncher launcher = _FakeLauncher();
    final EngineBootstrap subject = EngineBootstrap(
      launcher: launcher,
      preferDev: false,
      isEngineHealthy: isHealthy,
      pollInterval: const Duration(milliseconds: 500),
      startupTimeout: const Duration(seconds: 45),
      delay: noDelay,
    );
    await expectLater(
      subject.ensureRunning(),
      throwsA(
        isA<EngineStartException>().having(
          (EngineStartException e) => e.toString(),
          'message',
          contains('did not start within 45 seconds'),
        ),
      ),
    );
    expect(launcher.started, hasLength(1));
    // 500ms backoff doubling to a 2s cap: far fewer probes than 90.
    expect(delays, 24);
    expect(launcher.locks.single.releases, 1);
  });

  test('a timeout message names the engine log', () async {
    final EngineBootstrap subject = EngineBootstrap(
      launcher: _FakeLauncher(),
      preferDev: false,
      isEngineHealthy: isHealthy,
      pollInterval: const Duration(milliseconds: 500),
      startupTimeout: const Duration(seconds: 1),
      engineLogPath: r'C:\data\logs\engine.log',
      delay: noDelay,
    );
    await expectLater(
      subject.ensureRunning(),
      throwsA(
        isA<EngineStartException>().having(
          (EngineStartException e) => e.message,
          'message',
          endsWith(r'Details: C:\data\logs\engine.log'),
        ),
      ),
    );
  });

  test('a missing executable throws without launching', () async {
    final _FakeLauncher launcher = _FakeLauncher(executable: null);
    await expectLater(
      bootstrap(launcher).ensureRunning(),
      throwsA(
        isA<EngineStartException>().having(
          (EngineStartException e) => e.message,
          'message',
          allOf(
            contains('could not be found next to the app'),
            contains(r'C:\App\engine\subconscious-desktop.exe'),
          ),
        ),
      ),
    );
    expect(launcher.started, isEmpty);
    expect(launcher.lockAttempts, 0);
  });

  test('a lock held by another process only waits for the engine', () async {
    final _FakeLauncher launcher = _FakeLauncher(lockHeldElsewhere: true);
    int checks = 0;
    final EngineBootstrap subject = EngineBootstrap(
      launcher: launcher,
      preferDev: false,
      isEngineHealthy: () async => ++checks > 3,
      delay: noDelay,
    );
    expect(await subject.ensureRunning(), EngineStartOutcome.started);
    expect(launcher.started, isEmpty);
    expect(launcher.lockAttempts, 1);
  });

  test('an engine that became healthy while locking is not launched', () async {
    final _FakeLauncher launcher = _FakeLauncher();
    int checks = 0;
    final EngineBootstrap subject = EngineBootstrap(
      launcher: launcher,
      preferDev: false,
      // Unhealthy on the first check, healthy once the lock is held.
      isEngineHealthy: () async => ++checks > 1,
      delay: noDelay,
    );
    expect(await subject.ensureRunning(), EngineStartOutcome.alreadyRunning);
    expect(launcher.started, isEmpty);
    expect(launcher.locks.single.releases, 1);
  });

  test('a failing start is wrapped and releases the lock', () async {
    final StateError cause = StateError('access denied');
    final _FakeLauncher launcher = _FakeLauncher(startError: cause);
    await expectLater(
      bootstrap(launcher).ensureRunning(),
      throwsA(
        isA<EngineStartException>()
            .having((EngineStartException e) => e.cause, 'cause', cause)
            .having(
              (EngineStartException e) => e.message,
              'message',
              contains('access denied'),
            ),
      ),
    );
    expect(launcher.locks.single.releases, 1);
  });

  test('concurrent calls share one launch', () async {
    final _FakeLauncher launcher = _FakeLauncher();
    final Completer<void> gate = Completer<void>();
    bool started = false;
    final EngineBootstrap subject = EngineBootstrap(
      launcher: launcher,
      preferDev: false,
      isEngineHealthy: () async {
        await gate.future;
        started = started || launcher.started.isNotEmpty;
        return started;
      },
      delay: noDelay,
    );
    final Future<EngineStartOutcome> first = subject.ensureRunning();
    final Future<EngineStartOutcome> second = subject.ensureRunning();
    expect(identical(first, second), isTrue);
    gate.complete();
    expect(await first, EngineStartOutcome.started);
    expect(await second, EngineStartOutcome.started);
    expect(launcher.started, hasLength(1));
  });

  test('a later call starts a fresh attempt after one finishes', () async {
    final _FakeLauncher launcher = _FakeLauncher();
    healthy = true;
    final EngineBootstrap subject = bootstrap(launcher);
    await subject.ensureRunning();
    healthy = false;
    await expectLater(
      subject.ensureRunning(),
      throwsA(isA<EngineStartException>()),
    );
    expect(launcher.started, hasLength(1));
  });

  group('desktopExecutablePathFor', () {
    test('maps gui.exe to the sibling engine folder', () {
      expect(
        desktopExecutablePathFor(
          r'C:\Program Files\WindowsApps\Pkg\gui\gui.exe',
          separator: r'\',
        ),
        r'C:\Program Files\WindowsApps\Pkg\engine\subconscious-desktop.exe',
      );
    });

    test('works with forward slashes', () {
      expect(
        desktopExecutablePathFor('/opt/pkg/gui/gui.exe', separator: '/'),
        '/opt/pkg/engine/subconscious-desktop.exe',
      );
    });

    test('returns null when there is no parent directory', () {
      expect(desktopExecutablePathFor('gui.exe', separator: r'\'), isNull);
      expect(desktopExecutablePathFor(r'gui\gui.exe', separator: r'\'), isNull);
      expect(desktopExecutablePathFor('', separator: r'\'), isNull);
    });
  });
}
