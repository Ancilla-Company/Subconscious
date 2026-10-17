import 'dart:io';

import 'engine_bootstrap.dart';
import 'engine_connection_resolver_native.dart' show engineDataDirectory;

const String _lockFileName = 'gui-engine-launch.lock';

/// Starts the packaged tray engine on Windows. Every argument is optional and
/// exists so tests do not depend on the real machine.
final class PlatformEngineLauncher implements EngineProcessLauncher {
  PlatformEngineLauncher({
    this.executableOverride,
    this.resolvedExecutable,
    this.isWindows,
    this.fileExists,
    this.dataDirectory,
  });

  /// Overrides the engine executable (SUBCONSCIOUS_ENGINE_EXE); empty is
  /// ignored.
  final String? executableOverride;

  /// Test hooks standing in for the real machine.
  final String? resolvedExecutable;
  final bool? isWindows;
  final bool Function(String)? fileExists;
  final String? dataDirectory;

  @override
  bool get isSupported => isWindows ?? Platform.isWindows;

  @override
  String? get expectedExecutable {
    final String? override = executableOverride?.trim();
    if (override != null && override.isNotEmpty) return override;
    return desktopExecutablePathFor(
      resolvedExecutable ?? Platform.resolvedExecutable,
      separator: r'\',
    );
  }

  @override
  String? resolveExecutable() {
    final String? path = expectedExecutable;
    if (path == null) return null;
    final bool exists = fileExists?.call(path) ?? File(path).existsSync();
    return exists ? path : null;
  }

  @override
  Future<void> start(String executable) async {
    final int separator = executable.lastIndexOf(r'\');
    await Process.start(
      executable,
      const <String>[],
      workingDirectory: separator > 0 ? executable.substring(0, separator) : null,
      mode: ProcessStartMode.detached,
    );
  }

  @override
  Future<EngineLaunchLock?> tryAcquireLock() async {
    final String? directory =
        dataDirectory ?? engineDataDirectory(preferDev: false);
    if (directory == null) return const _NoopLaunchLock();
    final RandomAccessFile handle;
    try {
      await Directory(directory).create(recursive: true);
      handle = await File(
        '$directory${Platform.pathSeparator}$_lockFileName',
      ).open(mode: FileMode.append);
    } on FileSystemException {
      // Without a lock file, launching still beats showing nothing.
      return const _NoopLaunchLock();
    }
    try {
      // Non-blocking: throws when another process holds the lock.
      await handle.lock(FileLock.exclusive);
    } on FileSystemException {
      await handle.close();
      return null;
    }
    return _FileLaunchLock(handle);
  }
}

final class _NoopLaunchLock implements EngineLaunchLock {
  const _NoopLaunchLock();

  @override
  Future<void> release() async {}
}

final class _FileLaunchLock implements EngineLaunchLock {
  _FileLaunchLock(this._handle);

  final RandomAccessFile _handle;

  @override
  Future<void> release() async {
    try {
      await _handle.unlock();
    } on FileSystemException {
      // Closing the handle releases the lock anyway.
    }
    await _handle.close();
  }
}
