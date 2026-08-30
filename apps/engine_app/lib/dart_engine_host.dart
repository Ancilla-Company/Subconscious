import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';

final class DartEngineRequestException implements Exception {
  const DartEngineRequestException(this.statusCode, this.message);

  final int statusCode;
  final String message;
}

final Set<String> _supportedTextExtensions = <String>{
  '.c', '.cc', '.cpp', '.cs', '.css', '.go', '.h', '.hpp', '.html', '.htm', '.java', '.js', '.jsx', '.json', '.md', '.markdown', '.php', '.ps1', '.py', '.rb', '.rs', '.sh', '.sql', '.toml', '.ts', '.tsx', '.txt', '.xml', '.xaml', '.yml', '.yaml',
};

final class DartEngineHost {
  DartEngineHost({required this.token, required this.modelProvider, this.host = '127.0.0.1', this.port = 0, this.runtimeDirectory})
      : _workspaces = <Workspace>[
          Workspace(id: 1, uuid: 'default', name: 'Local Workspace', createdAt: DateTime.now().toUtc(), updatedAt: DateTime.now().toUtc()),
        ];

  final String host;
  final int port;
  final String token;
  final EngineModelProvider modelProvider;
  final String? runtimeDirectory;
  final List<Workspace> _workspaces;
  final Map<String, List<ThreadInfo>> _threads = <String, List<ThreadInfo>>{};
  final Map<String, List<ChatMessage>> _messages = <String, List<ChatMessage>>{};
  final List<EngineSetting> _settings = <EngineSetting>[];
  final Map<String, ModelConfiguration> _modelConfigurations = <String, ModelConfiguration>{};
  final List<ToolRegistryEntry> _tools = <ToolRegistryEntry>[];
  int _nextRecordId = 2;
  HttpServer? _server;
  int? _boundPort;

  String get address => 'http://$host:${_boundPort ?? port}/api/v1/';

  Future<void> start() async {
    _server = await HttpServer.bind(host, port);
    _boundPort = _server!.port;
    unawaited(_serve());
    await _writeRuntimeFile();
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
    final String? directory = runtimeDirectory;
    if (directory == null) return;
    try {
      await File('$directory/runtime.json').delete();
    } on FileSystemException {
      // Runtime discovery is best effort during shutdown.
    }
  }

  Future<void> _serve() async {
    final HttpServer? server = _server;
    if (server == null) return;
    await for (final HttpRequest request in server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.uri.path == '/api/v1/events' && WebSocketTransformer.isUpgradeRequest(request)) {
        if (!_authorized(request)) {
          await _respond(request, HttpStatus.unauthorized, <String, Object>{'error': 'Missing or invalid bearer token.'});
          return;
        }
        final WebSocket socket = await WebSocketTransformer.upgrade(request);
        await _handleSocket(socket);
        return;
      }
      if (request.uri.path == '/api/v1/health') {
        await _respond(request, HttpStatus.ok, <String, Object>{'status': 'ok', 'version': '0.1.0-dart'});
        return;
      }
      if (!_authorized(request)) {
        await _respond(request, HttpStatus.unauthorized, <String, Object>{'error': 'Missing or invalid bearer token.'});
        return;
      }
      await _handleRest(request);
    } on DartEngineRequestException catch (error) {
      await _respond(request, error.statusCode, <String, String>{'error': error.message});
    } on FormatException catch (error) {
      await _respond(request, HttpStatus.badRequest, <String, String>{'error': error.message});
    } on Object catch (error) {
      await _respond(request, HttpStatus.internalServerError, <String, String>{'error': error.toString()});
    }
  }

  Future<void> _handleRest(HttpRequest request) async {
    final String path = request.uri.path.substring('/api/v1/'.length);
    final RegExp workspaceByUuid = RegExp(r'^workspaces/([^/]+)$');
    final RegExp workspaceThreads = RegExp(r'^workspaces/([^/]+)/threads$');
    final RegExp threadByUuid = RegExp(r'^threads/([^/]+)$');
    final RegExp threadMessages = RegExp(r'^threads/([^/]+)/messages$');

    if (request.method == 'GET' && path == 'workspaces') {
      final List<Workspace> workspaces = List<Workspace>.from(_workspaces)..sort((Workspace left, Workspace right) => left.name.compareTo(right.name));
      await _respond(request, HttpStatus.ok, workspaces.map(_workspaceJson).toList(growable: false));
      return;
    }
    if (request.method == 'POST' && path == 'workspaces') {
      final Map<String, dynamic> body = await _readJson(request);
      final DateTime now = DateTime.now().toUtc();
      final Workspace workspace = Workspace(
        id: _nextRecordId++,
        uuid: _id(),
        name: _requiredString(body, 'name'),
        description: _optionalString(body, 'description'),
        defaultModelId: _optionalString(body, 'defaultModelId'),
        toolsConfig: _optionalString(body, 'toolsConfig'),
        directories: _optionalString(body, 'directories'),
        approvalConfig: _optionalString(body, 'approvalConfig'),
        ragConfig: _optionalString(body, 'ragConfig'),
        createdAt: now,
        updatedAt: now,
      );
      _workspaces.add(workspace);
      await _respond(request, HttpStatus.ok, _workspaceJson(workspace));
      return;
    }

    final RegExpMatch? workspaceMatch = workspaceByUuid.firstMatch(path);
    if (workspaceMatch != null) {
      final String workspaceUuid = Uri.decodeComponent(workspaceMatch.group(1)!);
      final Workspace? workspace = _findWorkspace(workspaceUuid);
      if (workspace == null) {
        await _respond(request, HttpStatus.notFound, <String, String>{'error': 'Workspace not found.'});
        return;
      }
      if (request.method == 'GET') {
        await _respond(request, HttpStatus.ok, _workspaceJson(workspace));
        return;
      }
      if (request.method == 'PUT') {
        final Map<String, dynamic> body = await _readJson(request);
        final Workspace updated = Workspace(
          id: workspace.id,
          uuid: workspace.uuid,
          name: _requiredString(body, 'name'),
          description: _optionalString(body, 'description'),
          defaultModelId: _optionalString(body, 'defaultModelId'),
          toolsConfig: _optionalString(body, 'toolsConfig'),
          directories: _optionalString(body, 'directories'),
          approvalConfig: _optionalString(body, 'approvalConfig'),
          ragConfig: _optionalString(body, 'ragConfig'),
          createdAt: workspace.createdAt,
          updatedAt: DateTime.now().toUtc(),
        );
        _replaceWorkspace(updated);
        await _respond(request, HttpStatus.ok, _workspaceJson(updated));
        return;
      }
      if (request.method == 'DELETE') {
        _deleteWorkspace(workspace);
        await _respond(request, HttpStatus.noContent, <String, Object?>{});
        return;
      }
    }

    final RegExp workspaceFilesPath = RegExp(r'^workspaces/([^/]+)/files(?:/(content|directory))?$');
    final RegExpMatch? workspaceFilesMatch = workspaceFilesPath.firstMatch(path);
    if (workspaceFilesMatch != null) {
      final String workspaceUuid = Uri.decodeComponent(workspaceFilesMatch.group(1)!);
      final Workspace? workspace = _findWorkspace(workspaceUuid);
      if (workspace == null) {
        await _respond(request, HttpStatus.notFound, <String, String>{'error': 'Workspace not found.'});
        return;
      }
      final int rootIndex = _rootIndex(request);
      final String relativePath = request.uri.queryParameters['path'] ?? '';
      final String? operation = workspaceFilesMatch.group(2);
      if (request.method == 'GET' && operation == null) {
        await _respond(request, HttpStatus.ok, await _listWorkspaceFiles(workspace, rootIndex, relativePath));
        return;
      }
      if (request.method == 'GET' && operation == 'content') {
        await _respond(request, HttpStatus.ok, await _readWorkspaceFile(workspace, rootIndex, relativePath));
        return;
      }
      if (request.method == 'POST' && operation == 'content') {
        final Map<String, dynamic> body = await _readJson(request);
        final String content = _contentString(body, 'content');
        await _createWorkspaceFile(workspace, rootIndex, relativePath, content);
        await _respond(request, HttpStatus.ok, <String, String>{'content': content});
        return;
      }
      if (request.method == 'PUT' && operation == 'content') {
        final Map<String, dynamic> body = await _readJson(request);
        final String content = _requiredString(body, 'content');
        await _writeWorkspaceFile(workspace, rootIndex, relativePath, content);
        await _respond(request, HttpStatus.ok, <String, String>{'content': content});
        return;
      }
      if (request.method == 'POST' && operation == 'directory') {
        await _createWorkspaceDirectory(workspace, rootIndex, relativePath);
        await _respond(request, HttpStatus.ok, _fileEntryJson(workspace, rootIndex, relativePath, true));
        return;
      }
      await _respond(request, HttpStatus.methodNotAllowed, <String, String>{'error': 'Unsupported workspace file operation.'});
      return;
    }


    if (request.method == 'GET' && path == 'models') {
      final List<Map<String, Object?>> models = _modelConfigurations.values.map((ModelConfiguration value) => <String, Object?>{'id': value.id, 'name': value.alias ?? value.model, 'provider': value.provider, if (value.alias != null) 'description': value.model}).toList();
      models.add(<String, Object?>{'id': 'echo', 'name': 'Echo (dev)', 'provider': 'subconscious', 'description': 'Echoes the last user message back; no credentials required.'});
      await _respond(request, HttpStatus.ok, models);
      return;
    }
    if (request.method == 'GET' && path == 'model-configurations') {
      await _respond(request, HttpStatus.ok, _modelConfigurations.values.map(_modelConfigurationJson).toList(growable: false));
      return;
    }
    if (request.method == 'POST' && path == 'model-configurations') {
      final Map<String, dynamic> body = await _readJson(request);
      final ModelConfiguration configuration = _createModelConfiguration(body);
      _modelConfigurations[configuration.id] = configuration;
      await _respond(request, HttpStatus.created, _modelConfigurationJson(configuration));
      return;
    }
    final RegExp modelConfigurationPath = RegExp(r'^model-configurations/([^/]+)$');
    final RegExpMatch? modelConfigurationMatch = modelConfigurationPath.firstMatch(path);
    if (modelConfigurationMatch != null) {
      final String configurationId = Uri.decodeComponent(modelConfigurationMatch.group(1)!);
      final ModelConfiguration? current = _modelConfigurations[configurationId];
      if (current == null) {
        await _respond(request, HttpStatus.notFound, <String, String>{'error': 'Model configuration not found.'});
        return;
      }
      if (request.method == 'PUT') {
        final Map<String, dynamic> body = await _readJson(request);
        final ModelConfiguration updated = _updateModelConfiguration(current, body);
        _modelConfigurations[configurationId] = updated;
        await _respond(request, HttpStatus.ok, _modelConfigurationJson(updated));
        return;
      }
      if (request.method == 'DELETE') {
        _modelConfigurations.remove(configurationId);
        await _respond(request, HttpStatus.noContent, <String, Object?>{});
        return;
      }
      if (request.method == 'GET') {
        await _respond(request, HttpStatus.ok, _modelConfigurationJson(current));
        return;
      }
    }

    if (request.method == 'GET' && path == 'tools/catalog') {
      await _respond(request, HttpStatus.ok, _toolCatalogJson());
      return;
    }
    if (request.method == 'GET' && path == 'tool-registry') {
      final List<ToolRegistryEntry> tools = List<ToolRegistryEntry>.from(_tools)..sort((ToolRegistryEntry left, ToolRegistryEntry right) => (left.alias ?? left.name).compareTo(right.alias ?? right.name));
      await _respond(request, HttpStatus.ok, tools.map(_toolJson).toList(growable: false));
      return;
    }
    if (request.method == 'POST' && path == 'tool-registry') {
      final Map<String, dynamic> body = await _readJson(request);
      final ToolRegistryEntry tool = _createTool(body);
      _tools.add(tool);
      await _respond(request, HttpStatus.created, _toolJson(tool));
      return;
    }
    final RegExp toolPath = RegExp(r'^tool-registry/([^/]+)$');
    final RegExpMatch? toolMatch = toolPath.firstMatch(path);
    if (toolMatch != null) {
      final String toolUuid = Uri.decodeComponent(toolMatch.group(1)!);
      final ToolRegistryEntry? current = _findTool(toolUuid);
      if (current == null) {
        await _respond(request, HttpStatus.notFound, <String, String>{'error': 'Tool not found.'});
        return;
      }
      if (request.method == 'GET') {
        await _respond(request, HttpStatus.ok, _toolJson(current));
        return;
      }
      if (request.method == 'PUT') {
        final Map<String, dynamic> body = await _readJson(request);
        final ToolRegistryEntry updated = _updateTool(current, body);
        _replaceTool(updated);
        await _respond(request, HttpStatus.ok, _toolJson(updated));
        return;
      }
      if (request.method == 'DELETE') {
        _tools.removeWhere((ToolRegistryEntry value) => value.uuid == toolUuid);
        await _respond(request, HttpStatus.noContent, <String, Object?>{});
        return;
      }
    }
    if (request.method == 'GET' && path == 'settings') {
      final String? key = request.uri.queryParameters['key'];
      final String? tag = request.uri.queryParameters['tag'];
      final String? client = request.uri.queryParameters['client'];
      final List<Map<String, dynamic>> settings = _settings.where((EngineSetting setting) => (key == null || setting.key == key) && (tag == null || setting.tag == tag) && (client == null || setting.client == client)).map((EngineSetting value) => value.toJson()).toList(growable: false);
      await _respond(request, HttpStatus.ok, settings);
      return;
    }
    if (request.method == 'PUT' && path == 'settings') {
      final dynamic decoded = await _readJsonValue(request);
      if (decoded is! List) {
        await _respond(request, HttpStatus.badRequest, <String, String>{'error': 'Settings must be a JSON array.'});
        return;
      }
      final List<EngineSetting> settings;
      try {
        settings = decoded.map((dynamic item) => EngineSetting.fromJson((item as Map).cast<String, dynamic>())).toList(growable: false);
      } on Object {
        await _respond(request, HttpStatus.badRequest, <String, String>{'error': 'Settings must contain key and value fields.'});
        return;
      }
      final Set<String> scopes = <String>{};
      if (settings.any((EngineSetting setting) => setting.key.trim().isEmpty || !scopes.add('${setting.key}\u0000${setting.tag}\u0000${setting.client}'))) {
        await _respond(request, HttpStatus.badRequest, <String, String>{'error': 'Settings must have unique key/tag/client scopes.'});
        return;
      }
      _settings
        ..clear()
        ..addAll(settings);
      await _respond(request, HttpStatus.ok, settings.map((EngineSetting value) => value.toJson()).toList(growable: false));
      return;
    }

    final RegExpMatch? workspaceThreadsMatch = workspaceThreads.firstMatch(path);
    if (request.method == 'GET' && workspaceThreadsMatch != null) {
      final String workspaceUuid = Uri.decodeComponent(workspaceThreadsMatch.group(1)!);
      final List<ThreadInfo> threads = List<ThreadInfo>.from(_threads[workspaceUuid] ?? <ThreadInfo>[])
        ..sort((ThreadInfo left, ThreadInfo right) => (right.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(left.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0)));
      await _respond(request, HttpStatus.ok, threads.map(_threadJson).toList(growable: false));
      return;
    }

    final RegExpMatch? messageMatch = threadMessages.firstMatch(path);
    if (request.method == 'GET' && messageMatch != null) {
      final String threadUuid = Uri.decodeComponent(messageMatch.group(1)!);
      await _respond(request, HttpStatus.ok, (_messages[threadUuid] ?? <ChatMessage>[]).map((ChatMessage value) => value.toJson()).toList(growable: false));
      return;
    }

    if (request.method == 'POST' && path == 'threads') {
      final Map<String, dynamic> body = await _readJson(request);
      final String workspaceUuid = _requiredString(body, 'workspaceUuid');
      if (_findWorkspace(workspaceUuid) == null) {
        await _respond(request, HttpStatus.notFound, <String, String>{'error': 'Workspace not found.'});
        return;
      }
      final DateTime now = DateTime.now().toUtc();
      final ThreadInfo thread = ThreadInfo(id: _nextRecordId++, uuid: _id(), workspaceUuid: workspaceUuid, title: _optionalString(body, 'title'), description: _optionalString(body, 'description'), defaultModelId: _optionalString(body, 'defaultModelId'), createdAt: now, updatedAt: now);
      _threads.putIfAbsent(workspaceUuid, () => <ThreadInfo>[]).add(thread);
      await _respond(request, HttpStatus.ok, _threadJson(thread));
      return;
    }

    final RegExpMatch? threadMatch = threadByUuid.firstMatch(path);
    if (threadMatch != null) {
      final String threadUuid = Uri.decodeComponent(threadMatch.group(1)!);
      final ThreadInfo? thread = _findThread(threadUuid);
      if (thread == null) {
        await _respond(request, HttpStatus.notFound, <String, String>{'error': 'Thread not found.'});
        return;
      }
      if (request.method == 'GET') {
        await _respond(request, HttpStatus.ok, _threadJson(thread));
        return;
      }
      if (request.method == 'PUT') {
        final Map<String, dynamic> body = await _readJson(request);
        final ThreadInfo updated = ThreadInfo(id: thread.id, uuid: thread.uuid, workspaceUuid: thread.workspaceUuid, title: _optionalString(body, 'title') ?? thread.title, description: _optionalString(body, 'description') ?? thread.description, defaultModelId: _optionalString(body, 'defaultModelId') ?? thread.defaultModelId, toolsConfig: thread.toolsConfig, createdAt: thread.createdAt, updatedAt: DateTime.now().toUtc());
        _replaceThread(updated);
        await _respond(request, HttpStatus.ok, _threadJson(updated));
        return;
      }
      if (request.method == 'DELETE') {
        _deleteThread(thread);
        await _respond(request, HttpStatus.noContent, <String, Object?>{});
        return;
      }
    }

    if (request.method == 'POST' && path == 'messages') {
      final Map<String, dynamic> body = await _readJson(request);
      final ChatMessage message = ChatMessage(uuid: _id(), threadUuid: _requiredString(body, 'threadUuid'), role: _requiredString(body, 'role'), content: _requiredString(body, 'content'), createdAt: DateTime.now().toUtc());
      _messages.putIfAbsent(message.threadUuid, () => <ChatMessage>[]).add(message);
      await _respond(request, HttpStatus.ok, message.toJson());
      return;
    }
    await _respond(request, HttpStatus.notFound, <String, String>{'error': 'Not found.'});
  }

  Future<void> _handleSocket(WebSocket socket) async {
    bool handshaken = false;
    try {
      await for (final dynamic raw in socket) {
        final WireFrame frame;
        try {
          frame = WireFrame.decode(raw.toString());
        } on Object {
          socket.add(const WireFrame(type: 'error', data: <String, String>{'error': 'Invalid JSON frame.'}).encode());
          continue;
        }
        if (!handshaken && frame.type != 'client.hello') {
          socket.add(WireFrame(type: 'client.hello.reject', id: frame.id, data: <String, String>{'reason': 'client.hello is required before other frames.'}).encode());
          continue;
        }
        switch (frame.type) {
          case 'client.hello':
            if (handshaken) {
              socket.add(WireFrame(type: 'client.hello.reject', id: frame.id, data: <String, String>{'reason': 'client.hello was already completed.'}).encode());
              continue;
            }
            handshaken = true;
            final String clientId = frame.data?['clientId'] as String? ?? 'dart-engine';
            socket.add(WireFrame(type: 'client.hello.ack', id: frame.id, data: <String, String>{'clientId': clientId}).encode());
          case 'ping':
            socket.add(const WireFrame(type: 'pong').encode());
          case 'chat.send':
            await _streamChat(socket, frame);
          case 'chat.cancel':
            socket.add(WireFrame(type: 'chat.cancelled', id: frame.id, data: <String, String>{'thread_uuid': ''}).encode());
          default:
            socket.add(WireFrame(type: 'error', id: frame.id, data: <String, String>{'error': 'Unknown frame type: ${frame.type}'}).encode());
        }
      }
    } finally {
      await socket.close();
    }
  }

  Future<void> _streamChat(WebSocket socket, WireFrame frame) async {
    final Map<String, dynamic> data = frame.data ?? <String, dynamic>{};
    final String? requestedThreadUuid = data['thread_uuid'] as String?;
    final String? workspaceUuid = data['workspace_uuid'] as String?;
    final String content = data['content'] as String? ?? '';
    if ((requestedThreadUuid == null) == (workspaceUuid == null)) {
      socket.add(WireFrame(type: 'chat.error', id: frame.id, data: <String, String>{'thread_uuid': requestedThreadUuid ?? '', 'error': 'chat.send requires exactly one of thread_uuid or workspace_uuid.'}).encode());
      return;
    }

    String threadUuid;
    if (requestedThreadUuid != null) {
      threadUuid = requestedThreadUuid;
    } else {
      final Workspace? workspace = _workspaces.where((Workspace value) => value.uuid == workspaceUuid).isEmpty ? null : _workspaces.firstWhere((Workspace value) => value.uuid == workspaceUuid);
      if (workspace == null) {
        socket.add(WireFrame(type: 'chat.error', id: frame.id, data: <String, String>{'thread_uuid': '', 'error': 'Workspace not found.'}).encode());
        return;
      }
      final DateTime now = DateTime.now().toUtc();
      final ThreadInfo thread = ThreadInfo(id: _nextRecordId++, uuid: _id(), workspaceUuid: workspace.uuid, title: _title(content), createdAt: now, updatedAt: now);
      _threads.putIfAbsent(workspace.uuid, () => <ThreadInfo>[]).add(thread);
      threadUuid = thread.uuid;
      socket.add(WireFrame(type: 'thread.created', id: frame.id, data: _threadJson(thread)).encode());
    }

    final List<ChatMessage> history = _messages.putIfAbsent(threadUuid, () => <ChatMessage>[]);
    history.add(ChatMessage(uuid: _id(), threadUuid: threadUuid, role: 'user', content: content, createdAt: DateTime.now().toUtc()));
    final StringBuffer response = StringBuffer();
    try {
      await for (final String delta in modelProvider.generate(history: history, prompt: content)) {
        response.write(delta);
        socket.add(WireFrame(type: 'chat.delta', id: frame.id, data: <String, String>{'thread_uuid': threadUuid, 'delta': delta}).encode());
      }
    } on Object catch (error) {
      socket.add(WireFrame(type: 'chat.error', id: frame.id, data: <String, String>{'thread_uuid': threadUuid, 'error': error.toString()}).encode());
      return;
    }
    history.add(ChatMessage(uuid: _id(), threadUuid: threadUuid, role: 'assistant', content: response.toString(), createdAt: DateTime.now().toUtc()));
    socket.add(WireFrame(type: 'chat.done', id: frame.id, data: <String, String>{'thread_uuid': threadUuid}).encode());
  }

  bool _authorized(HttpRequest request) => request.headers.value(HttpHeaders.authorizationHeader) == 'Bearer $token' || request.uri.queryParameters['token'] == token;

  int _rootIndex(HttpRequest request) {
    final String? raw = request.uri.queryParameters['rootIndex'];
    final int? value = raw == null ? null : int.tryParse(raw);
    if (value == null || value < 0) throw const DartEngineRequestException(HttpStatus.badRequest, 'rootIndex does not select a configured workspace root.');
    return value;
  }

  List<String> _workspaceRoots(Workspace workspace) {
    final String? rawDirectories = workspace.directories;
    if (rawDirectories == null || rawDirectories.trim().isEmpty) throw const DartEngineRequestException(HttpStatus.badRequest, 'Workspace directories must be a JSON array of absolute paths.');
    final dynamic decoded;
    try {
      decoded = jsonDecode(rawDirectories);
    } on FormatException {
      throw const DartEngineRequestException(HttpStatus.badRequest, 'Workspace directories must be a JSON array of absolute paths.');
    }
    if (decoded is! List || decoded.any((dynamic value) => value is! String || value.trim().isEmpty)) throw const DartEngineRequestException(HttpStatus.badRequest, 'Workspace directories must be a JSON array of absolute paths.');
    return decoded.cast<String>();
  }

  String _workspaceRoot(Workspace workspace, int rootIndex) {
    final List<String> roots = _workspaceRoots(workspace);
    if (rootIndex >= roots.length) throw const DartEngineRequestException(HttpStatus.badRequest, 'rootIndex does not select a configured workspace root.');
    final String configuredRoot = roots[rootIndex];
    final Directory root = Directory(configuredRoot).absolute;
    if (root.path != configuredRoot) throw const DartEngineRequestException(HttpStatus.badRequest, 'The selected workspace root is not an absolute path.');
    if (!root.existsSync()) throw const DartEngineRequestException(HttpStatus.notFound, 'The selected workspace root does not exist.');
    if (FileSystemEntity.typeSync(root.path, followLinks: false) == FileSystemEntityType.link) throw const DartEngineRequestException(HttpStatus.forbidden, 'The selected workspace root must not be a symbolic link.');
    return root.path;
  }

  String _workspacePath(String root, String relativePath, {required bool allowEmpty}) {
    if (!allowEmpty && relativePath.trim().isEmpty) throw const DartEngineRequestException(HttpStatus.badRequest, 'The workspace-relative path must not be empty.');
    final String normalized = relativePath.replaceAll('\\\\', '/');
    if (normalized.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(normalized) || normalized.split('/').any((String segment) => segment == '.' || segment == '..')) throw const DartEngineRequestException(HttpStatus.badRequest, 'The path must be workspace-relative and must not contain traversal segments.');
    final String candidate = Directory('$root${Platform.pathSeparator}${normalized.replaceAll('/', Platform.pathSeparator)}').absolute.path;
    final String rootPrefix = root.endsWith(Platform.pathSeparator) ? root : '$root${Platform.pathSeparator}';
    if (candidate != root && !candidate.toLowerCase().startsWith(rootPrefix.toLowerCase())) throw const DartEngineRequestException(HttpStatus.badRequest, 'The requested path is outside the workspace root.');
    return candidate;
  }

  Future<List<Map<String, Object?>>> _listWorkspaceFiles(Workspace workspace, int rootIndex, String relativePath) async {
    final String root = _workspaceRoot(workspace, rootIndex);
    final String directoryPath = _workspacePath(root, relativePath, allowEmpty: true);
    final Directory directory = Directory(directoryPath);
    if (!await directory.exists()) throw const DartEngineRequestException(HttpStatus.notFound, 'The requested workspace directory does not exist.');
    _ensureNoSymbolicLinks(root, directoryPath);
    final List<FileSystemEntity> entries = await directory.list(followLinks: false).toList();
    final List<Map<String, Object?>> result = <Map<String, Object?>>[];
    for (final FileSystemEntity entry in entries) {
      final FileSystemEntityType type = await FileSystemEntity.type(entry.path, followLinks: false);
      if (type == FileSystemEntityType.link) continue;
      final String entryRelativePath = _relativePath(root, entry.path);
      result.add(<String, Object?>{'name': entryRelativePath.split('/').last, 'relativePath': entryRelativePath, 'isDirectory': type == FileSystemEntityType.directory});
    }
    result.sort((Map<String, Object?> left, Map<String, Object?> right) {
      final bool leftDirectory = left['isDirectory'] as bool;
      final bool rightDirectory = right['isDirectory'] as bool;
      if (leftDirectory != rightDirectory) return leftDirectory ? -1 : 1;
      return (left['name'] as String).toLowerCase().compareTo((right['name'] as String).toLowerCase());
    });
    return result;
  }

  Future<Map<String, String>> _readWorkspaceFile(Workspace workspace, int rootIndex, String relativePath) async {
    final String filePath = _existingWorkspaceFile(workspace, rootIndex, relativePath);
    final List<int> bytes = await File(filePath).readAsBytes();
    if (bytes.length > 1000000) throw const DartEngineRequestException(HttpStatus.badRequest, 'The requested file exceeds the 1 MB limit.');
    try {
      return <String, String>{'content': utf8.decode(bytes)};
    } on FormatException {
      throw const DartEngineRequestException(HttpStatus.badRequest, 'The requested file is not valid UTF-8 text.');
    }
  }

  Future<void> _createWorkspaceFile(Workspace workspace, int rootIndex, String relativePath, String content) async {
    final String root = _workspaceRoot(workspace, rootIndex);
    final String filePath = _newWorkspacePath(root, relativePath);
    final File file = File(filePath);
    if (await file.exists() || await Directory(filePath).exists()) throw const DartEngineRequestException(HttpStatus.conflict, 'A file or directory already exists at the requested path.');
    await _validateContent(content);
    final Directory parent = Directory(file.parent.path);
    if (!await parent.exists()) throw const DartEngineRequestException(HttpStatus.notFound, 'The parent workspace directory does not exist.');
    _ensureNoSymbolicLinks(root, parent.path);
    await file.writeAsString(content, encoding: utf8, flush: true);
  }

  Future<void> _writeWorkspaceFile(Workspace workspace, int rootIndex, String relativePath, String content) async {
    final String filePath = _existingWorkspaceFile(workspace, rootIndex, relativePath);
    await _validateContent(content);
    await File(filePath).writeAsString(content, encoding: utf8, flush: true);
  }

  Future<void> _createWorkspaceDirectory(Workspace workspace, int rootIndex, String relativePath) async {
    final String root = _workspaceRoot(workspace, rootIndex);
    final String directoryPath = _workspacePath(root, relativePath, allowEmpty: false);
    final Directory directory = Directory(directoryPath);
    if (await directory.exists() || await File(directoryPath).exists()) throw const DartEngineRequestException(HttpStatus.conflict, 'A file or directory already exists at the requested path.');
    final Directory parent = Directory(directory.parent.path);
    if (!await parent.exists()) throw const DartEngineRequestException(HttpStatus.notFound, 'The parent workspace directory does not exist.');
    _ensureNoSymbolicLinks(root, parent.path);
    await directory.create();
  }

  String _existingWorkspaceFile(Workspace workspace, int rootIndex, String relativePath) {
    final String root = _workspaceRoot(workspace, rootIndex);
    final String filePath = _workspacePath(root, relativePath, allowEmpty: false);
    final String extension = _extensionOf(filePath);
    if (!_supportedTextExtensions.contains(extension)) throw const DartEngineRequestException(HttpStatus.badRequest, 'The requested file is not a supported text or source file.');
    if (!File(filePath).existsSync()) throw const DartEngineRequestException(HttpStatus.notFound, 'The requested workspace file does not exist.');
    if (Directory(filePath).existsSync()) throw const DartEngineRequestException(HttpStatus.badRequest, 'The content path must identify a file, not a directory.');
    _ensureNoSymbolicLinks(root, filePath);
    return filePath;
  }

  String _newWorkspacePath(String root, String relativePath) {
    final String filePath = _workspacePath(root, relativePath, allowEmpty: false);
    final String extension = _extensionOf(filePath);
    if (!_supportedTextExtensions.contains(extension)) throw const DartEngineRequestException(HttpStatus.badRequest, 'The requested file is not a supported text or source file.');
    return filePath;
  }

  String _extensionOf(String path) {
    final int separatorIndex = path.lastIndexOf(Platform.pathSeparator);
    final int dotIndex = path.lastIndexOf('.');
    return dotIndex > separatorIndex ? path.substring(dotIndex).toLowerCase() : '';
  }

  void _ensureNoSymbolicLinks(String root, String target) {
    if (FileSystemEntity.typeSync(root, followLinks: false) == FileSystemEntityType.link) throw const DartEngineRequestException(HttpStatus.forbidden, 'Symbolic links are not allowed in workspace file paths.');
    final String relative = _relativePath(root, target);
    String current = root;
    for (final String segment in relative.split('/').where((String value) => value.isNotEmpty)) {
      current = '$current${Platform.pathSeparator}$segment';
      if (FileSystemEntity.typeSync(current, followLinks: false) == FileSystemEntityType.link) throw const DartEngineRequestException(HttpStatus.forbidden, 'Symbolic links are not allowed in workspace file paths.');
    }
  }

  Future<void> _validateContent(String content) async {
    final List<int> bytes = utf8.encode(content);
    if (bytes.length > 1000000) throw const DartEngineRequestException(HttpStatus.badRequest, 'Content exceeds the 1 MB limit.');
  }

  String _relativePath(String root, String path) {
    final String prefix = root.endsWith(Platform.pathSeparator) ? root : '$root${Platform.pathSeparator}';
    return path.startsWith(prefix) ? path.substring(prefix.length).replaceAll(Platform.pathSeparator, '/') : '';
  }

  Map<String, Object?> _fileEntryJson(Workspace workspace, int rootIndex, String relativePath, bool isDirectory) => <String, Object?>{'name': relativePath.split('/').last, 'relativePath': relativePath, 'isDirectory': isDirectory};

  ModelConfiguration _createModelConfiguration(Map<String, dynamic> body) {
    final String provider = _requiredString(body, 'provider');
    final String model = _requiredString(body, 'model');
    final String? apiKey = _optionalString(body, 'apiKey');
    final int? contextWindow = _optionalInt(body, 'contextWindow');
    if (contextWindow != null && contextWindow <= 0) throw const DartEngineRequestException(HttpStatus.badRequest, 'Context window must be a positive number of tokens.');
    return ModelConfiguration(id: _id(), provider: provider.trim(), model: model.trim(), alias: _optionalString(body, 'alias')?.trim(), baseUrl: _optionalString(body, 'baseUrl')?.trim(), contextWindow: contextWindow, hasApiKey: apiKey != null && apiKey.isNotEmpty);
  }

  ModelConfiguration _updateModelConfiguration(ModelConfiguration current, Map<String, dynamic> body) {
    final String provider = _requiredString(body, 'provider');
    final String model = _requiredString(body, 'model');
    final String? apiKey = _optionalString(body, 'apiKey');
    final bool hasApiKey = apiKey != null && apiKey.isNotEmpty ? true : (_jsonBool(body, 'clearApiKey') ? false : current.hasApiKey);
    final int? contextWindow = _optionalInt(body, 'contextWindow');
    if (contextWindow != null && contextWindow <= 0) throw const DartEngineRequestException(HttpStatus.badRequest, 'Context window must be a positive number of tokens.');
    return ModelConfiguration(id: current.id, provider: provider.trim(), model: model.trim(), alias: _optionalString(body, 'alias')?.trim(), baseUrl: _optionalString(body, 'baseUrl')?.trim(), contextWindow: contextWindow, hasApiKey: hasApiKey);
  }

  Map<String, Object?> _modelConfigurationJson(ModelConfiguration value) => <String, Object?>{'id': value.id, 'provider': value.provider, 'model': value.model, if (value.alias != null) 'alias': value.alias, if (value.baseUrl != null) 'baseUrl': value.baseUrl, if (value.contextWindow != null) 'contextWindow': value.contextWindow, 'hasApiKey': value.hasApiKey};

  ToolRegistryEntry? _findTool(String uuid) {
    for (final ToolRegistryEntry tool in _tools) {
      if (tool.uuid == uuid) return tool;
    }
    return null;
  }

  ToolRegistryEntry _createTool(Map<String, dynamic> body) {
    final String toolType = _optionalString(body, 'toolType') ?? 'script';
    final String? authType = _optionalString(body, 'authType')?.toLowerCase();
    final String? authConfig = _optionalString(body, 'authConfigJson');
    _validateToolAuth(toolType, authType, authConfig);
    final String uuid = _id();
    final DateTime now = DateTime.now().toUtc();
    final String? alias = _optionalString(body, 'alias');
    return ToolRegistryEntry(id: _nextRecordId++, uuid: uuid, name: _optionalString(body, 'name') ?? alias ?? 'tool-$uuid', alias: alias, description: _optionalString(body, 'description'), toolType: toolType, scriptPath: _optionalString(body, 'scriptPath'), scriptLanguage: _optionalString(body, 'scriptLanguage'), endpointUrl: _optionalString(body, 'endpointUrl'), authType: authType, hasAuthConfig: authConfig != null && authConfig.isNotEmpty, status: _optionalString(body, 'status') ?? 'active', createdAt: now, updatedAt: now);
  }

  ToolRegistryEntry _updateTool(ToolRegistryEntry current, Map<String, dynamic> body) {
    final String? authConfig = _optionalString(body, 'authConfigJson');
    final String? authType = _optionalString(body, 'authType')?.toLowerCase();
    final String toolType = _optionalString(body, 'toolType') ?? current.toolType;
    _validateToolAuth(toolType, authType, authConfig);
    final bool hasAuthConfig = authConfig != null && authConfig.isNotEmpty ? true : (_jsonBool(body, 'clearAuthConfig') ? false : current.hasAuthConfig);
    final DateTime now = DateTime.now().toUtc();
    return ToolRegistryEntry(id: current.id, uuid: current.uuid, name: _optionalString(body, 'name') ?? current.name, alias: _optionalString(body, 'alias'), description: _optionalString(body, 'description'), toolType: toolType, scriptPath: _optionalString(body, 'scriptPath'), scriptLanguage: _optionalString(body, 'scriptLanguage'), endpointUrl: _optionalString(body, 'endpointUrl'), authType: authType, hasAuthConfig: hasAuthConfig, status: _optionalString(body, 'status') ?? current.status, createdAt: current.createdAt, updatedAt: now);
  }

  void _validateToolAuth(String toolType, String? authType, String? authConfig) {
    if (authType != null && authType != 'api_key') throw const DartEngineRequestException(HttpStatus.badRequest, 'Only api_key authentication is supported for configured tools.');
    if (authType == 'api_key' && toolType.toLowerCase() != 'api' && toolType.toLowerCase() != 'mcp') throw const DartEngineRequestException(HttpStatus.badRequest, 'API key authentication is supported only for API and MCP endpoint tools.');
    if (authConfig == null) return;
    if (authType != 'api_key') throw const DartEngineRequestException(HttpStatus.badRequest, 'API key headers require the api_key authentication type.');
    final dynamic decoded;
    try {
      decoded = jsonDecode(authConfig);
    } on FormatException {
      throw const DartEngineRequestException(HttpStatus.badRequest, 'API key headers must be valid JSON.');
    }
    if (decoded is! Map || decoded.isEmpty) throw const DartEngineRequestException(HttpStatus.badRequest, 'API key headers must be a non-empty JSON object.');
    final Set<String> names = <String>{};
    final RegExp validHeaderName = RegExp(r"^[A-Za-z0-9!#\$%&'*+.^_`|~-]+$");
    for (final MapEntry<dynamic, dynamic> entry in decoded.entries) {
      final String name = '${entry.key}';
      final dynamic value = entry.value;
      if (!validHeaderName.hasMatch(name) || !names.add(name.toLowerCase()) || value is! String || value.trim().isEmpty || value.contains('\r') || value.contains('\n')) throw const DartEngineRequestException(HttpStatus.badRequest, 'API key headers must use unique valid names and non-empty string values.');
    }
  }

  void _replaceTool(ToolRegistryEntry updated) {
    final int index = _tools.indexWhere((ToolRegistryEntry value) => value.uuid == updated.uuid);
    if (index >= 0) _tools[index] = updated;
  }

  Map<String, Object?> _toolJson(ToolRegistryEntry value) => <String, Object?>{'id': value.id, 'uuid': value.uuid, 'name': value.name, if (value.alias != null) 'alias': value.alias, if (value.description != null) 'description': value.description, 'toolType': value.toolType, if (value.scriptPath != null) 'scriptPath': value.scriptPath, if (value.scriptLanguage != null) 'scriptLanguage': value.scriptLanguage, if (value.endpointUrl != null) 'endpointUrl': value.endpointUrl, if (value.authType != null) 'authType': value.authType, 'hasAuthConfig': value.hasAuthConfig, 'status': value.status, if (value.createdAt != null) 'createdAt': value.createdAt!.toUtc().toIso8601String(), if (value.updatedAt != null) 'updatedAt': value.updatedAt!.toUtc().toIso8601String()};

  Map<String, Object?> _toolCatalogJson() => <String, Object?>{'builtin': <String, Object?>{'core': <Map<String, String>>[<String, String>{'name': 'calculator', 'doc': 'Evaluate a mathematical expression.', 'operation': 'query'}, <String, String>{'name': 'time', 'doc': 'Get the current time.', 'operation': 'query'}]}, 'configured': _tools.map(_toolJson).toList(growable: false)};

  int? _optionalInt(Map<String, dynamic> body, String key) {
    final dynamic value = body[key];
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    throw FormatException('$key must be an integer.');
  }

  bool _jsonBool(Map<String, dynamic> body, String key) => body[key] == true;


  Future<dynamic> _readJsonValue(HttpRequest request) async => jsonDecode(await utf8.decoder.bind(request).join());

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    final dynamic value = await _readJsonValue(request);
    if (value is! Map) throw const FormatException('Expected a JSON object.');
    return value.cast<String, dynamic>();
  }

  Future<void> _respond(HttpRequest request, int status, Object body) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  Workspace? _findWorkspace(String uuid) {
    for (final Workspace workspace in _workspaces) {
      if (workspace.uuid == uuid) return workspace;
    }
    return null;
  }

  ThreadInfo? _findThread(String uuid) {
    for (final List<ThreadInfo> threads in _threads.values) {
      for (final ThreadInfo thread in threads) {
        if (thread.uuid == uuid) return thread;
      }
    }
    return null;
  }

  void _replaceWorkspace(Workspace updated) {
    final int index = _workspaces.indexWhere((Workspace value) => value.uuid == updated.uuid);
    if (index >= 0) _workspaces[index] = updated;
  }

  void _replaceThread(ThreadInfo updated) {
    final List<ThreadInfo>? threads = _threads[updated.workspaceUuid];
    if (threads == null) return;
    final int index = threads.indexWhere((ThreadInfo value) => value.uuid == updated.uuid);
    if (index >= 0) threads[index] = updated;
  }

  void _deleteWorkspace(Workspace workspace) {
    final List<ThreadInfo> threads = _threads.remove(workspace.uuid) ?? <ThreadInfo>[];
    for (final ThreadInfo thread in threads) {
      _messages.remove(thread.uuid);
    }
    _workspaces.removeWhere((Workspace value) => value.uuid == workspace.uuid);
  }

  void _deleteThread(ThreadInfo thread) {
    _threads[thread.workspaceUuid]?.removeWhere((ThreadInfo value) => value.uuid == thread.uuid);
    _messages.remove(thread.uuid);
  }

  Map<String, Object?> _workspaceJson(Workspace value) => <String, Object?>{
    'id': value.id,
    'uuid': value.uuid,
    'name': value.name,
    if (value.description != null) 'description': value.description,
    if (value.defaultModelId != null) 'defaultModelId': value.defaultModelId,
    if (value.toolsConfig != null) 'toolsConfig': value.toolsConfig,
    if (value.directories != null) 'directories': value.directories,
    if (value.approvalConfig != null) 'approvalConfig': value.approvalConfig,
    if (value.ragConfig != null) 'ragConfig': value.ragConfig,
    if (value.createdAt != null) 'createdAt': value.createdAt!.toUtc().toIso8601String(),
    if (value.updatedAt != null) 'updatedAt': value.updatedAt!.toUtc().toIso8601String(),
  };

  Map<String, Object?> _threadJson(ThreadInfo value) => <String, Object?>{
    'id': value.id,
    'uuid': value.uuid,
    'workspaceUuid': value.workspaceUuid,
    if (value.title != null) 'title': value.title,
    if (value.description != null) 'description': value.description,
    if (value.defaultModelId != null) 'defaultModelId': value.defaultModelId,
    if (value.toolsConfig != null) 'toolsConfig': value.toolsConfig,
    if (value.createdAt != null) 'createdAt': value.createdAt!.toUtc().toIso8601String(),
    if (value.updatedAt != null) 'updatedAt': value.updatedAt!.toUtc().toIso8601String(),
  };

  String _requiredString(Map<String, dynamic> body, String key) {
    final dynamic value = body[key];
    if (value is! String || value.trim().isEmpty) throw FormatException('$key is required.');
    return value;
  }

  String _contentString(Map<String, dynamic> body, String key) {
    final dynamic value = body[key];
    if (value is! String) throw FormatException('$key is required.');
    return value;
  }

  String? _optionalString(Map<String, dynamic> body, String key) {
    final dynamic value = body[key];
    if (value == null) return null;
    if (value is! String) throw FormatException('$key must be a string.');
    return value;
  }

  String _title(String content) {
    final String normalized = content.trim().replaceAll(RegExp(r'\s+'), ' ');
    return normalized.length <= 60 ? normalized : '${normalized.substring(0, 57)}…';
  }

  String _id() => DateTime.now().microsecondsSinceEpoch.toString();

  Future<void> _writeRuntimeFile() async {
    final String? directory = runtimeDirectory;
    if (directory == null) return;
    await Directory(directory).create(recursive: true);
    await File('$directory/runtime.json').writeAsString(jsonEncode(<String, Object>{'host': host, 'port': _boundPort!, 'token': token, 'pid': pid, 'version': '0.1.0-dart'}));
  }
}
