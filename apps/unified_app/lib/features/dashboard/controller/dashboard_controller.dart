import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/foundation.dart';

import '../../chat/engine_llm_provider.dart';
import '../../settings/controller/settings_controller.dart';

enum EngineConnectionStatus { disconnected, connecting, connected }

final class WorkspaceDirectoryRoot {
  const WorkspaceDirectoryRoot({required this.index, required this.path});

  final int index;
  final String path;

  String get name {
    final List<String> segments = path.replaceAll('\\', '/').split('/');
    return segments.lastWhere(
      (String segment) => segment.isNotEmpty,
      orElse: () => path,
    );
  }
}

final class OpenWorkspaceFile {
  const OpenWorkspaceFile({
    required this.rootIndex,
    required this.path,
    required this.content,
  });

  final int rootIndex;
  final String path;
  final String content;

  String get name => path.replaceAll('\\', '/').split('/').last;
}

typedef EngineRepositoryResolver = Future<EngineRepository?> Function();

/// Shared engine and context-panel state consumed by every Flutter layout.
final class DashboardController extends ChangeNotifier {
  DashboardController(this._repositoryResolver, {this.initialWorkspaceUuid}) {
    settings = DashboardSettingsController(
      repositoryProvider: () => repository,
    );
  }

  static const Duration reconnectInterval = Duration(seconds: 3);
  static const Duration requestTimeout = Duration(seconds: 5);

  final EngineRepositoryResolver _repositoryResolver;
  final String? initialWorkspaceUuid;
  late final DashboardSettingsController settings;
  EngineRepository? _repository;

  EngineRepository? get repository => _repository;

  EngineLlmProvider? chatProvider;
  EngineConnectionStatus connectionStatus = EngineConnectionStatus.connecting;
  List<Workspace> workspaces = const <Workspace>[];
  List<ThreadInfo> threads = const <ThreadInfo>[];
  Workspace? selectedWorkspace;
  ThreadInfo? selectedThread;
  Object? error;
  Object? workspacesError;
  Object? threadsError;
  Object? filesError;
  bool isLoadingWorkspaces = false;
  bool isLoadingThreads = false;
  bool isLoadingFile = false;
  bool isSavingFile = false;
  OpenWorkspaceFile? openFile;

  final Map<String, List<WorkspaceFileEntry>> _directoryEntries =
      <String, List<WorkspaceFileEntry>>{};
  final Set<String> _loadingDirectories = <String>{};
  Timer? _reconnectTimer;
  bool _connectionCheckInProgress = false;
  bool _disposed = false;
  int _threadRequestVersion = 0;
  int _fileRequestVersion = 0;

  bool get isConnected => connectionStatus == EngineConnectionStatus.connected;
  bool get isLoading =>
      connectionStatus == EngineConnectionStatus.connecting &&
      workspaces.isEmpty;

  List<WorkspaceDirectoryRoot> get fileRoots {
    final String? rawDirectories = selectedWorkspace?.directories;
    if (rawDirectories == null || rawDirectories.trim().isEmpty) {
      return const <WorkspaceDirectoryRoot>[];
    }
    try {
      final Object? decoded = jsonDecode(rawDirectories);
      if (decoded is! List<Object?>) return const <WorkspaceDirectoryRoot>[];
      return <WorkspaceDirectoryRoot>[
        for (int index = 0; index < decoded.length; index++)
          if (decoded[index] is String &&
              (decoded[index]! as String).trim().isNotEmpty)
            WorkspaceDirectoryRoot(
              index: index,
              path: decoded[index]! as String,
            ),
      ];
    } on FormatException {
      return const <WorkspaceDirectoryRoot>[];
    }
  }

  Future<void> load() async {
    _reconnectTimer ??= Timer.periodic(
      reconnectInterval,
      (_) => unawaited(_checkConnection()),
    );
    await _checkConnection();
  }

  Future<void> reconnectNow() => _checkConnection(forceConnectingState: true);

  Future<void> _checkConnection({bool forceConnectingState = false}) async {
    if (_connectionCheckInProgress || _disposed) return;
    _connectionCheckInProgress = true;
    final EngineRepository? currentRepository = _repository;
    final bool canReuseCurrent =
        !forceConnectingState && currentRepository != null && isConnected;
    if (!canReuseCurrent || !currentRepository.socket.isConnected) {
      connectionStatus = EngineConnectionStatus.connecting;
      notifyListeners();
    }

    try {
      if (canReuseCurrent) {
        try {
          await currentRepository.rest.health().timeout(requestTimeout);
          if (!currentRepository.socket.isConnected) {
            await currentRepository.connect().timeout(requestTimeout);
          }
          connectionStatus = EngineConnectionStatus.connected;
          error = null;
          notifyListeners();
          if (workspaces.isEmpty) await loadWorkspaces();
          return;
        } on Object {
          await _closeRepository(currentRepository);
        }
      } else if (currentRepository != null) {
        await _closeRepository(currentRepository);
      }

      final EngineRepository? discoveredRepository = await _repositoryResolver()
          .timeout(requestTimeout);
      if (discoveredRepository == null) {
        throw StateError(
          'No reachable Subconscious engine was discovered. Start the engine or configure an explicit endpoint.',
        );
      }
      _repository = discoveredRepository;
      await discoveredRepository.rest.health().timeout(requestTimeout);
      await discoveredRepository.connect().timeout(requestTimeout);
      connectionStatus = EngineConnectionStatus.connected;
      error = null;
      notifyListeners();
      await loadWorkspaces();
    } on Object catch (caughtError) {
      final EngineRepository? failedRepository = _repository;
      if (failedRepository != null) await _closeRepository(failedRepository);
      connectionStatus = EngineConnectionStatus.disconnected;
      error = caughtError;
      notifyListeners();
    } finally {
      _connectionCheckInProgress = false;
    }
  }

  Future<void> _closeRepository(EngineRepository repositoryToClose) async {
    if (identical(_repository, repositoryToClose)) _repository = null;
    chatProvider?.dispose();
    chatProvider = null;
    try {
      await repositoryToClose.socket.dispose();
    } on Object {
      // Best effort while replacing a failed connection.
    }
    try {
      await repositoryToClose.rest.close();
    } on Object {
      // Best effort while replacing a failed connection.
    }
  }

  Future<void> loadWorkspaces() async {
    final EngineRepository? currentRepository = repository;
    if (currentRepository == null || !isConnected) return;
    isLoadingWorkspaces = true;
    workspacesError = null;
    notifyListeners();
    try {
      final List<Workspace> loaded = await currentRepository
          .listWorkspaces()
          .timeout(requestTimeout);
      workspaces = loaded;
      final String? preferredUuid =
          selectedWorkspace?.uuid ?? initialWorkspaceUuid;
      Workspace? nextWorkspace;
      for (final Workspace workspace in loaded) {
        if (workspace.uuid == preferredUuid) {
          nextWorkspace = workspace;
          break;
        }
      }
      nextWorkspace ??= loaded.firstOrNull;
      await selectWorkspace(nextWorkspace);
    } on Object catch (caughtError) {
      workspacesError = caughtError;
    } finally {
      isLoadingWorkspaces = false;
      notifyListeners();
    }
  }

  Future<void> selectWorkspace(Workspace? workspace) async {
    selectedWorkspace = workspace;
    selectedThread = null;
    threads = const <ThreadInfo>[];
    threadsError = null;
    _threadRequestVersion++;
    _clearFiles();
    _setChatScope(workspaceUuid: workspace?.uuid);
    notifyListeners();
    if (workspace == null || repository == null || !isConnected) return;

    final int requestVersion = _threadRequestVersion;
    isLoadingThreads = true;
    notifyListeners();
    try {
      final List<ThreadInfo> loaded = await repository!
          .listThreads(workspace.uuid)
          .timeout(requestTimeout);
      if (requestVersion != _threadRequestVersion) return;
      threads = loaded;
    } on Object catch (caughtError) {
      if (requestVersion == _threadRequestVersion) threadsError = caughtError;
    } finally {
      if (requestVersion == _threadRequestVersion) {
        isLoadingThreads = false;
        notifyListeners();
      }
    }
  }

  void selectThread(ThreadInfo thread) {
    selectedThread = thread;
    _setChatScope(threadUuid: thread.uuid);
    notifyListeners();
  }

  Future<void> createWorkspace({
    required String name,
    String? description,
  }) async {
    final RestEngineClient? client = repository?.rest;
    if (client == null) return;
    final Workspace created = await client
        .createWorkspace(name: name, description: description)
        .timeout(requestTimeout);
    workspaces = <Workspace>[...workspaces, created];
    await selectWorkspace(created);
  }

  Future<void> updateWorkspace(
    Workspace workspace, {
    required String name,
    String? description,
  }) async {
    final RestEngineClient? client = repository?.rest;
    if (client == null) return;
    final Workspace updated = await client
        .updateWorkspace(
          workspaceUuid: workspace.uuid,
          name: name,
          description: description,
          defaultModelId: workspace.defaultModelId,
          toolsConfig: workspace.toolsConfig,
          directories: workspace.directories,
          approvalConfig: workspace.approvalConfig,
          ragConfig: workspace.ragConfig,
        )
        .timeout(requestTimeout);
    workspaces = workspaces
        .map((Workspace item) => item.uuid == updated.uuid ? updated : item)
        .toList(growable: false);
    if (selectedWorkspace?.uuid == updated.uuid) selectedWorkspace = updated;
    notifyListeners();
  }

  List<WorkspaceFileEntry>? directoryEntries(int rootIndex, String path) =>
      _directoryEntries[_directoryKey(rootIndex, path)];

  bool isDirectoryLoading(int rootIndex, String path) =>
      _loadingDirectories.contains(_directoryKey(rootIndex, path));

  Future<void> loadDirectory(int rootIndex, String path) async {
    final Workspace? workspace = selectedWorkspace;
    final RestEngineClient? client = repository?.rest;
    final String key = _directoryKey(rootIndex, path);
    if (workspace == null ||
        client == null ||
        _loadingDirectories.contains(key))
      return;
    _loadingDirectories.add(key);
    filesError = null;
    notifyListeners();
    try {
      _directoryEntries[key] = await client
          .listFiles(
            workspaceUuid: workspace.uuid,
            rootIndex: rootIndex,
            path: path.isEmpty ? null : path,
          )
          .timeout(requestTimeout);
    } on Object catch (caughtError) {
      filesError = caughtError;
    } finally {
      _loadingDirectories.remove(key);
      notifyListeners();
    }
  }

  Future<void> refreshFiles() async {
    _directoryEntries.clear();
    openFile = null;
    filesError = null;
    notifyListeners();
    await Future.wait(<Future<void>>[
      for (final WorkspaceDirectoryRoot root in fileRoots)
        loadDirectory(root.index, ''),
    ]);
  }

  Future<void> openWorkspaceFile(int rootIndex, String path) async {
    final Workspace? workspace = selectedWorkspace;
    final RestEngineClient? client = repository?.rest;
    if (workspace == null || client == null) return;
    final int requestVersion = ++_fileRequestVersion;
    isLoadingFile = true;
    filesError = null;
    notifyListeners();
    try {
      final WorkspaceFileContent result = await client
          .readFile(
            workspaceUuid: workspace.uuid,
            rootIndex: rootIndex,
            path: path,
          )
          .timeout(requestTimeout);
      if (requestVersion == _fileRequestVersion)
        openFile = OpenWorkspaceFile(
          rootIndex: rootIndex,
          path: path,
          content: result.content,
        );
    } on Object catch (caughtError) {
      if (requestVersion == _fileRequestVersion) filesError = caughtError;
    } finally {
      if (requestVersion == _fileRequestVersion) {
        isLoadingFile = false;
        notifyListeners();
      }
    }
  }

  Future<void> saveOpenFile(String content) async {
    final Workspace? workspace = selectedWorkspace;
    final OpenWorkspaceFile? file = openFile;
    final RestEngineClient? client = repository?.rest;
    if (workspace == null || file == null || client == null) return;
    isSavingFile = true;
    filesError = null;
    notifyListeners();
    try {
      await client
          .writeFile(
            workspaceUuid: workspace.uuid,
            rootIndex: file.rootIndex,
            path: file.path,
            content: content,
          )
          .timeout(requestTimeout);
      openFile = OpenWorkspaceFile(
        rootIndex: file.rootIndex,
        path: file.path,
        content: content,
      );
    } on Object catch (caughtError) {
      filesError = caughtError;
    } finally {
      isSavingFile = false;
      notifyListeners();
    }
  }

  Future<void> createFile({
    required int rootIndex,
    required String path,
  }) async {
    final Workspace? workspace = selectedWorkspace;
    final RestEngineClient? client = repository?.rest;
    if (workspace == null || client == null) return;
    await client
        .createFile(
          workspaceUuid: workspace.uuid,
          rootIndex: rootIndex,
          path: path,
          content: '',
        )
        .timeout(requestTimeout);
    await _reloadParent(rootIndex, path);
    await openWorkspaceFile(rootIndex, path);
  }

  Future<void> createDirectory({
    required int rootIndex,
    required String path,
  }) async {
    final Workspace? workspace = selectedWorkspace;
    final RestEngineClient? client = repository?.rest;
    if (workspace == null || client == null) return;
    await client
        .createDirectory(
          workspaceUuid: workspace.uuid,
          rootIndex: rootIndex,
          path: path,
        )
        .timeout(requestTimeout);
    await _reloadParent(rootIndex, path);
  }

  Future<void> _reloadParent(int rootIndex, String path) async {
    final String normalized = path.replaceAll('\\', '/');
    final int separator = normalized.lastIndexOf('/');
    final String parent = separator < 0
        ? ''
        : normalized.substring(0, separator);
    _directoryEntries.remove(_directoryKey(rootIndex, parent));
    await loadDirectory(rootIndex, parent);
  }

  void _setChatScope({String? workspaceUuid, String? threadUuid}) {
    chatProvider?.dispose();
    final EngineRepository? currentRepository = repository;
    chatProvider =
        currentRepository == null ||
            (workspaceUuid == null && threadUuid == null)
        ? null
        : EngineLlmProvider(
            repository: currentRepository,
            workspaceUuid: workspaceUuid,
            threadUuid: threadUuid,
          );
  }

  void _clearFiles() {
    _directoryEntries.clear();
    _loadingDirectories.clear();
    openFile = null;
    filesError = null;
    _fileRequestVersion++;
  }

  String _directoryKey(int rootIndex, String path) =>
      '$rootIndex:${path.replaceAll('\\', '/')}';

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    chatProvider?.dispose();
    settings.dispose();
    unawaited(repository?.socket.dispose());
    unawaited(repository?.rest.close());
    super.dispose();
  }
}
