import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'extension_host.dart';

const bool _forced = bool.fromEnvironment('SUBCONSCIOUS_EXTENSION');

ExtensionHost createExtensionHost() => WebExtensionHost();

/// `globalThis.subconsciousExtension`: every value crosses as a JSON string or
/// a primitive.
extension type _JsHost._(JSObject _) implements JSObject {
  external JSPromise<JSString> getConnection();
  external JSPromise<JSAny?> setConnection(String json);
  external JSPromise<JSAny?> clearConnection();
  external JSPromise<JSBoolean> requestOrigins(String originsJson);
  external JSPromise<JSBoolean> hasOrigins(String originsJson);
  external String toolGroups();
  external JSFunction onToolGroupsChanged(JSFunction callback);
  external JSPromise<JSString> callTool(
    String group,
    String id,
    String argsJson,
  );
  external void setVisible(bool visible);
  external JSPromise<JSBoolean> openSidePanel();
  external JSPromise<JSBoolean> requestSiteAccess(String origin);
  external JSPromise<JSNumber> acquireInstanceSlot(int max);
  external String? get mode;
  external String? get extensionVersion;
  external String? get extensionOrigin;
}

/// Talks to the JavaScript host. Every call tolerates a missing host or a
/// rejected promise so the app never crashes because of the extension layer.
final class WebExtensionHost implements ExtensionHost {
  WebExtensionHost();

  _JsHost? get _host {
    final JSObject? value = globalContext.getProperty<JSObject?>(
      'subconsciousExtension'.toJS,
    );
    return value == null ? null : _JsHost._(value);
  }

  @override
  bool get isExtension =>
      _forced || globalContext.has('__SUBCONSCIOUS_EXTENSION__');

  @override
  String get mode {
    final String? hostMode = _host?.mode;
    if (hostMode != null && hostMode.isNotEmpty) return hostMode;
    final JSObject? marker = globalContext.getProperty<JSObject?>(
      '__SUBCONSCIOUS_EXTENSION__'.toJS,
    );
    if (marker != null) {
      return marker.getProperty<JSString?>('mode'.toJS)?.toDart ?? '';
    }
    return '';
  }

  @override
  String get extensionVersion => _host?.extensionVersion ?? '';

  @override
  String get extensionOrigin => _host?.extensionOrigin ?? '';

  int _slot = 0;

  @override
  int get instanceSlot => _slot;

  @override
  Future<void> acquireInstanceSlot() async {
    final _JsHost? host = _host;
    if (host == null) return;
    try {
      _slot = (await host.acquireInstanceSlot(4).toDart).toDartInt;
    } on Object {
      _slot = 0; // An older host without slots: keep the single identity.
    }
  }

  @override
  String get deviceName {
    final String suffix = _slot > 0 ? ' #${_slot + 1}' : '';
    return 'Browser extension (${_browserName()})$suffix';
  }

  String _browserName() {
    try {
      final JSObject? navigator = globalContext.getProperty<JSObject?>(
        'navigator'.toJS,
      );
      final String agent =
          navigator?.getProperty<JSString?>('userAgent'.toJS)?.toDart ?? '';
      if (agent.contains('Edg/')) return 'Edge';
      if (agent.contains('OPR/')) return 'Opera';
      if (agent.contains('Brave')) return 'Brave';
      if (agent.contains('Firefox/')) return 'Firefox';
      if (agent.contains('Chrome/')) return 'Chrome';
    } on Object {
      // Fall through to the generic name.
    }
    return 'browser';
  }

  @override
  Future<ExtensionConnection?> getConnection() async {
    final _JsHost? host = _host;
    if (host == null) return null;
    try {
      return ExtensionConnection.tryParse(
        (await host.getConnection().toDart).toDart,
      );
    } on Object {
      return null;
    }
  }

  @override
  Future<void> setConnection(ExtensionConnection connection) async {
    final _JsHost? host = _host;
    if (host == null) return;
    await host.setConnection(jsonEncode(connection.toJson())).toDart;
  }

  @override
  Future<void> clearConnection() async {
    final _JsHost? host = _host;
    if (host == null) return;
    await host.clearConnection().toDart;
  }

  @override
  Future<bool> requestOrigins(List<String> origins) async {
    final _JsHost? host = _host;
    if (host == null) return false;
    try {
      return (await host.requestOrigins(jsonEncode(origins)).toDart).toDart;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> hasOrigins(List<String> origins) async {
    final _JsHost? host = _host;
    if (host == null) return false;
    try {
      return (await host.hasOrigins(jsonEncode(origins)).toDart).toDart;
    } on Object {
      return false;
    }
  }

  @override
  List<ClientToolGroup> toolGroups() {
    final _JsHost? host = _host;
    if (host == null) return const <ClientToolGroup>[];
    try {
      return parseToolGroups(host.toolGroups());
    } on Object {
      return const <ClientToolGroup>[];
    }
  }

  @override
  void Function() onToolGroupsChanged(
    void Function(List<ClientToolGroup> groups) listener,
  ) {
    final _JsHost? host = _host;
    if (host == null) return () {};
    try {
      final JSFunction unsubscribe = host.onToolGroupsChanged(
        ((JSString json) => listener(parseToolGroups(json.toDart))).toJS,
      );
      return () {
        try {
          unsubscribe.callAsFunction();
        } on Object {
          // Already gone.
        }
      };
    } on Object {
      return () {};
    }
  }

  @override
  Future<ExtensionToolResult> callTool(
    String group,
    String tool,
    String argumentsJson,
  ) async {
    final _JsHost? host = _host;
    if (host == null) {
      return const ExtensionToolResult.failure(
        'The browser extension host is not available.',
      );
    }
    try {
      return ExtensionToolResult.parse(
        (await host.callTool(group, tool, argumentsJson).toDart).toDart,
      );
    } on Object catch (error) {
      return ExtensionToolResult.failure('$error');
    }
  }

  @override
  void setVisible(bool visible) {
    try {
      _host?.setVisible(visible);
    } on Object {
      // The watcher is a convenience only.
    }
  }

  @override
  Future<bool> openSidePanel() async {
    final _JsHost? host = _host;
    if (host == null) return false;
    try {
      return (await host.openSidePanel().toDart).toDart;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> requestSiteAccess(String origin) async {
    final _JsHost? host = _host;
    if (host == null) return false;
    try {
      return (await host.requestSiteAccess(origin).toDart).toDart;
    } on Object {
      return false;
    }
  }
}
