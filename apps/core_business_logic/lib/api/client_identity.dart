/// Wire values for the engine's `client_type` parameter. Keep in sync with
/// `CLIENT_TYPES` in `engine/src/subconscious_engine/client_identity.py`.
abstract final class ClientType {
  static const String desktop = 'desktop';
  static const String mobile = 'mobile';
  static const String tui = 'tui';
  static const String browserExtension = 'browser_extension';
  static const String cli = 'cli';
  static const String web = 'web';
  static const String vscode = 'vscode';
}

/// Who this client tells the engine it is (shown in the engine tray menu).
final class ClientIdentity {
  const ClientIdentity({required this.type, this.name, this.version});

  final String type;
  final String? name;
  final String? version;

  /// Returns [endpoint] with the identity query parameters added, keeping
  /// every existing parameter (token, etc.).
  Uri withQuery(Uri endpoint) => endpoint.replace(
    queryParameters: <String, String>{
      ...endpoint.queryParameters,
      'client_type': type,
      if (name != null && name!.isNotEmpty) 'client_name': name!,
      if (version != null && version!.isNotEmpty) 'client_version': version!,
    },
  );

  /// The same identity as `client.hello` data (used when query parameters are
  /// not available, e.g. hive peers).
  Map<String, dynamic> helloData() => <String, dynamic>{
    'clientType': type,
    if (name != null && name!.isNotEmpty) 'clientName': name,
    if (version != null && version!.isNotEmpty) 'clientVersion': version,
  };
}
