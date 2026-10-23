import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';

export 'package:core_business_logic/core_business_logic.dart'
    show ClientToolDefinition, ClientToolGroup;

/// The stored pairing of this browser extension with an engine
/// (`chrome.storage.local['connection']`, contracts.md section 5).
final class ExtensionConnection {
  const ExtensionConnection({
    this.engineUrl,
    this.engineToken,
    this.clientId,
    this.expiresAt,
    this.serverUrl,
    this.environment,
  });

  /// Parses the host's JSON string; `"null"`, empty or malformed text gives
  /// null.
  static ExtensionConnection? tryParse(String? json) {
    if (json == null || json.trim().isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final Map<dynamic, dynamic> map = decoded;
    String? text(String key) {
      final Object? value = map[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    final ExtensionConnection connection = ExtensionConnection(
      engineUrl: text('engineUrl'),
      engineToken: text('engineToken'),
      clientId: text('clientId'),
      expiresAt: text('expiresAt'),
      serverUrl: text('serverUrl'),
      environment: text('environment'),
    );
    return connection.isEmpty ? null : connection;
  }

  final String? engineUrl;
  final String? engineToken;
  final String? clientId;
  final String? expiresAt;
  final String? serverUrl;
  final String? environment;

  bool get isEmpty =>
      engineUrl == null &&
      engineToken == null &&
      clientId == null &&
      expiresAt == null &&
      serverUrl == null &&
      environment == null;

  /// True when an engine URL and token are stored.
  bool get isPaired =>
      (engineUrl ?? '').isNotEmpty && (engineToken ?? '').isNotEmpty;

  ExtensionConnection copyWith({
    String? engineUrl,
    String? engineToken,
    String? clientId,
    String? expiresAt,
    String? serverUrl,
    String? environment,
  }) => ExtensionConnection(
    engineUrl: engineUrl ?? this.engineUrl,
    engineToken: engineToken ?? this.engineToken,
    clientId: clientId ?? this.clientId,
    expiresAt: expiresAt ?? this.expiresAt,
    serverUrl: serverUrl ?? this.serverUrl,
    environment: environment ?? this.environment,
  );

  /// Only the fields that are set: the host merge-writes them.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'engineUrl': ?engineUrl,
    'engineToken': ?engineToken,
    'clientId': ?clientId,
    'expiresAt': ?expiresAt,
    'serverUrl': ?serverUrl,
    'environment': ?environment,
  };
}

/// What `callTool` answers: `{ok:true,result}` or `{ok:false,error}`.
final class ExtensionToolResult {
  const ExtensionToolResult.success(this.result) : ok = true, error = null;
  const ExtensionToolResult.failure(this.error) : ok = false, result = null;

  /// Parses the host's JSON string. Anything unreadable is a failure.
  factory ExtensionToolResult.parse(String json) {
    try {
      final Object? decoded = jsonDecode(json);
      if (decoded is Map) {
        if (decoded['ok'] == true) {
          return ExtensionToolResult.success(decoded['result']);
        }
        final Object? error = decoded['error'];
        return ExtensionToolResult.failure(
          error is String && error.isNotEmpty
              ? error
              : 'The browser tool failed.',
        );
      }
    } on FormatException {
      // Falls through to the failure below.
    }
    return const ExtensionToolResult.failure(
      'The browser tool returned an unreadable answer.',
    );
  }

  final bool ok;
  final Object? result;
  final String? error;
}

/// Parses `toolGroups()` / `onToolGroupsChanged` JSON into groups.
List<ClientToolGroup> parseToolGroups(String? json) {
  if (json == null || json.trim().isEmpty) return const <ClientToolGroup>[];
  try {
    return ClientToolGroup.parseList(jsonDecode(json));
  } on FormatException {
    return const <ClientToolGroup>[];
  }
}
