/// A tool a client (browser extension, later VS Code) offers to the engine.
/// Wire shape: `.agents/tasks/extension-tools-pairing/contracts.md` section 1.
final class ClientToolDefinition {
  const ClientToolDefinition({
    required this.id,
    required this.description,
    required this.inputSchema,
    required this.operation,
    this.readOnly = false,
    this.timeoutSeconds,
  });

  /// Parses a tool as written by the host (`input_schema`, `read_only`, ...).
  /// Returns null when the id is missing.
  static ClientToolDefinition? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final Object? schema = raw['input_schema'];
    final Object? timeout = raw['timeout_seconds'];
    return ClientToolDefinition(
      id: id,
      description: raw['description'] is String
          ? raw['description']! as String
          : '',
      inputSchema: schema is Map
          ? schema.cast<String, dynamic>()
          : const <String, dynamic>{'type': 'object'},
      operation: raw['operation'] is String
          ? raw['operation']! as String
          : 'update',
      readOnly: raw['read_only'] == true,
      timeoutSeconds: timeout is num ? timeout.toInt() : null,
    );
  }

  final String id;
  final String description;
  final Map<String, dynamic> inputSchema;

  /// `read`, `create`, `update`, `delete` or `execute`.
  final String operation;
  final bool readOnly;
  final int? timeoutSeconds;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'description': description,
    'input_schema': inputSchema,
    'operation': operation,
    'read_only': readOnly,
    if (timeoutSeconds != null) 'timeout_seconds': timeoutSeconds,
  };
}

/// A named group of client tools. Registering a group replaces every tool of
/// that group on the connection; an empty [tools] list removes it.
final class ClientToolGroup {
  const ClientToolGroup({
    required this.group,
    required this.title,
    required this.tools,
  });

  static ClientToolGroup? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? group = raw['group'];
    if (group is! String || group.isEmpty) return null;
    final Object? tools = raw['tools'];
    return ClientToolGroup(
      group: group,
      title: raw['title'] is String ? raw['title']! as String : group,
      tools: <ClientToolDefinition>[
        if (tools is List)
          for (final Object? tool in tools)
            if (ClientToolDefinition.tryParse(tool)
                case final ClientToolDefinition parsed)
              parsed,
      ],
    );
  }

  /// Parses a JSON list of groups; malformed entries are skipped.
  static List<ClientToolGroup> parseList(Object? raw) => <ClientToolGroup>[
    if (raw is List)
      for (final Object? item in raw)
        if (tryParse(item) case final ClientToolGroup parsed) parsed,
  ];

  final String group;
  final String title;
  final List<ClientToolDefinition> tools;

  bool get isEmpty => tools.isEmpty;

  /// The `data` of a `tool.register` frame.
  Map<String, dynamic> toRegisterData() => <String, dynamic>{
    'group': group,
    'title': title,
    'tools': <Map<String, dynamic>>[
      for (final ClientToolDefinition tool in tools) tool.toJson(),
    ],
  };
}
