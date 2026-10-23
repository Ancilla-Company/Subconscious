import 'package:flutter/foundation.dart';

import 'features/extension/extension_host.dart';

/// What kind of client this build is. It is decided once at start, so every
/// registration with the server and the engine says the same thing.
enum AppClientKind {
  /// A desktop or mobile app that is installed on the device.
  native,

  /// The Flutter web build, opened as a page in a browser.
  web,

  /// The browser extension (popup or side panel).
  browserExtension,
}

/// The identity of this build: web page, browser extension, or native app.
///
/// Detected at start (`window.__SUBCONSCIOUS_EXTENSION__` marks the extension,
/// `kIsWeb` the web page). A build can also be told what it is with
/// `--dart-define=SUBCONSCIOUS_CLIENT=web|browser|native`, which wins over
/// detection (tests, kiosk pages, an extension build served as a page).
abstract final class AppClient {
  static const String _forced = String.fromEnvironment('SUBCONSCIOUS_CLIENT');

  static AppClientKind get kind {
    switch (_forced) {
      case 'web':
        return AppClientKind.web;
      case 'browser':
        return AppClientKind.browserExtension;
      case 'native':
        return AppClientKind.native;
    }
    if (ExtensionHost.instance.isExtension) {
      return AppClientKind.browserExtension;
    }
    return kIsWeb ? AppClientKind.web : AppClientKind.native;
  }

  /// The `platform` registered with the server. `web` and `browser` are
  /// transient: an offline one is dropped from the device list and, after a
  /// while, deleted by the server.
  static String get platform => switch (kind) {
    AppClientKind.browserExtension => 'browser',
    AppClientKind.web => 'web',
    AppClientKind.native => defaultTargetPlatform.name,
  };

  /// True for clients that come and go (a browser tab, an extension popup).
  static bool get isTransient => kind != AppClientKind.native;

  /// True for a server-reported [platform] that is transient.
  static bool isTransientPlatform(String platform) {
    final String value = platform.trim().toLowerCase();
    return value == 'web' || value == 'browser';
  }
}
