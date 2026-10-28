import 'dart:io';

import 'package:flutter/foundation.dart';

import '../connection/engine_connection_resolver_native.dart'
    show engineDataDirectory;

/// The desktop app's own log, next to the engine's: `<data>/logs/gui.log`.
///
/// It records start-up, window and connection milestones and every uncaught
/// error, so a window that never appears can be diagnosed from the file. Each
/// line is appended synchronously, so the last lines survive a crash or kill.
const int _maxBytes = 2 * 1024 * 1024;

File? _file;

String? get guiLogPath => _file?.path;

Future<void> initGuiLog() async {
  try {
    final String? root = engineDataDirectory(
      preferDev: const bool.fromEnvironment('SUBCONSCIOUS_ENGINE_DEV'),
    );
    if (root == null) return;
    final Directory logs = Directory('$root${Platform.pathSeparator}logs');
    await logs.create(recursive: true);
    final File file = File('${logs.path}${Platform.pathSeparator}gui.log');
    if (await file.exists() && await file.length() > _maxBytes) {
      final File old = File('${file.path}.1');
      if (await old.exists()) await old.delete();
      await file.rename(old.path);
    }
    _file = file;
    guiLog(
      'GUI start pid=$pid os=${Platform.operatingSystemVersion} '
      'mode=${kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug'} '
      'exe=${Platform.resolvedExecutable}',
    );
  } on Object {
    // Logging must never stop the app from starting.
  }
}

void guiLog(String message, {String level = 'INFO'}) {
  final File? file = _file;
  if (file == null) return;
  try {
    final String line =
        '${DateTime.now().toIso8601String()} ${level.padRight(7)} $message\n';
    file.writeAsStringSync(line, mode: FileMode.append, flush: true);
  } on Object {
    // Out of space or locked: drop the line.
  }
}

void guiLogError(String where, Object error, StackTrace? stack) {
  guiLog('$where: $error${stack == null ? '' : '\n$stack'}', level: 'ERROR');
}
