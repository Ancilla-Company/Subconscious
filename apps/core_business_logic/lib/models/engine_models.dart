import 'dart:convert';

DateTime? _dateTimeFromJson(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}

String? _dateTimeToJson(DateTime? value) => value?.toUtc().toIso8601String();

Object? _jsonValue(
  Map<String, dynamic> json,
  String camelCaseKey,
  String snakeCaseKey,
) => json[camelCaseKey] ?? json[snakeCaseKey];

String? _stringValue(
  Map<String, dynamic> json,
  String camelCaseKey,
  String snakeCaseKey,
) {
  final Object? value = _jsonValue(json, camelCaseKey, snakeCaseKey);
  return value is String ? value : null;
}

int? _intValue(
  Map<String, dynamic> json,
  String camelCaseKey,
  String snakeCaseKey,
) {
  final Object? value = _jsonValue(json, camelCaseKey, snakeCaseKey);
  return value is int
      ? value
      : value is num
      ? value.toInt()
      : null;
}

final class EngineRuntimeInfo {
  const EngineRuntimeInfo({
    required this.host,
    required this.port,
    required this.token,
    required this.pid,
    required this.version,
    this.nodeId,
  });
  final String host;
  final int port;
  final String token;
  final int pid;
  final String version;
  final String? nodeId;

  factory EngineRuntimeInfo.fromJson(Map<String, dynamic> json) =>
      EngineRuntimeInfo(
        host:
            _stringValue(json, 'host', 'host') ??
            (throw const FormatException('Runtime host is required.')),
        port:
            _intValue(json, 'port', 'port') ??
            (throw const FormatException('Runtime port is required.')),
        token:
            _stringValue(json, 'token', 'token') ??
            (throw const FormatException('Runtime token is required.')),
        pid: _intValue(json, 'pid', 'pid') ?? 0,
        version: _stringValue(json, 'version', 'version') ?? 'unknown',
        nodeId: _stringValue(json, 'nodeId', 'node_id'),
      );
  Map<String, dynamic> toJson() => <String, dynamic>{
    'host': host,
    'port': port,
    'token': token,
    'pid': pid,
    'version': version,
    if (nodeId != null) 'node_id': nodeId,
  };
  Uri get httpUri =>
      Uri(scheme: 'http', host: host, port: port, path: '/api/v1/');
  Uri get webSocketUri => Uri(
    scheme: 'ws',
    host: host,
    port: port,
    path: '/api/v1/events',
    queryParameters: <String, String>{'token': token},
  );
}

final class Workspace {
  const Workspace({
    required this.uuid,
    required this.name,
    this.id,
    this.description,
    this.defaultModelId,
    this.toolsConfig,
    this.directories,
    this.approvalConfig,
    this.ragConfig,
    this.createdAt,
    this.updatedAt,
  });
  final String uuid;
  final String name;
  final int? id;
  final String? description;
  final String? defaultModelId;
  final String? toolsConfig;
  final String? directories;
  final String? approvalConfig;
  final String? ragConfig;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory Workspace.fromJson(Map<String, dynamic> json) => Workspace(
    id: _intValue(json, 'id', 'id'),
    uuid:
        _stringValue(json, 'uuid', 'uuid') ??
        (throw const FormatException('Workspace uuid is required.')),
    name:
        _stringValue(json, 'name', 'name') ??
        (throw const FormatException('Workspace name is required.')),
    description: _stringValue(json, 'description', 'description'),
    defaultModelId: _stringValue(json, 'defaultModelId', 'default_model_id'),
    toolsConfig: _stringValue(json, 'toolsConfig', 'tools_config'),
    directories: _stringValue(json, 'directories', 'directories'),
    approvalConfig: _stringValue(json, 'approvalConfig', 'approval_config'),
    ragConfig: _stringValue(json, 'ragConfig', 'rag_config'),
    createdAt: _dateTimeFromJson(_jsonValue(json, 'createdAt', 'created_at')),
    updatedAt: _dateTimeFromJson(_jsonValue(json, 'updatedAt', 'updated_at')),
  );
}

final class ThreadInfo {
  const ThreadInfo({
    required this.uuid,
    required this.workspaceUuid,
    this.id,
    this.title,
    this.description,
    this.defaultModelId,
    this.toolsConfig,
    this.createdAt,
    this.updatedAt,
  });
  final String uuid;
  final String workspaceUuid;
  final int? id;
  final String? title;
  final String? description;
  final String? defaultModelId;
  final String? toolsConfig;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory ThreadInfo.fromJson(Map<String, dynamic> json) => ThreadInfo(
    id: _intValue(json, 'id', 'id'),
    uuid:
        _stringValue(json, 'uuid', 'uuid') ??
        (throw const FormatException('Thread uuid is required.')),
    workspaceUuid:
        _stringValue(json, 'workspaceUuid', 'workspace_uuid') ??
        (throw const FormatException('Thread workspaceUuid is required.')),
    title: _stringValue(json, 'title', 'title'),
    description: _stringValue(json, 'description', 'description'),
    defaultModelId: _stringValue(json, 'defaultModelId', 'default_model_id'),
    toolsConfig: _stringValue(json, 'toolsConfig', 'tools_config'),
    createdAt: _dateTimeFromJson(_jsonValue(json, 'createdAt', 'created_at')),
    updatedAt: _dateTimeFromJson(_jsonValue(json, 'updatedAt', 'updated_at')),
  );
}

final class ChatMessage {
  const ChatMessage({
    required this.uuid,
    required this.threadUuid,
    required this.role,
    required this.content,
    this.createdAt,
  });
  final String uuid;
  final String threadUuid;
  final String role;
  final String content;
  final DateTime? createdAt;

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    uuid: json['uuid'] as String,
    threadUuid: json['threadUuid'] as String,
    role: json['role'] as String,
    content: json['content'] as String,
    createdAt: _dateTimeFromJson(json['createdAt']),
  );
  Map<String, dynamic> toJson() => <String, dynamic>{
    'uuid': uuid,
    'threadUuid': threadUuid,
    'role': role,
    'content': content,
    if (_dateTimeToJson(createdAt) != null)
      'createdAt': _dateTimeToJson(createdAt),
  };
}

final class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.name,
    required this.provider,
    this.description,
  });
  final String id;
  final String name;
  final String provider;
  final String? description;

  factory ModelInfo.fromJson(Map<String, dynamic> json) => ModelInfo(
    id: json['id'] as String,
    name: json['name'] as String,
    provider: json['provider'] as String,
    description: json['description'] as String?,
  );
}

final class AppStateEntry {
  const AppStateEntry({
    required this.key,
    required this.value,
    required this.updatedAt,
  });

  final String key;
  final String value;
  final DateTime updatedAt;

  factory AppStateEntry.fromJson(Map<String, dynamic> json) => AppStateEntry(
    key:
        _stringValue(json, 'key', 'key') ??
        (throw const FormatException('App state key is required.')),
    value:
        _stringValue(json, 'value', 'value') ??
        (throw const FormatException('App state value is required.')),
    updatedAt:
        _dateTimeFromJson(_jsonValue(json, 'updatedAt', 'updated_at')) ??
        (throw const FormatException('App state updatedAt is required.')),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'key': key,
    'value': value,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

final class EngineSetting {
  const EngineSetting({
    required this.key,
    required this.value,
    this.tag,
    this.client,
  });
  final String key;
  final String value;
  final String? tag;
  final String? client;

  factory EngineSetting.fromJson(Map<String, dynamic> json) => EngineSetting(
    key: json['key'] as String,
    value: json['value'] as String,
    tag: json['tag'] as String?,
    client: json['client'] as String?,
  );
  Map<String, dynamic> toJson() => <String, dynamic>{
    'key': key,
    'value': value,
    if (tag != null) 'tag': tag,
    if (client != null) 'client': client,
  };
}

final class WorkspaceFileEntry {
  const WorkspaceFileEntry({
    required this.name,
    required this.relativePath,
    required this.isDirectory,
  });
  final String name;
  final String relativePath;
  final bool isDirectory;

  factory WorkspaceFileEntry.fromJson(Map<String, dynamic> json) =>
      WorkspaceFileEntry(
        name: json['name'] as String,
        relativePath: json['relativePath'] as String,
        isDirectory: json['isDirectory'] as bool,
      );
}

final class WireFrame {
  const WireFrame({required this.type, this.id, this.data, this.version = 1});
  final String type;
  final String? id;
  final Map<String, dynamic>? data;
  final int version;

  factory WireFrame.fromJson(Map<String, dynamic> json) => WireFrame(
    type: json['type'] as String,
    id: json['id'] as String?,
    data: json['data'] is Map
        ? (json['data'] as Map).cast<String, dynamic>()
        : null,
    version: json['v'] as int? ?? 1,
  );
  factory WireFrame.decode(String value) =>
      WireFrame.fromJson(jsonDecode(value) as Map<String, dynamic>);
  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': version,
    'type': type,
    if (id != null) 'id': id,
    if (data != null) 'data': data,
  };
  String encode() => jsonEncode(toJson());
}

final class WorkspaceFileContent {
  const WorkspaceFileContent({required this.content});
  final String content;

  factory WorkspaceFileContent.fromJson(Map<String, dynamic> json) =>
      WorkspaceFileContent(
        content: _stringValue(json, 'content', 'content') ?? '',
      );
}

final class WorkspaceFilePreview {
  const WorkspaceFilePreview({
    required this.localPath,
    required this.mediaType,
  });

  final String localPath;
  final String mediaType;

  factory WorkspaceFilePreview.fromJson(Map<String, dynamic> json) =>
      WorkspaceFilePreview(
        localPath:
            _stringValue(json, 'localPath', 'local_path') ??
            (throw const FormatException('Preview path is required.')),
        mediaType:
            _stringValue(json, 'mediaType', 'media_type') ??
            'application/octet-stream',
      );
}

final class ModelConfiguration {
  const ModelConfiguration({
    required this.id,
    required this.provider,
    required this.model,
    this.alias,
    this.baseUrl,
    this.contextWindow,
    this.hasApiKey = false,
  });
  final String id;
  final String provider;
  final String model;
  final String? alias;
  final String? baseUrl;
  final int? contextWindow;
  final bool hasApiKey;

  factory ModelConfiguration.fromJson(
    Map<String, dynamic> json,
  ) => ModelConfiguration(
    id:
        _stringValue(json, 'id', 'id') ??
        (throw const FormatException('Model configuration id is required.')),
    provider:
        _stringValue(json, 'provider', 'provider') ??
        (throw const FormatException(
          'Model configuration provider is required.',
        )),
    model:
        _stringValue(json, 'model', 'model') ??
        (throw const FormatException('Model configuration model is required.')),
    alias: _stringValue(json, 'alias', 'alias'),
    baseUrl: _stringValue(json, 'baseUrl', 'base_url'),
    contextWindow: _intValue(json, 'contextWindow', 'context_window'),
    hasApiKey: _jsonValue(json, 'hasApiKey', 'has_api_key') as bool? ?? false,
  );
}

final class ModelConfigurationRequest {
  const ModelConfigurationRequest({
    required this.provider,
    required this.model,
    this.alias,
    this.baseUrl,
    this.contextWindow,
    this.apiKey,
    this.clearApiKey = false,
  });
  final String provider;
  final String model;
  final String? alias;
  final String? baseUrl;
  final int? contextWindow;
  final String? apiKey;
  final bool clearApiKey;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider': provider,
    'model': model,
    if (alias != null) 'alias': alias,
    if (baseUrl != null) 'baseUrl': baseUrl,
    if (contextWindow != null) 'contextWindow': contextWindow,
    if (apiKey != null) 'apiKey': apiKey,
    if (clearApiKey) 'clearApiKey': true,
  };
}

final class BuiltinToolCatalogEntry {
  const BuiltinToolCatalogEntry({
    required this.name,
    required this.doc,
    required this.operation,
  });
  final String name;
  final String doc;
  final String operation;

  factory BuiltinToolCatalogEntry.fromJson(Map<String, dynamic> json) =>
      BuiltinToolCatalogEntry(
        name: _stringValue(json, 'name', 'name') ?? '',
        doc: _stringValue(json, 'doc', 'doc') ?? '',
        operation: _stringValue(json, 'operation', 'operation') ?? 'query',
      );
}

final class ToolRegistryEntry {
  const ToolRegistryEntry({
    required this.id,
    required this.uuid,
    required this.name,
    required this.toolType,
    required this.status,
    this.alias,
    this.description,
    this.scriptPath,
    this.scriptLanguage,
    this.endpointUrl,
    this.authType,
    this.hasAuthConfig = false,
    this.createdAt,
    this.updatedAt,
  });
  final int id;
  final String uuid;
  final String name;
  final String toolType;
  final String status;
  final String? alias;
  final String? description;
  final String? scriptPath;
  final String? scriptLanguage;
  final String? endpointUrl;
  final String? authType;
  final bool hasAuthConfig;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory ToolRegistryEntry.fromJson(
    Map<String, dynamic> json,
  ) => ToolRegistryEntry(
    id: _intValue(json, 'id', 'id') ?? 0,
    uuid:
        _stringValue(json, 'uuid', 'uuid') ??
        (throw const FormatException('Tool registry uuid is required.')),
    name: _stringValue(json, 'name', 'name') ?? '',
    toolType: _stringValue(json, 'toolType', 'tool_type') ?? 'script',
    status: _stringValue(json, 'status', 'status') ?? 'active',
    alias: _stringValue(json, 'alias', 'alias'),
    description: _stringValue(json, 'description', 'description'),
    scriptPath: _stringValue(json, 'scriptPath', 'script_path'),
    scriptLanguage: _stringValue(json, 'scriptLanguage', 'script_language'),
    endpointUrl: _stringValue(json, 'endpointUrl', 'endpoint_url'),
    authType: _stringValue(json, 'authType', 'auth_type'),
    hasAuthConfig:
        _jsonValue(json, 'hasAuthConfig', 'has_auth_config') as bool? ?? false,
    createdAt: _dateTimeFromJson(_jsonValue(json, 'createdAt', 'created_at')),
    updatedAt: _dateTimeFromJson(_jsonValue(json, 'updatedAt', 'updated_at')),
  );
}

final class ToolRegistryRequest {
  const ToolRegistryRequest({
    this.name,
    this.alias,
    this.description,
    this.toolType,
    this.scriptPath,
    this.scriptLanguage,
    this.endpointUrl,
    this.authType,
    this.authConfigJson,
    this.clearAuthConfig = false,
    this.status,
  });
  final String? name;
  final String? alias;
  final String? description;
  final String? toolType;
  final String? scriptPath;
  final String? scriptLanguage;
  final String? endpointUrl;
  final String? authType;
  final String? authConfigJson;
  final bool clearAuthConfig;
  final String? status;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (name != null) 'name': name,
    if (alias != null) 'alias': alias,
    if (description != null) 'description': description,
    if (toolType != null) 'toolType': toolType,
    if (scriptPath != null) 'scriptPath': scriptPath,
    if (scriptLanguage != null) 'scriptLanguage': scriptLanguage,
    if (endpointUrl != null) 'endpointUrl': endpointUrl,
    if (authType != null) 'authType': authType,
    if (authConfigJson != null) 'authConfigJson': authConfigJson,
    if (clearAuthConfig) 'clearAuthConfig': true,
    if (status != null) 'status': status,
  };
}

final class ToolCatalog {
  const ToolCatalog({required this.builtin, required this.configured});
  final Map<String, List<BuiltinToolCatalogEntry>> builtin;
  final List<ToolRegistryEntry> configured;

  factory ToolCatalog.fromJson(Map<String, dynamic> json) {
    final Map<String, List<BuiltinToolCatalogEntry>> builtin =
        <String, List<BuiltinToolCatalogEntry>>{};
    final dynamic rawBuiltin = _jsonValue(json, 'builtin', 'builtin');
    if (rawBuiltin is Map) {
      for (final MapEntry<Object?, Object?> entry in rawBuiltin.entries) {
        final dynamic rawItems = entry.value;
        if (rawItems is List)
          builtin['${entry.key}'] = rawItems
              .map(
                (dynamic item) => BuiltinToolCatalogEntry.fromJson(
                  (item as Map).cast<String, dynamic>(),
                ),
              )
              .toList(growable: false);
      }
    }
    final dynamic rawConfigured = _jsonValue(json, 'configured', 'configured');
    final List<ToolRegistryEntry> configured = rawConfigured is List
        ? rawConfigured
              .map(
                (dynamic item) => ToolRegistryEntry.fromJson(
                  (item as Map).cast<String, dynamic>(),
                ),
              )
              .toList(growable: false)
        : <ToolRegistryEntry>[];
    return ToolCatalog(builtin: builtin, configured: configured);
  }
}
