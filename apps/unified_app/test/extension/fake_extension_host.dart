import 'dart:async';

import 'package:unified_app/features/extension/extension_host.dart';

/// A scriptable [ExtensionHost] standing in for the JavaScript host.
final class FakeExtensionHost implements ExtensionHost {
  FakeExtensionHost({
    this.isExtension = true,
    this.extensionOrigin =
        'chrome-extension://abcdefghijklmnopabcdefghijklmnop',
    this.extensionVersion = '1.2.3',
    List<ClientToolGroup>? groups,
    this.connection,
    this.grantOrigins = true,
  }) : groups = groups ?? <ClientToolGroup>[];

  @override
  final bool isExtension;
  @override
  final String extensionOrigin;
  @override
  final String extensionVersion;
  @override
  String mode = 'panel';
  @override
  int instanceSlot = 0;
  @override
  String deviceName = 'Browser extension (Chrome)';
  int slotsAcquired = 0;

  @override
  Future<void> acquireInstanceSlot() async => slotsAcquired++;

  List<ClientToolGroup> groups;
  ExtensionConnection? connection;
  bool grantOrigins;

  final List<String> requestedOrigins = <String>[];
  final List<bool> visibility = <bool>[];
  final List<(String, String, String)> calls = <(String, String, String)>[];
  final List<void Function(List<ClientToolGroup>)> listeners =
      <void Function(List<ClientToolGroup>)>[];
  int unsubscribed = 0;
  int cleared = 0;

  /// Answers `callTool`; defaults to `{ok:true,result:{echo: ...}}`.
  Future<ExtensionToolResult> Function(String group, String tool, String args)?
  onCall;

  void emitGroups(List<ClientToolGroup> next) {
    groups = next;
    for (final void Function(List<ClientToolGroup>) listener
        in List<void Function(List<ClientToolGroup>)>.of(listeners)) {
      listener(next);
    }
  }

  @override
  Future<ExtensionConnection?> getConnection() async => connection;
  @override
  Future<void> setConnection(ExtensionConnection value) async {
    connection = ExtensionConnection(
      engineUrl: value.engineUrl ?? connection?.engineUrl,
      engineToken: value.engineToken ?? connection?.engineToken,
      clientId: value.clientId ?? connection?.clientId,
      expiresAt: value.expiresAt ?? connection?.expiresAt,
      serverUrl: value.serverUrl ?? connection?.serverUrl,
      environment: value.environment ?? connection?.environment,
    );
  }

  @override
  Future<void> clearConnection() async {
    cleared++;
    connection = null;
  }

  @override
  Future<bool> requestOrigins(List<String> origins) async {
    requestedOrigins.addAll(origins);
    return grantOrigins;
  }

  @override
  Future<bool> hasOrigins(List<String> origins) async => grantOrigins;
  @override
  List<ClientToolGroup> toolGroups() => groups;

  @override
  void Function() onToolGroupsChanged(
    void Function(List<ClientToolGroup> groups) listener,
  ) {
    listeners.add(listener);
    return () {
      unsubscribed++;
      listeners.remove(listener);
    };
  }

  @override
  Future<ExtensionToolResult> callTool(
    String group,
    String tool,
    String argumentsJson,
  ) async {
    calls.add((group, tool, argumentsJson));
    final Future<ExtensionToolResult> Function(String, String, String)?
    handler = onCall;
    if (handler != null) return handler(group, tool, argumentsJson);
    return ExtensionToolResult.success(<String, dynamic>{'tool': tool});
  }

  @override
  void setVisible(bool visible) => visibility.add(visible);
  @override
  Future<bool> openSidePanel() async => true;
  @override
  Future<bool> requestSiteAccess(String origin) async => true;
}

const ClientToolGroup browserGroup = ClientToolGroup(
  group: 'browser',
  title: 'Browser',
  tools: <ClientToolDefinition>[
    ClientToolDefinition(
      id: 'read_page',
      description: 'Read the page.',
      inputSchema: <String, dynamic>{'type': 'object'},
      operation: 'read',
      readOnly: true,
    ),
    ClientToolDefinition(
      id: 'open_tab',
      description: 'Open a tab.',
      inputSchema: <String, dynamic>{'type': 'object'},
      operation: 'create',
    ),
  ],
);
