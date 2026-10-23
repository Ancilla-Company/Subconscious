import 'extension_host.dart';

ExtensionHost createExtensionHost() => const NoExtensionHost();

/// Used outside the browser extension: nothing is available, nothing happens.
final class NoExtensionHost implements ExtensionHost {
  const NoExtensionHost();

  @override
  bool get isExtension => false;
  @override
  String get mode => '';
  @override
  String get extensionVersion => '';
  @override
  String get extensionOrigin => '';
  @override
  int get instanceSlot => 0;
  @override
  Future<void> acquireInstanceSlot() async {}
  @override
  String get deviceName => 'Browser extension';

  @override
  Future<ExtensionConnection?> getConnection() async => null;
  @override
  Future<void> setConnection(ExtensionConnection connection) async {}
  @override
  Future<void> clearConnection() async {}
  @override
  Future<bool> requestOrigins(List<String> origins) async => false;
  @override
  Future<bool> hasOrigins(List<String> origins) async => false;
  @override
  List<ClientToolGroup> toolGroups() => const <ClientToolGroup>[];
  @override
  void Function() onToolGroupsChanged(
    void Function(List<ClientToolGroup> groups) listener,
  ) => () {};
  @override
  Future<ExtensionToolResult> callTool(
    String group,
    String tool,
    String argumentsJson,
  ) async => const ExtensionToolResult.failure(
    'Browser tools are only available in the browser extension.',
  );
  @override
  void setVisible(bool visible) {}
  @override
  Future<bool> openSidePanel() async => false;
  @override
  Future<bool> requestSiteAccess(String origin) async => false;
}
