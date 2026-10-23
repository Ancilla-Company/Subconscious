import 'extension_host_stub.dart'
    if (dart.library.js_interop) 'extension_host_web.dart'
    as platform;
import 'extension_models.dart';

export 'extension_models.dart';

/// The thin JavaScript host of the browser extension
/// (`globalThis.subconsciousExtension`, contracts.md section 5). On every other
/// platform it is a no-op with [isExtension] false.
abstract interface class ExtensionHost {
  /// The host of this runtime. Tests may replace it with a fake.
  static ExtensionHost instance = platform.createExtensionHost();

  /// True inside the extension (`window.__SUBCONSCIOUS_EXTENSION__` exists or
  /// `--dart-define=SUBCONSCIOUS_EXTENSION=true`).
  bool get isExtension;

  /// `popup`, `panel`, or empty outside the extension.
  String get mode;
  String get extensionVersion;

  /// Which of the concurrently open extension pages this is (0, 1, ...). The
  /// popup, the side panel and a second window's side panel share one origin,
  /// hence one storage; each needs its own hive node identity or the engine
  /// sees them as the same client and rejects the second. Claim it with
  /// [acquireInstanceSlot] before anything reads the identity.
  int get instanceSlot;
  Future<void> acquireInstanceSlot();

  /// The name this page registers with the account's device list, for example
  /// `Browser extension (Chrome)` or `Browser extension (Chrome) #2`.
  String get deviceName;

  /// `chrome-extension://<id>`, empty outside the extension.
  String get extensionOrigin;

  Future<ExtensionConnection?> getConnection();

  /// Merge-writes the set fields of [connection].
  Future<void> setConnection(ExtensionConnection connection);
  Future<void> clearConnection();

  /// Must be called inside a user gesture (button tap).
  Future<bool> requestOrigins(List<String> origins);
  Future<bool> hasOrigins(List<String> origins);

  /// Browser tools plus the WebMCP tools of the active tab.
  List<ClientToolGroup> toolGroups();

  /// Calls [listener] when the available groups change; returns the
  /// unsubscribe function.
  void Function() onToolGroupsChanged(
    void Function(List<ClientToolGroup> groups) listener,
  );

  /// Never throws; failures come back as [ExtensionToolResult.failure].
  Future<ExtensionToolResult> callTool(
    String group,
    String tool,
    String argumentsJson,
  );

  /// Starts or stops the host's WebMCP watcher.
  void setVisible(bool visible);

  /// Popup only.
  Future<bool> openSidePanel();
  Future<bool> requestSiteAccess(String origin);
}
