import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/engine_models.dart';
import '../models/task_models.dart';
import 'engine_exception.dart';

final class RestEngineClient {
  RestEngineClient({
    required Uri baseUri,
    required this.token,
    http.Client? client,
  }) : _client = client ?? http.Client(),
       _baseUri = _withTrailingSlash(baseUri);
  final Uri _baseUri;
  final String token;
  final http.Client _client;

  Future<Map<String, dynamic>> health() =>
      _getMap('health', authenticate: false);

  Future<AccountSession> accountSession() async => AccountSession.fromJson(
    await _getMap('account/session', authenticate: true),
  );

  /// [deviceName] and [clientId] are optional and only understood by engines
  /// that fold GUI clients under themselves; older engines ignore them.
  Future<AccountSession> login({
    required String email,
    required String password,
    String? deviceName,
    String? clientId,
  }) async => AccountSession.fromJson(
    await _sendMap('POST', 'account/login', <String, dynamic>{
      'email': email,
      'password': password,
      'device_name': ?deviceName,
      'client_id': ?clientId,
    }),
  );

  Future<String> requestSignupCode({required String email}) async {
    final Map<String, dynamic> response = await _sendMap(
      'POST',
      'account/signup/code',
      <String, dynamic>{'email': email},
    );
    return response['notice'] as String? ??
        'Check your email for a verification code.';
  }

  Future<AccountSession> completeSignup({
    required String email,
    required String code,
    required String password,
    String? displayName,
  }) async => AccountSession.fromJson(
    await _sendMap('POST', 'account/signup/complete', <String, dynamic>{
      'email': email,
      'code': code,
      'password': password,
      if (displayName?.trim().isNotEmpty ?? false)
        'display_name': displayName!.trim(),
    }),
  );

  Future<void> logout() async {
    await _request('POST', 'account/logout');
  }

  Future<List<Workspace>> listWorkspaces() async =>
      _getList('workspaces', Workspace.fromJson);
  Future<Workspace> getWorkspace(String workspaceUuid) async =>
      Workspace.fromJson(
        await _getMap(
          'workspaces/${_segment(workspaceUuid)}',
          authenticate: true,
        ),
      );
  Future<Workspace> createWorkspace({
    required String name,
    String? description,
    String? defaultModelId,
    String? toolsConfig,
    String? directories,
    String? approvalConfig,
    String? ragConfig,
  }) async {
    final Map<String, dynamic> json = await _sendMap(
      'POST',
      'workspaces',
      <String, dynamic>{
        'name': name,
        if (description != null) 'description': description,
        if (defaultModelId != null) 'defaultModelId': defaultModelId,
        if (toolsConfig != null) 'toolsConfig': toolsConfig,
        if (directories != null) 'directories': directories,
        if (approvalConfig != null) 'approvalConfig': approvalConfig,
        if (ragConfig != null) 'ragConfig': ragConfig,
      },
    );
    return Workspace.fromJson(json);
  }

  Future<Workspace> updateWorkspace({
    required String workspaceUuid,
    required String name,
    String? description,
    String? defaultModelId,
    String? toolsConfig,
    String? directories,
    String? approvalConfig,
    String? ragConfig,
  }) async {
    final Map<String, dynamic> json = await _sendMap(
      'PUT',
      'workspaces/${_segment(workspaceUuid)}',
      <String, dynamic>{
        'name': name,
        if (description != null) 'description': description,
        if (defaultModelId != null) 'defaultModelId': defaultModelId,
        if (toolsConfig != null) 'toolsConfig': toolsConfig,
        if (directories != null) 'directories': directories,
        if (approvalConfig != null) 'approvalConfig': approvalConfig,
        if (ragConfig != null) 'ragConfig': ragConfig,
      },
    );
    return Workspace.fromJson(json);
  }

  Future<void> deleteWorkspace(String workspaceUuid) =>
      _delete('workspaces/${_segment(workspaceUuid)}');
  Future<List<ThreadInfo>> listThreads(String workspaceUuid) async => _getList(
    'workspaces/${_segment(workspaceUuid)}/threads',
    ThreadInfo.fromJson,
  );
  Future<ThreadInfo> getThread(String threadUuid) async => ThreadInfo.fromJson(
    await _getMap('threads/${_segment(threadUuid)}', authenticate: true),
  );

  Future<ThreadInfo> createThread({
    required String workspaceUuid,
    String? title,
    String? description,
    String? defaultModelId,
    String? toolsConfig,
  }) async {
    final Map<String, dynamic> json = await _sendMap(
      'POST',
      'threads',
      <String, dynamic>{
        'workspaceUuid': workspaceUuid,
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        if (defaultModelId != null) 'defaultModelId': defaultModelId,
        if (toolsConfig != null) 'toolsConfig': toolsConfig,
      },
    );
    return ThreadInfo.fromJson(json);
  }

  Future<ThreadInfo> updateThread({
    required String threadUuid,
    String? title,
    String? description,
    String? defaultModelId,
    String? toolsConfig,
    bool clearToolsConfig = false,
  }) async {
    final Map<String, dynamic> json = await _sendMap(
      'PUT',
      'threads/${_segment(threadUuid)}',
      <String, dynamic>{
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        if (defaultModelId != null) 'defaultModelId': defaultModelId,
        if (clearToolsConfig)
          'toolsConfig': null
        else if (toolsConfig != null)
          'toolsConfig': toolsConfig,
      },
    );
    return ThreadInfo.fromJson(json);
  }

  Future<void> deleteThread(String threadUuid) =>
      _delete('threads/${_segment(threadUuid)}');
  Future<List<ChatMessage>> listMessages(String threadUuid) async => _getList(
    'threads/${_segment(threadUuid)}/messages',
    ChatMessage.fromJson,
  );

  Future<ChatMessage> createMessage({
    required String threadUuid,
    required String role,
    required String content,
  }) async {
    final Map<String, dynamic> json = await _sendMap(
      'POST',
      'messages',
      <String, dynamic>{
        'threadUuid': threadUuid,
        'role': role,
        'content': content,
      },
    );
    return ChatMessage.fromJson(json);
  }

  /// `GET /api/v1/hive/tasks` (reachable by thin clients through the tunnel).
  Future<List<TaskRecord>> listTasks({
    String? status,
    String? threadUuid,
    int limit = 100,
  }) async {
    final Map<String, dynamic> body = await _getMap(
      'hive/tasks',
      authenticate: true,
      query: <String, String>{
        'status': ?status,
        'thread_uuid': ?threadUuid,
        'limit': '$limit',
      },
    );
    final Object? tasks = body['tasks'];
    if (tasks is! List) return const <TaskRecord>[];
    return <TaskRecord>[
      for (final Object? raw in tasks)
        if (TaskRecord.tryParse(raw) case final TaskRecord task) task,
    ];
  }

  /// `GET /api/v1/hive/nodes`: the account's devices as this engine sees them
  /// (raw snapshot rows: id, name, kind, platform, status, trusted, local,
  /// online, tier). Empty when the engine's hive is not running.
  Future<List<Map<String, dynamic>>> listHiveNodes() async {
    final Map<String, dynamic> body = await getHiveSnapshot();
    final Object? nodes = body['nodes'];
    if (nodes is! List) return const <Map<String, dynamic>>[];
    return <Map<String, dynamic>>[
      for (final Object? raw in nodes)
        if (raw is Map<String, dynamic>) raw,
    ];
  }

  /// The whole `GET /api/v1/hive/nodes` body: `nodes` plus the engine's hive
  /// `state`, `detail` and `signalling` fields.
  Future<Map<String, dynamic>> getHiveSnapshot() =>
      _getMap('hive/nodes', authenticate: true);

  /// `POST /api/v1/hive/refresh`: the engine reconnects signalling now (no
  /// backoff), re-lists the devices and returns the snapshot. `problem` is
  /// non-null whenever the engine is still not online, with the cause.
  Future<Map<String, dynamic>> refreshHive() =>
      _sendMap('POST', 'hive/refresh', <String, dynamic>{});

  /// `POST /api/v1/hive/nodes/{id}/approve` with the confirmed code.
  Future<void> approveHiveNode(String id, String sas) async {
    await _sendMap('POST', 'hive/nodes/${_segment(id)}/approve', <String, dynamic>{
      'sas': sas,
    });
  }

  /// `DELETE /api/v1/hive/nodes/{id}`.
  Future<void> revokeHiveNode(String id) => _delete('hive/nodes/${_segment(id)}');

  /// `POST /api/v1/hive/reset-local` with `confirm: true`. The engine backs up
  /// its database and forgets local hive bookkeeping (threads and files are
  /// kept). Returns the backup file name.
  Future<String?> resetLocalHive() async {
    final Map<String, dynamic> body = await _sendMap(
      'POST',
      'hive/reset-local',
      <String, dynamic>{'confirm': true},
    );
    return body['backup'] as String?;
  }

  Future<List<ModelInfo>> listModels() async =>
      _getList('models', ModelInfo.fromJson);

  /// Transcribes a recording with a speech-to-text model.
  Future<String> transcribeAudio({
    required String modelId,
    required Uint8List audio,
    required String mediaType,
    String? language,
  }) async {
    final Uri uri = _baseUri
        .resolve('audio/transcriptions')
        .replace(
          queryParameters: <String, String>{
            'modelId': modelId,
            if (language != null) 'language': language,
          },
        );
    final http.Request request = http.Request('POST', uri)
      ..headers['Accept'] = 'application/json'
      ..headers['Content-Type'] = mediaType
      ..bodyBytes = audio;
    if (token.isNotEmpty) request.headers['Authorization'] = 'Bearer $token';
    final http.StreamedResponse response = await _client.send(request);
    final String text = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw apiException(request, response, text);
    }
    final dynamic decoded = jsonDecode(text);
    final Object? transcript = decoded is Map ? decoded['text'] : null;
    if (transcript is! String) {
      throw const FormatException('The engine returned no transcript.');
    }
    return transcript;
  }

  /// Synthesizes speech with a text-to-speech model.
  Future<SpeechAudio> synthesizeSpeech({
    required String modelId,
    required String text,
    String? voice,
    String format = 'mp3',
  }) async {
    final http.Request request =
        http.Request('POST', _baseUri.resolve('audio/speech'))
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode(<String, dynamic>{
            'modelId': modelId,
            'input': text,
            'format': format,
            if (voice != null) 'voice': voice,
          });
    if (token.isNotEmpty) request.headers['Authorization'] = 'Bearer $token';
    final http.StreamedResponse response = await _client.send(request);
    final Uint8List bytes = await _readBounded(
      response.stream,
      32 * 1024 * 1024,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw apiException(
        request,
        response,
        utf8.decode(bytes, allowMalformed: true),
      );
    }
    return SpeechAudio(
      bytes,
      response.headers['content-type'] ?? 'audio/mpeg',
    );
  }

  Future<List<WorkspaceFileMatch>> searchFiles({
    required String workspaceUuid,
    required String query,
    int limit = 20,
  }) async => _getList(
    'workspaces/${_segment(workspaceUuid)}/files/search',
    WorkspaceFileMatch.fromJson,
    query: <String, String>{'q': query, 'limit': '$limit'},
  );

  Future<List<WorkspaceFileEntry>> listFiles({
    required String workspaceUuid,
    required int rootIndex,
    String? path,
  }) async {
    final Map<String, String> query = <String, String>{
      'rootIndex': '$rootIndex',
      if (path != null) 'path': path,
    };
    return _getList(
      'workspaces/${_segment(workspaceUuid)}/files',
      WorkspaceFileEntry.fromJson,
      query: query,
    );
  }

  Future<WorkspaceFileContent> readFile({
    required String workspaceUuid,
    required int rootIndex,
    required String path,
  }) async => WorkspaceFileContent.fromJson(
    await _getMap(
      'workspaces/${_segment(workspaceUuid)}/files/content',
      authenticate: true,
      query: <String, String>{'rootIndex': '$rootIndex', 'path': path},
    ),
  );

  Future<WorkspaceFilePreview> previewFile({
    required String workspaceUuid,
    required int rootIndex,
    required String path,
  }) async {
    final _BinaryResponse response = await _requestBinary(
      'workspaces/${_segment(workspaceUuid)}/files/preview',
      query: <String, String>{'rootIndex': '$rootIndex', 'path': path},
      maxBytes: 50 * 1024 * 1024,
    );
    return WorkspaceFilePreview(
      kind: WorkspacePreviewKind.fromHeader(
        response.headers['x-preview-kind'] ?? '',
      ),
      mediaType:
          response.headers['content-type']?.split(';').first.trim() ??
          'application/octet-stream',
      bytes: response.bytes,
      filename: _contentDispositionFilename(
        response.headers['content-disposition'],
      ),
    );
  }

  Future<WorkspaceFileContent> createFile({
    required String workspaceUuid,
    required int rootIndex,
    required String path,
    required String content,
  }) async => WorkspaceFileContent.fromJson(
    await _sendMapWithQuery(
      'POST',
      'workspaces/${_segment(workspaceUuid)}/files/content',
      <String, dynamic>{'content': content},
      <String, String>{'rootIndex': '$rootIndex', 'path': path},
    ),
  );

  /// Overwrites a workspace file.
  ///
  /// With [expectedVersion] the engine refuses the write (HTTP 409, see
  /// [EngineApiException.isVersionConflict]) when the file on disk no longer
  /// has that version, so an editor never silently replaces someone else's
  /// change.
  Future<WorkspaceFileContent> writeFile({
    required String workspaceUuid,
    required int rootIndex,
    required String path,
    required String content,
    String? expectedVersion,
  }) async => WorkspaceFileContent.fromJson(
    await _sendMapWithQuery(
      'PUT',
      'workspaces/${_segment(workspaceUuid)}/files/content',
      <String, dynamic>{'content': content, 'expectedVersion': ?expectedVersion},
      <String, String>{'rootIndex': '$rootIndex', 'path': path},
    ),
  );

  /// Version and size of a file on disk without transferring its content.
  Future<WorkspaceFileVersion> fileVersion({
    required String workspaceUuid,
    required int rootIndex,
    required String path,
  }) async => WorkspaceFileVersion.fromJson(
    await _getMap(
      'workspaces/${_segment(workspaceUuid)}/files/version',
      authenticate: true,
      query: <String, String>{'rootIndex': '$rootIndex', 'path': path},
    ),
  );

  Future<WorkspaceFileEntry> createDirectory({
    required String workspaceUuid,
    required int rootIndex,
    required String path,
  }) async => WorkspaceFileEntry.fromJson(
    await _requestMap(
      'POST',
      'workspaces/${_segment(workspaceUuid)}/files/directory',
      query: <String, String>{'rootIndex': '$rootIndex', 'path': path},
    ),
  );

  Future<WorkspaceFileEntry> moveWorkspacePath({
    required String workspaceUuid,
    required int sourceRootIndex,
    required String sourcePath,
    required int destinationRootIndex,
    required String destinationPath,
  }) async => WorkspaceFileEntry.fromJson(
    await _sendMap(
      'POST',
      'workspaces/${_segment(workspaceUuid)}/files/move',
      <String, dynamic>{
        'sourceRootIndex': sourceRootIndex,
        'sourcePath': sourcePath,
        'destinationRootIndex': destinationRootIndex,
        'destinationPath': destinationPath,
      },
    ),
  );

  Future<Map<String, dynamic>> indexWorkspaceRag({
    required String workspaceUuid,
  }) => _requestMap('POST', 'workspaces/${_segment(workspaceUuid)}/rag/index');

  Future<List<Map<String, dynamic>>> searchWorkspaceRag({
    required String workspaceUuid,
    required String query,
    String mode = 'hybrid',
    int limit = 8,
  }) async {
    final dynamic response = await _request(
      'POST',
      'workspaces/${_segment(workspaceUuid)}/rag/search',
      body: <String, dynamic>{'query': query, 'mode': mode, 'limit': limit},
    );
    if (response is! List) {
      throw const FormatException('Expected a JSON array from the engine.');
    }
    return response
        .map((dynamic item) => (item as Map).cast<String, dynamic>())
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> indexWorkspaceRagRoot({
    required String workspaceUuid,
    required int rootIndex,
  }) => _requestMap(
    'POST',
    'workspaces/${_segment(workspaceUuid)}/rag/roots/$rootIndex/index',
  );

  Future<List<ModelConfiguration>> listModelConfigurations() async =>
      _getList('model-configurations', ModelConfiguration.fromJson);

  Future<ModelConfiguration> createModelConfiguration(
    ModelConfigurationRequest configuration,
  ) async => ModelConfiguration.fromJson(
    await _sendMap('POST', 'model-configurations', configuration.toJson()),
  );

  Future<ModelConfiguration> updateModelConfiguration({
    required String id,
    required ModelConfigurationRequest configuration,
  }) async => ModelConfiguration.fromJson(
    await _sendMap(
      'PUT',
      'model-configurations/${_segment(id)}',
      configuration.toJson(),
    ),
  );

  Future<void> deleteModelConfiguration(String id) =>
      _delete('model-configurations/${_segment(id)}');

  Future<ToolCatalog> listToolCatalog() async =>
      ToolCatalog.fromJson(await _getMap('tools/catalog', authenticate: true));
  Future<List<ToolRegistryEntry>> listTools() async =>
      _getList('tool-registry', ToolRegistryEntry.fromJson);
  Future<ToolRegistryEntry> getTool(String uuid) async =>
      ToolRegistryEntry.fromJson(
        await _getMap('tool-registry/${_segment(uuid)}', authenticate: true),
      );
  Future<ToolRegistryEntry> createTool(ToolRegistryRequest tool) async =>
      ToolRegistryEntry.fromJson(
        await _sendMap('POST', 'tool-registry', tool.toJson()),
      );
  Future<ToolRegistryEntry> updateTool({
    required String uuid,
    required ToolRegistryRequest tool,
  }) async => ToolRegistryEntry.fromJson(
    await _sendMap('PUT', 'tool-registry/${_segment(uuid)}', tool.toJson()),
  );
  Future<void> deleteTool(String uuid) =>
      _delete('tool-registry/${_segment(uuid)}');

  Future<AppStateEntry?> getAppState(String key) async {
    try {
      return AppStateEntry.fromJson(
        await _getMap('app-state/${_segment(key)}', authenticate: true),
      );
    } on EngineApiException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<AppStateEntry> putAppState(String key, String value) async =>
      AppStateEntry.fromJson(
        await _sendMap('PUT', 'app-state/${_segment(key)}', <String, dynamic>{
          'value': value,
        }),
      );

  Future<List<EngineSetting>> getSettings({
    String? key,
    String? tag,
    String? client,
  }) async => _getList(
    'settings',
    EngineSetting.fromJson,
    query: <String, String>{
      if (key != null) 'key': key,
      if (tag != null) 'tag': tag,
      if (client != null) 'client': client,
    },
  );

  Future<List<EngineSetting>> putSettings(List<EngineSetting> settings) async =>
      _putList(
        'settings',
        settings
            .map((EngineSetting value) => value.toJson())
            .toList(growable: false),
        EngineSetting.fromJson,
      );

  /// Deletes the settings that [getSettings] would return for the same
  /// filters. A [key] or [tag] is required, and the number of removed rows is
  /// returned.
  Future<int> deleteSettings({String? key, String? tag, String? client}) async {
    final dynamic value = await _request(
      'DELETE',
      'settings',
      query: <String, String>{'key': ?key, 'tag': ?tag, 'client': ?client},
    );
    return value is Map ? (value['deleted'] as num?)?.toInt() ?? 0 : 0;
  }

  Future<void> close() async => _client.close();

  Future<void> _delete(String path) async {
    await _request('DELETE', path);
  }

  Future<List<T>> _getList<T>(
    String path,
    T Function(Map<String, dynamic>) decode, {
    Map<String, String> query = const <String, String>{},
  }) async {
    final dynamic value = await _request('GET', path, query: query);
    if (value is! List)
      throw const FormatException('Expected a JSON array from the engine.');
    return value
        .map((dynamic item) => decode((item as Map).cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<List<T>> _putList<T>(
    String path,
    List<Map<String, dynamic>> body,
    T Function(Map<String, dynamic>) decode,
  ) async {
    final dynamic value = await _request('PUT', path, body: body);
    if (value is! List)
      throw const FormatException('Expected a JSON array from the engine.');
    return value
        .map((dynamic item) => decode((item as Map).cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> _getMap(
    String path, {
    required bool authenticate,
    Map<String, String> query = const <String, String>{},
  }) async => _mapResponse(
    await _request('GET', path, query: query, authenticate: authenticate),
  );

  Future<Map<String, dynamic>> _sendMap(
    String method,
    String path,
    Map<String, dynamic> body,
  ) async => _mapResponse(await _request(method, path, body: body));

  Future<Map<String, dynamic>> _sendMapWithQuery(
    String method,
    String path,
    Map<String, dynamic> body,
    Map<String, String> query,
  ) async =>
      _mapResponse(await _request(method, path, body: body, query: query));

  Future<Map<String, dynamic>> _requestMap(
    String method,
    String path, {
    Map<String, String> query = const <String, String>{},
  }) async => _mapResponse(await _request(method, path, query: query));

  Map<String, dynamic> _mapResponse(dynamic value) {
    if (value is! Map)
      throw const FormatException('Expected a JSON object from the engine.');
    return value.cast<String, dynamic>();
  }

  Future<_BinaryResponse> _requestBinary(
    String path, {
    required int maxBytes,
    Map<String, String> query = const <String, String>{},
  }) async {
    final Uri uri = _baseUri
        .resolve(path)
        .replace(queryParameters: query.isEmpty ? null : query);
    final http.Request request = http.Request('GET', uri)
      ..headers['Accept'] =
          'image/*, application/pdf, '
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    if (token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    final http.StreamedResponse response = await _client.send(request);
    final int? declaredLength = int.tryParse(
      response.headers['content-length'] ?? '',
    );
    if (response.statusCode >= 200 &&
        response.statusCode < 300 &&
        declaredLength != null &&
        declaredLength > maxBytes) {
      throw const FormatException(
        'Workspace preview exceeds the client limit.',
      );
    }
    final int bodyLimit =
        response.statusCode >= 200 && response.statusCode < 300
        ? maxBytes
        : 1024 * 1024;
    final Uint8List bytes = await _readBounded(response.stream, bodyLimit);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw apiException(
        request,
        response,
        utf8.decode(bytes, allowMalformed: true),
      );
    }
    return _BinaryResponse(bytes, response.headers);
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Object? body,
    Map<String, String> query = const <String, String>{},
    bool authenticate = true,
  }) async {
    final Uri uri = _baseUri
        .resolve(path)
        .replace(queryParameters: query.isEmpty ? null : query);
    final http.Request request = http.Request(method, uri);
    request.headers['Accept'] = 'application/json';
    if (authenticate && token.isNotEmpty)
      request.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.StreamedResponse response = await _client.send(request);
    final String text = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw apiException(request, response, text);
    if (text.trim().isEmpty) return null;
    return jsonDecode(text);
  }
}

/// Spoken audio returned by the engine.
final class SpeechAudio {
  const SpeechAudio(this.bytes, this.mediaType);

  final Uint8List bytes;
  final String mediaType;
}

final class _BinaryResponse {
  const _BinaryResponse(this.bytes, this.headers);

  final Uint8List bytes;
  final Map<String, String> headers;
}

Future<Uint8List> _readBounded(Stream<List<int>> stream, int maxBytes) async {
  final BytesBuilder builder = BytesBuilder(copy: false);
  var length = 0;
  await for (final List<int> chunk in stream) {
    length += chunk.length;
    if (length > maxBytes) {
      throw const FormatException(
        'Workspace preview exceeds the client limit.',
      );
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

String? _contentDispositionFilename(String? value) {
  if (value == null) return null;
  final RegExpMatch? encoded = RegExp(
    r"filename\*=UTF-8''([^;]+)",
    caseSensitive: false,
  ).firstMatch(value);
  if (encoded != null) {
    try {
      return Uri.decodeComponent(encoded.group(1)!);
    } on FormatException {
      return null;
    }
  }
  return RegExp(
    r'filename="([^"]*)"',
    caseSensitive: false,
  ).firstMatch(value)?.group(1);
}

String _segment(String value) => Uri.encodeComponent(value);
Uri _withTrailingSlash(Uri value) =>
    value.path.endsWith('/') ? value : value.replace(path: '${value.path}/');
