import 'dart:async';

import 'package:flutter/foundation.dart';

import 'extension_host.dart';
import 'extension_pairing.dart';

enum ExtensionEngineStatus {
  /// Not looked at yet.
  idle,
  searching,

  /// A local engine answered; waiting for the user to pair.
  found,
  pairing,
  paired,
  notFound,
}

/// State behind the Account page "Engine" section (extension mode only).
final class ExtensionPairingController extends ChangeNotifier {
  ExtensionPairingController({
    required this.pairing,
    ExtensionHost? host,
    this.serverUrl,
    this.environment,
    this.onConnectionChanged,
  }) : host = host ?? ExtensionHost.instance;

  final ExtensionPairing pairing;
  final ExtensionHost host;
  final String? serverUrl;
  final String? environment;

  /// Called after a pairing, a pasted token or an unpair so the app reconnects.
  final FutureOr<void> Function()? onConnectionChanged;

  ExtensionEngineStatus status = ExtensionEngineStatus.idle;
  FoundEngine? engine;
  ExtensionConnection? connection;

  /// Plain-language failure of the last action.
  String? error;
  bool _disposed = false;

  bool get isPaired => status == ExtensionEngineStatus.paired;

  /// Reads the stored pairing, else looks for a local engine.
  Future<void> refresh() async {
    status = ExtensionEngineStatus.searching;
    error = null;
    _notify();
    final ExtensionConnection? stored = await host.getConnection();
    if (stored != null && stored.isPaired) {
      connection = stored;
      status = ExtensionEngineStatus.paired;
      _notify();
      return;
    }
    connection = null;
    engine = await pairing.findEngine();
    status = engine == null
        ? ExtensionEngineStatus.notFound
        : ExtensionEngineStatus.found;
    _notify();
  }

  /// Call from the button tap: the permission prompt needs a user gesture, so
  /// the request is issued before the first `await` of other work.
  Future<void> pair() async {
    final FoundEngine? target = engine;
    if (target == null || status == ExtensionEngineStatus.pairing) return;
    final Future<bool> granted = host.requestOrigins(_originsFor(target.url));
    status = ExtensionEngineStatus.pairing;
    error = null;
    _notify();
    try {
      if (!await granted) {
        throw const PairingException(
          'Allow access to the engine address to pair this browser.',
        );
      }
      connection = await pairing.pair(
        target,
        serverUrl: serverUrl,
        environment: environment,
      );
      status = ExtensionEngineStatus.paired;
      _notify();
      await onConnectionChanged?.call();
    } on PairingException catch (failure) {
      error = failure.message;
      status = ExtensionEngineStatus.found;
      _notify();
    } on Object catch (failure) {
      error = 'Pairing failed: $failure';
      status = ExtensionEngineStatus.found;
      _notify();
    }
  }

  /// Fallback: an engine address and joining token pasted by the user.
  Future<void> connectWithToken({
    required String url,
    required String token,
  }) async {
    final Uri? uri = Uri.tryParse(url.trim());
    final String joining = token.trim();
    if (uri == null ||
        !uri.hasScheme ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        joining.isEmpty) {
      error = 'Enter the engine address (http://host:port) and its token.';
      _notify();
      return;
    }
    final Future<bool> granted = host.requestOrigins(_originsFor(uri));
    status = ExtensionEngineStatus.pairing;
    error = null;
    _notify();
    try {
      if (!await granted) {
        error = 'Allow access to the engine address to connect.';
        status = ExtensionEngineStatus.notFound;
        _notify();
        return;
      }
      final ExtensionConnection pasted = ExtensionConnection(
        engineUrl: Uri(
          scheme: uri.scheme,
          host: uri.host,
          port: uri.hasPort ? uri.port : null,
        ).toString(),
        engineToken: joining,
        clientId: '',
        serverUrl: serverUrl,
        environment: environment,
      );
      await host.setConnection(pasted);
      connection = pasted;
      status = ExtensionEngineStatus.paired;
      _notify();
      await onConnectionChanged?.call();
    } on Object catch (failure) {
      error = 'Could not save the connection: $failure';
      status = ExtensionEngineStatus.notFound;
      _notify();
    }
  }

  Future<void> unpair() async {
    await host.clearConnection();
    connection = null;
    error = null;
    _notify();
    await onConnectionChanged?.call();
    await refresh();
  }

  static List<String> _originsFor(Uri url) => <String>[
    '${url.scheme}://${url.host}/*',
  ];

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
