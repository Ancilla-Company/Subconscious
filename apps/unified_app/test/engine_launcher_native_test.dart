import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/connection/engine_bootstrap.dart';
import 'package:unified_app/features/connection/engine_launcher_native.dart';

void main() {
  const String guiExe = r'C:\Pkg\gui\gui.exe';
  const String trayExe = r'C:\Pkg\engine\subconscious-desktop.exe';

  test('resolves the engine next to the gui folder', () {
    final PlatformEngineLauncher launcher = PlatformEngineLauncher(
      isWindows: true,
      resolvedExecutable: guiExe,
      fileExists: (String path) => path == trayExe,
    );
    expect(launcher.isSupported, isTrue);
    expect(launcher.resolveExecutable(), trayExe);
    expect(launcher.expectedExecutable, trayExe);
  });

  test('returns null when the engine file is missing', () {
    final PlatformEngineLauncher launcher = PlatformEngineLauncher(
      isWindows: true,
      resolvedExecutable: guiExe,
      fileExists: (String path) => false,
    );
    expect(launcher.resolveExecutable(), isNull);
    expect(launcher.expectedExecutable, trayExe);
  });

  test('honours the executable override', () {
    const String override = r'D:\dev\engine\subconscious-desktop.exe';
    final PlatformEngineLauncher launcher = PlatformEngineLauncher(
      executableOverride: override,
      isWindows: true,
      resolvedExecutable: guiExe,
      fileExists: (String path) => path == override,
    );
    expect(launcher.resolveExecutable(), override);
  });

  test('an empty override falls back to the sibling engine', () {
    final PlatformEngineLauncher launcher = PlatformEngineLauncher(
      executableOverride: '',
      isWindows: true,
      resolvedExecutable: guiExe,
      fileExists: (String path) => true,
    );
    expect(launcher.resolveExecutable(), trayExe);
  });

  test('is unsupported off Windows', () {
    expect(PlatformEngineLauncher(isWindows: false).isSupported, isFalse);
  });

  group('launch lock', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('engine-launch-test');
    });

    tearDown(() async {
      await directory.delete(recursive: true);
    });

    test('a second acquire is refused until the first is released', () async {
      final PlatformEngineLauncher first = PlatformEngineLauncher(
        dataDirectory: directory.path,
      );
      final PlatformEngineLauncher second = PlatformEngineLauncher(
        dataDirectory: directory.path,
      );
      final EngineLaunchLock? held = await first.tryAcquireLock();
      expect(held, isNotNull);
      expect(await second.tryAcquireLock(), isNull);
      await held!.release();
      final EngineLaunchLock? reacquired = await second.tryAcquireLock();
      expect(reacquired, isNotNull);
      await reacquired!.release();
    }, skip: Platform.isWindows ? false : 'Same-process locks only conflict on Windows.');

    test('creates the data directory when it is missing', () async {
      final String nested = '${directory.path}${Platform.pathSeparator}new';
      final EngineLaunchLock? lock = await PlatformEngineLauncher(
        dataDirectory: nested,
      ).tryAcquireLock();
      expect(lock, isNotNull);
      expect(Directory(nested).existsSync(), isTrue);
      await lock!.release();
    });
  });
}
