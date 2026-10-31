import 'dart:convert';
import 'dart:typed_data';

DateTime? _dateTimeFromJson(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}

List<String> _stringListValue(Object? value) => value is List
    ? <String>[for (final Object? item in value) if (item is String) item]
    : const <String>[];

Map<String, String> _stringMapValue(Object? value) => value is Map
    ? <String, String>{
        for (final MapEntry<Object?, Object?> entry in value.entries)
          if (entry.key is String && entry.value is String)
            entry.key! as String: entry.value! as String,
      }
    : const <String, String>{};

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

/// What a model can do. `null` means unknown, which is not the same as false.
///
/// The engine decides these from the user's override, a capability service
/// and built-in heuristics, so the app only reads them.
final class ModelCapabilities {
  const ModelCapabilities({
    this.chat,
    this.toolCalling,
    this.vision,
    this.audioInput,
    this.audioOutput,
    this.speechToText,
    this.textToSpeech,
    this.realtime,
    this.sources = const <String>[],
  });

  /// Flags the user may set, as sent to the engine.
  static const List<String> flags = <String>[
    'chat',
    'tool_calling',
    'vision',
    'audio_input',
    'audio_output',
    'speech_to_text',
    'text_to_speech',
    'realtime',
  ];

  final bool? chat;
  final bool? toolCalling;
  final bool? vision;
  final bool? audioInput;
  final bool? audioOutput;
  final bool? speechToText;
  final bool? textToSpeech;
  final bool? realtime;
  final List<String> sources;

  /// False only when the engine says this is not a chat model (for example a
  /// transcription model), so it stays out of the chat model picker.
  bool get isChatModel => chat != false;
  bool get canTranscribe => speechToText == true;
  bool get canSpeak => textToSpeech == true;
  bool get canRealtime => realtime == true;

  factory ModelCapabilities.fromJson(Map<String, dynamic> json) {
    bool? flag(String snake, String camel) {
      final Object? value = json[camel] ?? json[snake];
      return value is bool ? value : null;
    }

    final Object? sources = json['sources'];
    return ModelCapabilities(
      chat: flag('chat', 'chat'),
      toolCalling: flag('tool_calling', 'toolCalling'),
      vision: flag('vision', 'vision'),
      audioInput: flag('audio_input', 'audioInput'),
      audioOutput: flag('audio_output', 'audioOutput'),
      speechToText: flag('speech_to_text', 'speechToText'),
      textToSpeech: flag('text_to_speech', 'textToSpeech'),
      realtime: flag('realtime', 'realtime'),
      sources: sources is List
          ? sources.whereType<String>().toList(growable: false)
          : const <String>[],
    );
  }
}

final class ModelInfo {
  const ModelInfo({
    required this.id,
    required this.name,
    required this.provider,
    this.description,
    this.capabilities,
  });
  final String id;
  final String name;
  final String provider;
  final String? description;
  final ModelCapabilities? capabilities;

  /// Older engines send no capabilities; treat those as plain chat models.
  bool get isChatModel => capabilities?.isChatModel ?? true;

  factory ModelInfo.fromJson(Map<String, dynamic> json) => ModelInfo(
    id: json['id'] as String,
    name: json['name'] as String,
    provider: json['provider'] as String,
    description: json['description'] as String?,
    capabilities: json['capabilities'] is Map
        ? ModelCapabilities.fromJson(
            (json['capabilities'] as Map).cast<String, dynamic>(),
          )
        : null,
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

final class WorkspaceFileMatch {
  const WorkspaceFileMatch({
    required this.rootIndex,
    required this.name,
    required this.relativePath,
  });

  final int rootIndex;
  final String name;
  final String relativePath;

  factory WorkspaceFileMatch.fromJson(Map<String, dynamic> json) =>
      WorkspaceFileMatch(
        rootIndex: json['rootIndex'] as int,
        name: json['name'] as String,
        relativePath: json['relativePath'] as String,
      );
}

final class ChatFileReference {
  const ChatFileReference({
    required this.rootIndex,
    required this.path,
    String? label,
  }) : label = label ?? path;

  final int rootIndex;
  final String path;
  final String label;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'root_index': rootIndex,
    'path': path,
    'label': label,
  };
}

final class ChatAttachment {
  const ChatAttachment({
    required this.id,
    required this.name,
    required this.mediaType,
    required this.bytes,
  });

  final String id;
  final String name;
  final String mediaType;
  final Uint8List bytes;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'media_type': mediaType,
    'data': base64Encode(bytes),
  };
}

final class ChatFileContext {
  const ChatFileContext({
    this.activeFile,
    this.taggedFiles = const <ChatFileReference>[],
    this.attachments = const <ChatAttachment>[],
  });

  final ChatFileReference? activeFile;
  final List<ChatFileReference> taggedFiles;
  final List<ChatAttachment> attachments;

  bool get isEmpty =>
      activeFile == null && taggedFiles.isEmpty && attachments.isEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (activeFile != null) 'active_file': activeFile!.toJson(),
    'tagged_files': <Map<String, dynamic>>[
      for (final ChatFileReference file in taggedFiles) file.toJson(),
    ],
    'attachments': <Map<String, dynamic>>[
      for (final ChatAttachment attachment in attachments) attachment.toJson(),
    ],
  };
}

final class ToolApprovalRequest {
  const ToolApprovalRequest({
    required this.turnId,
    required this.approvalId,
    required this.threadUuid,
    required this.toolName,
    required this.arguments,
    required this.operation,
    this.remote = false,
    this.peerName,
    this.peerNodeId,
  });

  final String turnId;
  final String approvalId;
  final String threadUuid;
  final String toolName;
  final Map<String, dynamic> arguments;
  final String operation;

  /// True when a hive peer asks to run one of this node's exported tools.
  final bool remote;
  final String? peerName;
  final String? peerNodeId;
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
  const WorkspaceFileContent({required this.content, this.version});
  final String content;

  /// Hash of the exact bytes on disk. Send it back as `expectedVersion` so the
  /// engine can refuse a save that would overwrite a newer change.
  final String? version;

  factory WorkspaceFileContent.fromJson(Map<String, dynamic> json) =>
      WorkspaceFileContent(
        content: _stringValue(json, 'content', 'content') ?? '',
        version: _stringValue(json, 'version', 'version'),
      );
}

/// Cheap description of a file on disk, used to notice external changes
/// without downloading the content.
final class WorkspaceFileVersion {
  const WorkspaceFileVersion({required this.version, required this.size});
  final String version;
  final int size;

  factory WorkspaceFileVersion.fromJson(Map<String, dynamic> json) =>
      WorkspaceFileVersion(
        version:
            _stringValue(json, 'version', 'version') ??
            (throw const FormatException('File version is required.')),
        size: (json['size'] as num?)?.toInt() ?? 0,
      );
}

enum WorkspacePreviewKind {
  image,
  pdf,
  docx;

  factory WorkspacePreviewKind.fromHeader(String value) => switch (value) {
    'image' => WorkspacePreviewKind.image,
    'pdf' => WorkspacePreviewKind.pdf,
    'docx' => WorkspacePreviewKind.docx,
    _ => throw const FormatException('Unsupported workspace preview kind.'),
  };
}

final class WorkspaceFilePreview {
  const WorkspaceFilePreview({
    required this.kind,
    required this.mediaType,
    required this.bytes,
    this.filename,
  });

  final WorkspacePreviewKind kind;
  final String mediaType;
  final Uint8List bytes;
  final String? filename;
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
    this.capabilities,
  });
  final String id;
  final String provider;
  final String model;
  final String? alias;
  final String? baseUrl;
  final int? contextWindow;
  final bool hasApiKey;

  /// The user's explicit capability flags only (snake_case keys).
  final Map<String, bool>? capabilities;

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
    capabilities: json['capabilities'] is Map
        ? <String, bool>{
            for (final MapEntry<dynamic, dynamic> entry
                in (json['capabilities'] as Map).entries)
              if (entry.key is String && entry.value is bool)
                entry.key as String: entry.value as bool,
          }
        : null,
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
    this.capabilities,
  });
  final String provider;
  final String model;
  final String? alias;
  final String? baseUrl;
  final int? contextWindow;
  final String? apiKey;
  final bool clearApiKey;

  /// Explicit flags to store; null keeps what is stored, `{}` clears them.
  final Map<String, bool>? capabilities;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider': provider,
    'model': model,
    if (alias != null) 'alias': alias,
    if (baseUrl != null) 'baseUrl': baseUrl,
    if (contextWindow != null) 'contextWindow': contextWindow,
    if (apiKey != null) 'apiKey': apiKey,
    if (clearApiKey) 'clearApiKey': true,
    if (capabilities != null) 'capabilities': capabilities,
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
        operation: _stringValue(json, 'operation', 'operation') ?? 'read',
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
    this.oauthClientId,
    this.oauthScopes,
    this.oauthConnected,
    this.command,
    this.args = const <String>[],
    this.env = const <String, String>{},
    this.cwd,
    this.transport,
    this.permissions,
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
  final String? oauthClientId;
  final String? oauthScopes;

  /// Null unless [authType] is `oauth`.
  final bool? oauthConnected;
  final String? command;
  final List<String> args;
  final Map<String, String> env;
  final String? cwd;
  final String? transport;

  /// ACP agents only: `read_only` or `allow_all`.
  final String? permissions;
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
    oauthClientId: _stringValue(json, 'oauthClientId', 'oauth_client_id'),
    oauthScopes: _stringValue(json, 'oauthScopes', 'oauth_scopes'),
    oauthConnected: switch (_jsonValue(
      json,
      'oauthConnected',
      'oauth_connected',
    )) {
      final bool connected => connected,
      _ => null,
    },
    command: _stringValue(json, 'command', 'command'),
    args: _stringListValue(json['args']),
    env: _stringMapValue(json['env']),
    cwd: _stringValue(json, 'cwd', 'cwd'),
    transport: _stringValue(json, 'transport', 'transport'),
    permissions: _stringValue(json, 'permissions', 'permissions'),
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
    this.oauthClientId,
    this.oauthClientSecret,
    this.clearOauthClientSecret = false,
    this.oauthScopes,
    this.command,
    this.args,
    this.env,
    this.cwd,
    this.clearEndpointUrl = false,
    this.clearCommand = false,
    this.permissions,
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
  final String? oauthClientId;

  /// Write-only: the engine never returns it.
  final String? oauthClientSecret;
  final bool clearOauthClientSecret;

  /// Space separated scopes.
  final String? oauthScopes;
  final String? command;
  final List<String>? args;
  final Map<String, String>? env;
  final String? cwd;

  /// Sends an explicit ndpointUrl: null, so switching a tool away from HTTP
  /// does not leave the old URL behind.
  final bool clearEndpointUrl;

  /// Sends explicit nulls for command/args/env/cwd (switching away from stdio).
  final bool clearCommand;

  /// ACP agents only: `read_only` or `allow_all`.
  final String? permissions;
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
    if (oauthClientId != null) 'oauthClientId': oauthClientId,
    if (oauthClientSecret != null) 'oauthClientSecret': oauthClientSecret,
    if (clearOauthClientSecret) 'clearOauthClientSecret': true,
    if (oauthScopes != null) 'oauthScopes': oauthScopes,
    if (clearEndpointUrl) 'endpointUrl': null,
    if (clearCommand) ...<String, dynamic>{
      'command': null,
      'args': null,
      'env': null,
      'cwd': null,
    } else ...<String, dynamic>{
      if (command != null) 'command': command,
      if (args != null) 'args': args,
      if (env != null) 'env': env,
      if (cwd != null) 'cwd': cwd,
    },
    if (permissions != null) 'permissions': permissions,
    if (status != null) 'status': status,
  };
}

/// One tool a registered server exposes, as reported by a connection test.
final class ToolTestTool {
  const ToolTestTool({
    required this.name,
    this.description = '',
    this.operation = 'read',
  });
  final String name;
  final String description;
  final String operation;

  factory ToolTestTool.fromJson(Map<String, dynamic> json) => ToolTestTool(
    name: _stringValue(json, 'name', 'name') ?? '',
    description: _stringValue(json, 'description', 'description') ?? '',
    operation: _stringValue(json, 'operation', 'operation') ?? 'read',
  );
}

/// Result of POST /api/v1/tool-registry/{uuid}/test.
final class ToolTestResult {
  const ToolTestResult({
    required this.ok,
    this.tools = const <ToolTestTool>[],
    this.error,
    this.needsAuth = false,
  });
  final bool ok;
  final List<ToolTestTool> tools;
  final String? error;

  /// True when the server requires an OAuth sign-in first.
  final bool needsAuth;

  factory ToolTestResult.fromJson(Map<String, dynamic> json) => ToolTestResult(
    ok: json['ok'] as bool? ?? false,
    tools: json['tools'] is List
        ? <ToolTestTool>[
            for (final Object? item in json['tools'] as List<Object?>)
              if (item is Map<String, dynamic>) ToolTestTool.fromJson(item),
          ]
        : const <ToolTestTool>[],
    error: _stringValue(json, 'error', 'error'),
    needsAuth: json['needsAuth'] == true || json['needs_auth'] == true,
  );
}

/// An OAuth sign-in the engine is waiting on (`oauth.request` frame or
/// `GET oauth/pending`).
final class OAuthAuthorization {
  const OAuthAuthorization({
    required this.authId,
    required this.toolUuid,
    required this.toolName,
    required this.url,
    this.redirectUri = '',
    this.expiresAt,
    this.turnId,
    this.threadUuid,
  });
  final String authId;
  final String toolUuid;
  final String toolName;
  final String url;
  final String redirectUri;

  /// When the engine stops accepting the sign-in; null when unknown.
  final DateTime? expiresAt;
  final String? turnId;
  final String? threadUuid;

  /// Frame payload (snake_case); `expires_in` seconds are counted from [now].
  static OAuthAuthorization? tryParseFrame(
    Map<String, dynamic> data, {
    String? turnId,
    DateTime? now,
  }) {
    final Object? authId = data['auth_id'];
    final Object? toolUuid = data['tool_uuid'];
    final Object? url = data['url'];
    if (authId is! String ||
        authId.isEmpty ||
        toolUuid is! String ||
        url is! String ||
        url.isEmpty) {
      return null;
    }
    final Object? expires = data['expires_in'];
    return OAuthAuthorization(
      authId: authId,
      toolUuid: toolUuid,
      toolName: data['tool_name'] is String ? data['tool_name'] as String : '',
      url: url,
      redirectUri: data['redirect_uri'] is String
          ? data['redirect_uri'] as String
          : '',
      expiresAt: expires is num
          ? (now ?? DateTime.now()).add(Duration(seconds: expires.toInt()))
          : null,
      turnId: turnId,
      threadUuid: data['thread_uuid'] is String
          ? data['thread_uuid'] as String
          : null,
    );
  }

  /// Element of `GET oauth/pending` (camelCase).
  factory OAuthAuthorization.fromJson(Map<String, dynamic> json) =>
      OAuthAuthorization(
        authId:
            _stringValue(json, 'authId', 'auth_id') ??
            (throw const FormatException('OAuth authId is required.')),
        toolUuid: _stringValue(json, 'toolUuid', 'tool_uuid') ?? '',
        toolName: _stringValue(json, 'toolName', 'tool_name') ?? '',
        url:
            _stringValue(json, 'url', 'url') ??
            (throw const FormatException('OAuth url is required.')),
        redirectUri: _stringValue(json, 'redirectUri', 'redirect_uri') ?? '',
        expiresAt: _dateTimeFromJson(
          _jsonValue(json, 'expiresAt', 'expires_at'),
        ),
      );
}

/// Outcome reported by an `oauth.resolved` frame.
enum OAuthStatus {
  authorized,
  denied,
  expired,
  cancelled;

  static OAuthStatus? tryParse(Object? value) {
    for (final OAuthStatus status in OAuthStatus.values) {
      if (status.name == value) return status;
    }
    return null;
  }
}

/// Result of `POST tool-registry/{uuid}/authorize`.
final class ToolAuthorizeResult {
  const ToolAuthorizeResult({this.authId, this.url, required this.status});
  final String? authId;
  final String? url;

  /// `connected` or `pending`.
  final String status;

  bool get isConnected => status == 'connected';

  factory ToolAuthorizeResult.fromJson(Map<String, dynamic> json) =>
      ToolAuthorizeResult(
        authId: _stringValue(json, 'authId', 'auth_id'),
        url: _stringValue(json, 'url', 'url'),
        status: _stringValue(json, 'status', 'status') ?? 'pending',
      );
}

/// A skill: instructions the assistant can load when relevant.
final class SkillEntry {
  const SkillEntry({
    required this.uuid,
    required this.name,
    required this.sourceType,
    this.alias,
    this.description,
    this.source,
    this.instructions,
    this.enabled = true,
    this.valid = true,
    this.error,
    this.createdAt,
    this.updatedAt,
  });
  final String uuid;
  final String name;
  final String sourceType;
  final String? alias;
  final String? description;
  final String? source;
  final String? instructions;
  final bool enabled;
  final bool valid;
  final String? error;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory SkillEntry.fromJson(Map<String, dynamic> json) => SkillEntry(
    uuid:
        _stringValue(json, 'uuid', 'uuid') ??
        (throw const FormatException('Skill uuid is required.')),
    name: _stringValue(json, 'name', 'name') ?? '',
    sourceType: _stringValue(json, 'sourceType', 'source_type') ?? 'folder',
    alias: _stringValue(json, 'alias', 'alias'),
    description: _stringValue(json, 'description', 'description'),
    source: _stringValue(json, 'source', 'source'),
    instructions: _stringValue(json, 'instructions', 'instructions'),
    enabled: json['enabled'] as bool? ?? true,
    valid: json['valid'] as bool? ?? true,
    error: _stringValue(json, 'error', 'error'),
    createdAt: _dateTimeFromJson(_jsonValue(json, 'createdAt', 'created_at')),
    updatedAt: _dateTimeFromJson(_jsonValue(json, 'updatedAt', 'updated_at')),
  );
}

final class SkillRequest {
  const SkillRequest({
    required this.name,
    required this.sourceType,
    this.alias,
    this.description,
    this.source,
    this.instructions,
    this.enabled,
  });
  final String name;
  final String sourceType;
  final String? alias;
  final String? description;
  final String? source;
  final String? instructions;
  final bool? enabled;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'sourceType': sourceType,
    if (alias != null) 'alias': alias,
    if (description != null) 'description': description,
    if (source != null) 'source': source,
    if (instructions != null) 'instructions': instructions,
    if (enabled != null) 'enabled': enabled,
  };
}

/// An agent: a reusable assistant profile with its own instructions, model,
/// tools and permissions. It belongs to one workspace, or to the whole account
/// when [workspaceUuid] is null. A null [toolsConfig] or [approvalConfig] means
/// "use the workspace's".
final class AgentInfo {
  const AgentInfo({
    required this.uuid,
    required this.name,
    this.description,
    this.instructions,
    this.defaultModelId,
    this.toolsConfig,
    this.approvalConfig,
    this.workspaceUuid,
    this.enabled = true,
    this.createdAt,
    this.updatedAt,
  });
  final String uuid;
  final String name;
  final String? description;
  final String? instructions;
  final String? defaultModelId;
  final String? toolsConfig;
  final String? approvalConfig;
  final String? workspaceUuid;
  final bool enabled;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isAccountWide => workspaceUuid == null;

  factory AgentInfo.fromJson(Map<String, dynamic> json) => AgentInfo(
    uuid:
        _stringValue(json, 'uuid', 'uuid') ??
        (throw const FormatException('Agent uuid is required.')),
    name: _stringValue(json, 'name', 'name') ?? '',
    description: _stringValue(json, 'description', 'description'),
    instructions: _stringValue(json, 'instructions', 'instructions'),
    defaultModelId: _stringValue(json, 'defaultModelId', 'default_model_id'),
    toolsConfig: _stringValue(json, 'toolsConfig', 'tools_config'),
    approvalConfig: _stringValue(json, 'approvalConfig', 'approval_config'),
    workspaceUuid: _stringValue(json, 'workspaceUuid', 'workspace_uuid'),
    enabled: json['enabled'] as bool? ?? true,
    createdAt: _dateTimeFromJson(_jsonValue(json, 'createdAt', 'created_at')),
    updatedAt: _dateTimeFromJson(_jsonValue(json, 'updatedAt', 'updated_at')),
  );
}

/// The whole editable state of an agent. Every field is sent, so a null
/// clears the value on the engine (no description, workspace defaults for
/// tools and approvals, account-wide scope).
final class AgentRequest {
  const AgentRequest({
    required this.name,
    this.description,
    this.instructions,
    this.defaultModelId,
    this.toolsConfig,
    this.approvalConfig,
    this.workspaceUuid,
    this.enabled = true,
  });
  final String name;
  final String? description;
  final String? instructions;
  final String? defaultModelId;
  final String? toolsConfig;
  final String? approvalConfig;
  final String? workspaceUuid;
  final bool enabled;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'description': description,
    'instructions': instructions,
    'defaultModelId': defaultModelId,
    'toolsConfig': toolsConfig,
    'approvalConfig': approvalConfig,
    'workspaceUuid': workspaceUuid,
    'enabled': enabled,
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

final class AccountUser {
  const AccountUser({
    required this.id,
    required this.email,
    required this.connectedProviders,
    this.displayName,
    this.avatarUrl,
  });

  final String id;
  final String email;
  final String? displayName;
  final String? avatarUrl;
  final List<String> connectedProviders;

  factory AccountUser.fromJson(Map<String, dynamic> json) => AccountUser(
    id:
        _stringValue(json, 'id', 'id') ??
        (throw const FormatException('Account user id is required.')),
    email:
        _stringValue(json, 'email', 'email') ??
        (throw const FormatException('Account email is required.')),
    displayName: _stringValue(json, 'displayName', 'display_name'),
    avatarUrl: _stringValue(json, 'avatarUrl', 'avatar_url'),
    connectedProviders:
        (json['connected_providers'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<String>()
            .toList(growable: false),
  );
}

/// The engine profile (one data directory and engine instance per account) that
/// holds a signed-in session. When [switched] the caller was talking to another
/// profile's engine and must reconnect.
final class EngineProfile {
  const EngineProfile({required this.id, this.switched = false});

  final String id;
  final bool switched;

  static EngineProfile? fromJson(Object? value) {
    if (value is! Map) return null;
    final Object? id = value['id'];
    if (id is! String || id.isEmpty) return null;
    return EngineProfile(id: id, switched: value['switched'] == true);
  }
}
 class AccountSession {
  const AccountSession({
    required this.authenticated,
    this.user,
    this.notice,
    this.profile,
  });

  final bool authenticated;
  final AccountUser? user;
  final String? notice;
  final EngineProfile? profile;

  factory AccountSession.fromJson(Map<String, dynamic> json) {
    final Object? rawUser = json['user'];
    final bool authenticated =
        json['authenticated'] as bool? ?? rawUser != null;
    final AccountUser? user = rawUser is Map
        ? AccountUser.fromJson(rawUser.cast<String, dynamic>())
        : null;
    if (authenticated && user == null) {
      throw const FormatException('Authenticated account session has no user.');
    }
    return AccountSession(
      authenticated: authenticated,
      user: user,
      notice: _stringValue(json, 'notice', 'notice'),
      profile: EngineProfile.fromJson(json['profile']),
    );
  }
}
