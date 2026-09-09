import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/foundation.dart';

import '../../chat/engine_llm_provider.dart';
import '../../settings/controller/settings_controller.dart';

enum EngineConnectionStatus { disconnected, connecting, connected }

enum DashboardSection { workspaces, threads, files, settings, account }

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
    this.previewBytes,
    this.previewKind,
    this.mediaType,
  });

  final int rootIndex;
  final String path;
  final String content;
  final Uint8List? previewBytes;
  final WorkspacePreviewKind? previewKind;
  final String? mediaType;

  String get name => path.replaceAll('\\', '/').split('/').last;
  bool get isReadOnlyPreview => previewKind != null && previewBytes != null;
  bool get isImage => previewKind == WorkspacePreviewKind.image;
  bool get isDocumentPreview =>
      previewKind == WorkspacePreviewKind.pdf ||
      previewKind == WorkspacePreviewKind.docx;
  bool get isSvg => mediaType == 'image/svg+xml';

  static WorkspacePreviewKind? previewKindForPath(String path) {
    final String lower = path.toLowerCase();
    if (const <String>[
      '.bmp',
      '.gif',
      '.jpeg',
      '.jpg',
      '.png',
      '.svg',
      '.webp',
    ].any(lower.endsWith)) {
      return WorkspacePreviewKind.image;
    }
    if (lower.endsWith('.pdf')) return WorkspacePreviewKind.pdf;
    if (lower.endsWith('.docx')) return WorkspacePreviewKind.docx;
    return null;
  }

  static bool supportsPreview(String path) => previewKindForPath(path) != null;
}

/// A stable reference to a file within one of a workspace's directory roots.
final class WorkspaceFileReference {
  WorkspaceFileReference({required this.rootIndex, required this.path})
    : key = _createKey(rootIndex, path);

  final int rootIndex;
  final String path;
  final String key;

  factory WorkspaceFileReference.fromJson(Map<String, dynamic> json) {
    final Object? rootIndex = json['rootIndex'];
    final Object? path = json['path'];
    if (rootIndex is! int || rootIndex < 0 || path is! String || path.isEmpty) {
      throw const FormatException('Invalid workspace file reference.');
    }
    return WorkspaceFileReference(rootIndex: rootIndex, path: path);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'rootIndex': rootIndex,
    'path': path,
    'key': key,
  };

  static String _createKey(int rootIndex, String path) =>
      '$rootIndex:${path.replaceAll('\\', '/')}';
}

final class _WorkspaceViewerState {
  _WorkspaceViewerState({
    List<WorkspaceFileReference>? openFiles,
    this.activeFileKey,
    Set<String>? expandedDirectoryKeys,
  }) : openFiles = openFiles ?? <WorkspaceFileReference>[],
       expandedDirectoryKeys = expandedDirectoryKeys ?? <String>{};

  List<WorkspaceFileReference> openFiles;
  String? activeFileKey;
  final Set<String> expandedDirectoryKeys;
}

typedef EngineRepositoryResolver = Future<EngineRepository?> Function({
  Uri? explicitEndpoint,
  String? explicitToken,
});

/// Shared engine and context-panel state consumed by every Flutter layout.
final class DashboardController extends ChangeNotifier {
  DashboardController(
    this._repositoryResolver, {
    this.initialWorkspaceUuid,
    Uri? initialEndpoint,
    String? initialToken,
  }) : _explicitEndpoint = initialEndpoint,
       _explicitToken = initialToken {
    settings = DashboardSettingsController(
      repositoryProvider: () => repository,
    );
  }

  static const Duration reconnectInterval = Duration(seconds: 3);
  static const Duration requestTimeout = Duration(seconds: 5);
  static const Duration appStateSaveDebounce = Duration(milliseconds: 300);
  static const String appStateKey = 'dashboard_state_v2';
  static const String navigationKey = 'dashboard_navigation_v1';
  static const String navigationTag = 'navigation';

  final EngineRepositoryResolver _repositoryResolver;
  final String? initialWorkspaceUuid;
  late final DashboardSettingsController settings;
  EngineRepository? _repository;
  Uri? _explicitEndpoint;
  String? _explicitToken;

  EngineRepository? get repository => _repository;
  Uri? get explicitEndpoint => _explicitEndpoint;
  String? get explicitHost => _explicitEndpoint?.host;
  String? get explicitPort => _explicitEndpoint == null
      ? null
      : '${_explicitEndpoint!.hasPort ? _explicitEndpoint!.port : 80}';
  bool get hasExplicitToken => _explicitToken?.isNotEmpty ?? false;

  /// Replaces the active engine connection with a LAN endpoint and token.
  /// The connection details stay in memory for the current app session.
  Future<String?> connectToRemoteEngine({
    required String host,
    required String port,
    required String token,
  }) async {
    final String normalizedHost = _normalizeRemoteHost(host);
    final int? parsedPort = int.tryParse(port.trim());
    final String trimmedToken = token.trim();
    if (normalizedHost.isEmpty ||
        normalizedHost.contains(RegExp(r'[\s/?#]')) ||
        parsedPort == null ||
        parsedPort < 1 ||
        parsedPort > 65535 ||
        (trimmedToken.isEmpty && !hasExplicitToken)) {
      return 'Enter a host, a port from 1 to 65535, and a joining token.';
    }

    try {
      _explicitEndpoint = Uri(
        scheme: 'http',
        host: normalizedHost,
        port: parsedPort,
      );
    } on FormatException {
      return 'Enter a valid LAN host or IP address.';
    }
    if (trimmedToken.isNotEmpty) _explicitToken = trimmedToken;
    await reconnectNow();
    return isConnected
        ? null
        : '${error ?? 'Unable to connect to the specified engine.'}';
  }

  static String _normalizeRemoteHost(String host) {
    final String trimmed = host.trim();
    return trimmed.startsWith('[') && trimmed.endsWith(']')
        ? trimmed.substring(1, trimmed.length - 1)
        : trimmed;
  }

  EngineLlmProvider? chatProvider;
  EngineConnectionStatus connectionStatus = EngineConnectionStatus.connecting;
  DashboardSection selectedSection = DashboardSection.threads;
  List<Workspace> workspaces = const <Workspace>[];
  List<ThreadInfo> threads = const <ThreadInfo>[];
  Workspace? selectedWorkspace;
  Workspace? activeWorkspace;
  Workspace? get threadsWorkspace => activeWorkspace;
  ThreadInfo? selectedThread;
  String? pendingDraftTitle;
  String? pendingDraftToolsConfig;
  int chatSessionVersion = 0;
  Object? error;
  Object? workspacesError;
  Object? threadsError;
  Object? chatError;
  Object? filesError;
  Object? navigationError;
  bool isLoadingWorkspaces = false;
  bool isLoadingThreads = false;
  bool isLoadingChat = false;
  bool isLoadingFile = false;
  bool isSavingFile = false;
  bool isCreatingWorkspace = false;
  bool hasLoadedNavigationState = false;
  OpenWorkspaceFile? openFile;
  String? selectedFileTreeNodeKey;

  bool chatPanelVisible = true;
  bool mainPanelVisible = true;
  bool contextPanelVisible = true;
  double chatPanelWidth = 280;
  double contextPanelWidth = 280;
  double? windowX;
  double? windowY;
  double? windowWidth;
  double? windowHeight;
  bool windowMaximized = false;

  String? _workspacesWorkspaceUuid;
  String? _threadsWorkspaceUuid;
  String? _threadsThreadUuid;
  final Map<String, String> _threadUuidsByWorkspace = <String, String>{};
  String? _filesWorkspaceUuid;
  int? _filesRootIndex;
  String? _filesPath;

  final Map<String, List<WorkspaceFileEntry>> _directoryEntries =
      <String, List<WorkspaceFileEntry>>{};
  final Set<String> _loadingDirectories = <String>{};
  final Map<String, _WorkspaceViewerState> _workspaceViewerStates =
      <String, _WorkspaceViewerState>{};
  Timer? _reconnectTimer;
  Timer? _appStateSaveTimer;
  bool _connectionCheckInProgress = false;
  bool _isRestoringNavigation = false;
  Future<void>? _appStateWriteFuture;
  bool _disposed = false;
  int _threadRequestVersion = 0;
  int _chatRequestVersion = 0;
  int _fileRequestVersion = 0;
  int _sectionActivationVersion = 0;
  int _appStateVersion = 0;
  int _appStateSavedVersion = 0;

  bool get isConnected => connectionStatus == EngineConnectionStatus.connected;
  bool get isLoading =>
      connectionStatus == EngineConnectionStatus.connecting &&
      workspaces.isEmpty;

  List<WorkspaceFileReference> get rememberedOpenFiles =>
      List<WorkspaceFileReference>.unmodifiable(
        _currentViewerState?.openFiles ?? const <WorkspaceFileReference>[],
      );

  String? get rememberedActiveFileKey => _currentViewerState?.activeFileKey;

  bool get hasWindowBounds =>
      _isFinite(windowX) &&
      _isFinite(windowY) &&
      _isPositiveFinite(windowWidth) &&
      _isPositiveFinite(windowHeight);

  void rememberOpenFiles(
    List<WorkspaceFileReference> files, {
    String? activeKey,
  }) {
    final String? workspaceUuid = activeWorkspace?.uuid;
    if (workspaceUuid == null) return;
    final Set<String> seen = <String>{};
    final List<WorkspaceFileReference> ordered = <WorkspaceFileReference>[
      for (final WorkspaceFileReference file in files)
        if (seen.add(file.key)) file,
    ];
    final _WorkspaceViewerState? existingState =
        _workspaceViewerStates[workspaceUuid];
    if (existingState == null && ordered.isEmpty && activeKey == null) return;
    if (existingState != null &&
        existingState.activeFileKey == activeKey &&
        existingState.openFiles.length == ordered.length) {
      bool unchanged = true;
      for (int index = 0; index < ordered.length; index++) {
        if (existingState.openFiles[index].key != ordered[index].key) {
          unchanged = false;
          break;
        }
      }
      if (unchanged) return;
    }
    final _WorkspaceViewerState state =
        existingState ?? _WorkspaceViewerState();
    _workspaceViewerStates[workspaceUuid] = state;
    state
      ..openFiles = ordered
      ..activeFileKey = activeKey;
    _markAppStateChanged();
    notifyListeners();
  }

  bool isDirectoryExpanded(
    int rootIndex,
    String path, {
    bool defaultValue = false,
  }) {
    final _WorkspaceViewerState? state = _currentViewerState;
    if (state == null) return defaultValue;
    return state.expandedDirectoryKeys.contains(_directoryKey(rootIndex, path));
  }

  void setDirectoryExpanded(int rootIndex, String path, bool expanded) {
    final String? workspaceUuid = activeWorkspace?.uuid;
    if (workspaceUuid == null) return;
    final _WorkspaceViewerState? existingState =
        _workspaceViewerStates[workspaceUuid];
    final _WorkspaceViewerState state =
        existingState ?? _WorkspaceViewerState();
    _workspaceViewerStates[workspaceUuid] = state;
    final String key = _directoryKey(rootIndex, path);
    final bool membershipChanged = expanded
        ? state.expandedDirectoryKeys.add(key)
        : state.expandedDirectoryKeys.remove(key);
    final bool changed = existingState == null || membershipChanged;
    if (!changed) return;
    _markAppStateChanged();
    notifyListeners();
  }

  void updateLayoutState({
    bool? chatPanelVisible,
    bool? mainPanelVisible,
    bool? contextPanelVisible,
    double? chatPanelWidth,
    double? contextPanelWidth,
  }) {
    bool changed = false;
    if (chatPanelVisible != null && chatPanelVisible != this.chatPanelVisible) {
      this.chatPanelVisible = chatPanelVisible;
      changed = true;
    }
    if (mainPanelVisible != null && mainPanelVisible != this.mainPanelVisible) {
      this.mainPanelVisible = mainPanelVisible;
      changed = true;
    }
    if (contextPanelVisible != null &&
        contextPanelVisible != this.contextPanelVisible) {
      this.contextPanelVisible = contextPanelVisible;
      changed = true;
    }
    if (_isPositiveFinite(chatPanelWidth) &&
        chatPanelWidth != this.chatPanelWidth) {
      this.chatPanelWidth = chatPanelWidth!;
      changed = true;
    }
    if (_isPositiveFinite(contextPanelWidth) &&
        contextPanelWidth != this.contextPanelWidth) {
      this.contextPanelWidth = contextPanelWidth!;
      changed = true;
    }
    if (!changed) return;
    _markAppStateChanged();
    notifyListeners();
  }

  void updateWindowState({
    double? windowX,
    double? windowY,
    double? windowWidth,
    double? windowHeight,
    bool? windowMaximized,
  }) {
    bool changed = false;
    if (_isFinite(windowX) && windowX != this.windowX) {
      this.windowX = windowX;
      changed = true;
    }
    if (_isFinite(windowY) && windowY != this.windowY) {
      this.windowY = windowY;
      changed = true;
    }
    if (_isPositiveFinite(windowWidth) && windowWidth != this.windowWidth) {
      this.windowWidth = windowWidth;
      changed = true;
    }
    if (_isPositiveFinite(windowHeight) && windowHeight != this.windowHeight) {
      this.windowHeight = windowHeight;
      changed = true;
    }
    if (windowMaximized != null && windowMaximized != this.windowMaximized) {
      this.windowMaximized = windowMaximized;
      changed = true;
    }
    if (!changed) return;
    _markAppStateChanged();
    notifyListeners();
  }

  Workspace? get _filesWorkspace => activeWorkspace;

  List<WorkspaceDirectoryRoot> get fileRoots {
    final String? rawDirectories = activeWorkspace?.directories;
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

  Future<void> activateSection(
    DashboardSection section, {
    bool persist = true,
  }) async {
    final int activationVersion = ++_sectionActivationVersion;
    selectedSection = section;
    switch (section) {
      case DashboardSection.workspaces:
        if (selectedWorkspace == null) {
          settings.showUtility();
        } else {
          settings.showWorkspace();
        }
      case DashboardSection.threads:
        settings.showUtility();
      case DashboardSection.files:
        settings.showFiles();
      case DashboardSection.settings:
        settings.showSettings();
      case DashboardSection.account:
        settings.showUtility();
    }
    notifyListeners();

    if (section == DashboardSection.threads && selectedThread == null) {
      final ThreadInfo? thread = _threadByUuid(_threadsThreadUuid);
      if (thread != null) {
        await selectThread(thread, remember: false);
      } else if (_threadsThreadUuid != null) {
        if (_threadsWorkspaceUuid case final String workspaceUuid) {
          _setRememberedThread(workspaceUuid, null);
        } else {
          _threadsThreadUuid = null;
        }
      }
    } else if (section == DashboardSection.files) {
      final int? rootIndex = _filesRootIndex;
      final String? path = _filesPath;
      if (rootIndex != null && path != null && openFile == null) {
        final bool opened = await openWorkspaceFile(
          rootIndex,
          path,
          remember: false,
        );
        if (!opened) {
          _filesRootIndex = null;
          _filesPath = null;
        }
      }
    }
    if (activationVersion != _sectionActivationVersion ||
        selectedSection != section) {
      return;
    }
    if (persist) _markNavigationChanged();
    notifyListeners();
  }

  void openSettingsPage(SettingsPage page) {
    selectedSection = DashboardSection.settings;
    settings.openSettingsPage(page);
    _markNavigationChanged();
    notifyListeners();
  }

  void beginWorkspaceCreation() {
    if (!isConnected || isCreatingWorkspace) return;
    isCreatingWorkspace = true;
    settings.showWorkspace();
    notifyListeners();
  }

  void cancelWorkspaceCreation() {
    if (!isCreatingWorkspace) return;
    isCreatingWorkspace = false;
    notifyListeners();
  }

  Future<void> _loadNavigationState() async {
    if (hasLoadedNavigationState) return;
    final RestEngineClient? client = repository?.rest;
    if (client == null) return;
    final int versionAtStart = _appStateVersion;
    bool migratedLegacyState = false;
    try {
      final List<EngineSetting> loaded = await client
          .getSettings(key: appStateKey)
          .timeout(requestTimeout);
      if (versionAtStart != 0 || versionAtStart != _appStateVersion) {
        hasLoadedNavigationState = true;
        return;
      }

      _isRestoringNavigation = true;
      if (loaded.isEmpty) {
        migratedLegacyState = await _loadLegacyNavigationState(client);
      } else {
        _restoreAppState(loaded.last.value);
      }
      navigationError = null;
    } on Object catch (caughtError) {
      navigationError = caughtError;
    } finally {
      _isRestoringNavigation = false;
      hasLoadedNavigationState = true;
      if (migratedLegacyState) _markAppStateChanged();
      notifyListeners();
    }
  }

  Future<bool> _loadLegacyNavigationState(RestEngineClient client) async {
    final List<EngineSetting> loaded = await client
        .getSettings(
          key: navigationKey,
          tag: navigationTag,
          client: DashboardSettingsController.settingsClient,
        )
        .timeout(requestTimeout);
    if (loaded.isEmpty) return false;
    final Object? decoded = jsonDecode(loaded.last.value);
    final Map<String, dynamic> root = _objectValue(decoded);
    if (root['version'] != 1) return false;
    _restoreNavigation(root);
    return true;
  }

  void _restoreAppState(String value) {
    final Object? decoded = jsonDecode(value);
    final Map<String, dynamic> root = _objectValue(decoded);
    if (root['version'] != 2) {
      throw const FormatException('Unsupported dashboard app-state version.');
    }
    _restoreNavigation(root);
    _restoreFileViewer(root['fileViewer']);

    final Map<String, dynamic> layout = _objectValue(root['layout']);
    chatPanelVisible = _boolValue(layout['chatPanelVisible']) ?? true;
    mainPanelVisible = _boolValue(layout['mainPanelVisible']) ?? true;
    contextPanelVisible = _boolValue(layout['contextPanelVisible']) ?? true;
    chatPanelWidth = _positiveDoubleValue(layout['chatPanelWidth']) ?? 280;
    contextPanelWidth =
        _positiveDoubleValue(layout['contextPanelWidth']) ?? 280;

    final Map<String, dynamic> window = _objectValue(root['window']);
    windowX = _doubleValue(window['x']);
    windowY = _doubleValue(window['y']);
    windowWidth = _positiveDoubleValue(window['width']);
    windowHeight = _positiveDoubleValue(window['height']);
    windowMaximized = _boolValue(window['maximized']) ?? false;
  }

  void _restoreNavigation(Map<String, dynamic> root) {
    selectedSection =
        _enumValue(DashboardSection.values, root['activeSection']) ??
        DashboardSection.threads;
    final Map<String, dynamic> sections = _objectValue(root['sections']);
    final Map<String, dynamic> workspaces = _objectValue(
      sections['workspaces'],
    );
    final Map<String, dynamic> threads = _objectValue(sections['threads']);
    final Map<String, dynamic> files = _objectValue(sections['files']);
    final Map<String, dynamic> settingsState = _objectValue(
      sections['settings'],
    );
    _workspacesWorkspaceUuid = _stringValue(workspaces['workspaceUuid']);
    _threadsWorkspaceUuid = _stringValue(threads['workspaceUuid']);
    _threadUuidsByWorkspace.clear();
    final Map<String, dynamic> rememberedThreads = _objectValue(
      threads['threadUuidsByWorkspace'],
    );
    for (final MapEntry<String, dynamic> entry in rememberedThreads.entries) {
      final String? threadUuid = _stringValue(entry.value);
      if (entry.key.isNotEmpty && threadUuid?.isNotEmpty == true) {
        _threadUuidsByWorkspace[entry.key] = threadUuid!;
      }
    }
    final String? legacyThreadUuid = _stringValue(threads['threadUuid']);
    if (_threadsWorkspaceUuid case final String workspaceUuid) {
      if (legacyThreadUuid != null) {
        _threadUuidsByWorkspace.putIfAbsent(
          workspaceUuid,
          () => legacyThreadUuid,
        );
      }
      _threadsThreadUuid = _threadUuidsByWorkspace[workspaceUuid];
    } else {
      _threadsThreadUuid = null;
    }
    _filesWorkspaceUuid = _stringValue(files['workspaceUuid']);
    _filesRootIndex = _nonNegativeIntValue(files['rootIndex']);
    _filesPath = _stringValue(files['path']);
    settings.activePage =
        _enumValue(SettingsPage.values, settingsState['page']) ??
        SettingsPage.general;
  }

  void _restoreFileViewer(Object? value) {
    _workspaceViewerStates.clear();
    final Map<String, dynamic> fileViewer = _objectValue(value);
    final Map<String, dynamic> nestedWorkspaces = _objectValue(
      fileViewer['workspaces'],
    );
    final Map<String, dynamic> workspaceMap = nestedWorkspaces.isNotEmpty
        ? nestedWorkspaces
        : fileViewer;
    for (final MapEntry<String, dynamic> entry in workspaceMap.entries) {
      final Map<String, dynamic> stateJson = _objectValue(entry.value);
      if (stateJson.isEmpty) continue;
      final List<WorkspaceFileReference> openFiles = <WorkspaceFileReference>[];
      final Set<String> seenFileKeys = <String>{};
      final Object? rawOpenFiles = stateJson['openFiles'];
      if (rawOpenFiles is List) {
        for (final Object? rawFile in rawOpenFiles) {
          try {
            final WorkspaceFileReference file = WorkspaceFileReference.fromJson(
              _objectValue(rawFile),
            );
            if (seenFileKeys.add(file.key)) openFiles.add(file);
          } on FormatException {
            // Ignore malformed file references without discarding other state.
          }
        }
      }
      final Set<String> expandedDirectoryKeys = <String>{};
      final Object? rawExpanded =
          stateJson['expandedDirectoryKeys'] ??
          stateJson['expandedDirectories'];
      if (rawExpanded is List) {
        for (final Object? key in rawExpanded) {
          if (key is String && key.isNotEmpty) {
            expandedDirectoryKeys.add(key);
          }
        }
      }
      _workspaceViewerStates[entry.key] = _WorkspaceViewerState(
        openFiles: openFiles,
        activeFileKey: _stringValue(stateJson['activeFileKey']),
        expandedDirectoryKeys: expandedDirectoryKeys,
      );
    }
  }

  String _appStateSnapshot() => jsonEncode(<String, dynamic>{
    'version': 2,
    'activeSection': selectedSection.name,
    'sections': <String, dynamic>{
      'workspaces': <String, dynamic>{
        if (_workspacesWorkspaceUuid != null)
          'workspaceUuid': _workspacesWorkspaceUuid,
      },
      'threads': <String, dynamic>{
        if (_threadsWorkspaceUuid != null)
          'workspaceUuid': _threadsWorkspaceUuid,
        if (_threadsThreadUuid != null) 'threadUuid': _threadsThreadUuid,
        'threadUuidsByWorkspace': <String, String>{
          for (final MapEntry<String, String> entry
              in _threadUuidsByWorkspace.entries)
            entry.key: entry.value,
        },
      },
      'files': <String, dynamic>{
        if (_filesWorkspaceUuid != null) 'workspaceUuid': _filesWorkspaceUuid,
        if (_filesRootIndex != null) 'rootIndex': _filesRootIndex,
        if (_filesPath != null) 'path': _filesPath,
      },
      'settings': <String, dynamic>{'page': settings.activePage.name},
      'account': <String, dynamic>{},
    },
    'fileViewer': <String, dynamic>{
      for (final MapEntry<String, _WorkspaceViewerState> entry
          in _workspaceViewerStates.entries)
        entry.key: <String, dynamic>{
          'openFiles': <Map<String, dynamic>>[
            for (final WorkspaceFileReference file in entry.value.openFiles)
              file.toJson(),
          ],
          if (entry.value.activeFileKey != null)
            'activeFileKey': entry.value.activeFileKey,
          'expandedDirectoryKeys': entry.value.expandedDirectoryKeys.toList()
            ..sort(),
        },
    },
    'layout': <String, dynamic>{
      'chatPanelVisible': chatPanelVisible,
      'mainPanelVisible': mainPanelVisible,
      'contextPanelVisible': contextPanelVisible,
      'chatPanelWidth': _isPositiveFinite(chatPanelWidth)
          ? chatPanelWidth
          : 280,
      'contextPanelWidth': _isPositiveFinite(contextPanelWidth)
          ? contextPanelWidth
          : 280,
    },
    'window': <String, dynamic>{
      if (_isFinite(windowX)) 'x': windowX,
      if (_isFinite(windowY)) 'y': windowY,
      if (_isPositiveFinite(windowWidth)) 'width': windowWidth,
      if (_isPositiveFinite(windowHeight)) 'height': windowHeight,
      'maximized': windowMaximized,
    },
  });

  void _markNavigationChanged() => _markAppStateChanged();

  void _markAppStateChanged() {
    if (_isRestoringNavigation || _disposed) return;
    _appStateVersion++;
    navigationError = null;
    _schedulePendingAppStateSave();
  }

  void _schedulePendingNavigationSave() => _schedulePendingAppStateSave();

  void _schedulePendingAppStateSave() {
    if (_appStateSavedVersion >= _appStateVersion || _disposed) return;
    _appStateSaveTimer?.cancel();
    _appStateSaveTimer = Timer(
      appStateSaveDebounce,
      () => unawaited(flushAppState()),
    );
  }

  Future<void> flushAppState() {
    _appStateSaveTimer?.cancel();
    _appStateSaveTimer = null;
    if (_disposed || _appStateSavedVersion >= _appStateVersion) {
      return _appStateWriteFuture ?? Future<void>.value();
    }
    final Future<void>? currentWrite = _appStateWriteFuture;
    if (currentWrite != null) {
      return currentWrite.then((_) => flushAppState());
    }
    late final Future<void> write;
    write = _writePendingAppState().whenComplete(() {
      if (identical(_appStateWriteFuture, write)) {
        _appStateWriteFuture = null;
      }
    });
    _appStateWriteFuture = write;
    return write;
  }

  Future<void> _writePendingAppState() async {
    final RestEngineClient? client = repository?.rest;
    if (client == null) return;
    try {
      while (_appStateSavedVersion < _appStateVersion && !_disposed) {
        final int version = _appStateVersion;
        final String value = _appStateSnapshot();
        await client
            .putSettings(<EngineSetting>[
              EngineSetting(key: appStateKey, value: value),
            ])
            .timeout(requestTimeout);
        _appStateSavedVersion = version;
        navigationError = null;
      }
    } on Object catch (caughtError) {
      navigationError = caughtError;
      notifyListeners();
    } finally {
      if (_appStateSavedVersion < _appStateVersion &&
          navigationError == null &&
          !_disposed) {
        _schedulePendingAppStateSave();
      }
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
          if (!settings.hasLoadedGeneralSettings) {
            await settings.loadGeneralSettings();
          }
          if (!hasLoadedNavigationState) await _loadNavigationState();
          if (workspaces.isEmpty) {
            await loadWorkspaces();
          }
          _schedulePendingNavigationSave();
          return;
        } on Object {
          await _closeRepository(currentRepository);
        }
      } else if (currentRepository != null) {
        await _closeRepository(currentRepository);
      }

      final EngineRepository? discoveredRepository = await _repositoryResolver(
        explicitEndpoint: _explicitEndpoint,
        explicitToken: _explicitToken,
      ).timeout(requestTimeout);
      if (discoveredRepository == null) {
        throw StateError(
          'No reachable Subconscious engine was discovered. Start the engine or configure an explicit endpoint.',
        );
      }
      _repository = discoveredRepository;
      await discoveredRepository.rest.health().timeout(requestTimeout);
      await discoveredRepository.connect().timeout(requestTimeout);
      chatProvider?.replaceRepository(discoveredRepository);
      await settings.loadGeneralSettings(force: true);
      await _loadNavigationState();
      connectionStatus = EngineConnectionStatus.connected;
      error = null;
      notifyListeners();
      await loadWorkspaces();
      _schedulePendingNavigationSave();
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
    _chatRequestVersion++;
    isLoadingChat = false;
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
      final Set<String> workspaceUuids = <String>{
        for (final Workspace workspace in loaded) workspace.uuid,
      };
      final int rememberedThreadCount = _threadUuidsByWorkspace.length;
      _threadUuidsByWorkspace.removeWhere(
        (String workspaceUuid, String _) =>
            !workspaceUuids.contains(workspaceUuid),
      );
      if (_threadUuidsByWorkspace.length != rememberedThreadCount) {
        _markNavigationChanged();
      }

      final Workspace? managementWorkspace =
          _workspaceByUuid(
            selectedWorkspace?.uuid ??
                _workspacesWorkspaceUuid ??
                initialWorkspaceUuid,
          ) ??
          loaded.firstOrNull;
      final Workspace? restoredActiveWorkspace =
          _workspaceByUuid(
            activeWorkspace?.uuid ??
                _threadsWorkspaceUuid ??
                _filesWorkspaceUuid ??
                initialWorkspaceUuid ??
                managementWorkspace?.uuid,
          ) ??
          managementWorkspace;
      await selectWorkspace(managementWorkspace, remember: false);
      await selectActiveWorkspace(restoredActiveWorkspace, remember: false);
      await activateSection(selectedSection, persist: navigationError == null);
    } on Object catch (caughtError) {
      workspacesError = caughtError;
    } finally {
      isLoadingWorkspaces = false;
      notifyListeners();
    }
  }

  Future<void> selectWorkspace(
    Workspace? workspace, {
    bool remember = true,
  }) async {
    isCreatingWorkspace = false;
    selectedWorkspace = workspace;
    if (remember) {
      _workspacesWorkspaceUuid = workspace?.uuid;
      _markNavigationChanged();
    } else {
      _workspacesWorkspaceUuid ??= workspace?.uuid;
    }
    notifyListeners();
  }

  Future<void> selectThreadWorkspace(
    Workspace? workspace, {
    bool remember = true,
  }) => selectActiveWorkspace(workspace, remember: remember);

  Future<void> selectActiveWorkspace(
    Workspace? workspace, {
    bool remember = true,
  }) async {
    final bool changed = activeWorkspace?.uuid != workspace?.uuid;
    activeWorkspace = workspace;
    if (changed) {
      selectedThread = null;
      pendingDraftTitle = null;
      pendingDraftToolsConfig = null;
      threads = const <ThreadInfo>[];
      threadsError = null;
      isLoadingThreads = false;
      _threadRequestVersion++;
      _threadsThreadUuid = workspace == null
          ? null
          : _threadUuidsByWorkspace[workspace.uuid];
      _clearFiles();
      chatSessionVersion++;
      _setChatScope(
        workspaceUuid: workspace?.uuid,
        modelId: workspace?.defaultModelId,
      );
    }
    _threadsWorkspaceUuid = workspace?.uuid;
    _filesWorkspaceUuid = workspace?.uuid;
    if (remember) _markNavigationChanged();
    notifyListeners();
    if (workspace == null || repository == null || !isConnected) return;

    final int requestVersion = ++_threadRequestVersion;
    isLoadingThreads = true;
    threadsError = null;
    notifyListeners();
    ThreadInfo? rememberedThread;
    try {
      final List<ThreadInfo> loaded = await repository!
          .listThreads(workspace.uuid)
          .timeout(requestTimeout);
      if (requestVersion != _threadRequestVersion) return;
      threads = loaded;
      final String? rememberedUuid = _threadUuidsByWorkspace[workspace.uuid];
      rememberedThread = _threadByUuid(rememberedUuid);
      if (rememberedUuid != null && rememberedThread == null) {
        _setRememberedThread(workspace.uuid, null);
        _markNavigationChanged();
      }
    } on Object catch (caughtError) {
      if (requestVersion == _threadRequestVersion) threadsError = caughtError;
    } finally {
      if (requestVersion == _threadRequestVersion) {
        isLoadingThreads = false;
        notifyListeners();
      }
    }
    if (rememberedThread == null ||
        requestVersion != _threadRequestVersion ||
        activeWorkspace?.uuid != workspace.uuid) {
      return;
    }
    if (selectedThread?.uuid == rememberedThread.uuid) {
      selectedThread = rememberedThread;
      notifyListeners();
      return;
    }
    await selectThread(rememberedThread, remember: false);
  }

  Future<void> selectThread(ThreadInfo thread, {bool remember = true}) async {
    final EngineRepository? currentRepository = repository;
    final int requestVersion = ++_chatRequestVersion;
    selectedThread = thread;
    pendingDraftTitle = null;
    pendingDraftToolsConfig = null;
    chatSessionVersion++;
    final String workspaceUuid = threadsWorkspace?.uuid ?? thread.workspaceUuid;
    _threadsWorkspaceUuid = workspaceUuid;
    _setRememberedThread(workspaceUuid, thread.uuid);
    if (remember) _markNavigationChanged();
    chatProvider?.dispose();
    chatProvider = null;
    chatError = null;
    isLoadingChat = true;
    notifyListeners();
    if (currentRepository == null || !isConnected) {
      isLoadingChat = false;
      chatError = StateError('The Subconscious engine is not connected.');
      notifyListeners();
      return;
    }

    try {
      final List<ChatMessage> messages = await currentRepository
          .listMessages(thread.uuid)
          .timeout(requestTimeout);
      if (_disposed ||
          requestVersion != _chatRequestVersion ||
          selectedThread?.uuid != thread.uuid) {
        return;
      }
      final EngineLlmProvider provider = EngineLlmProvider(
        repository: currentRepository,
        threadUuid: thread.uuid,
        modelId: thread.defaultModelId ?? threadsWorkspace?.defaultModelId,
      );
      provider.replaceEngineHistory(messages);
      chatProvider = provider;
    } on Object catch (caughtError) {
      if (!_disposed && requestVersion == _chatRequestVersion) {
        chatError = caughtError;
      }
    } finally {
      if (!_disposed && requestVersion == _chatRequestVersion) {
        isLoadingChat = false;
        notifyListeners();
      }
    }
  }

  void beginThreadDraft() {
    final Workspace? workspace = threadsWorkspace;
    if (workspace == null) return;
    selectedThread = null;
    pendingDraftTitle = null;
    pendingDraftToolsConfig = null;
    _setRememberedThread(workspace.uuid, null);
    chatSessionVersion++;
    _setChatScope(
      workspaceUuid: workspace.uuid,
      modelId: workspace.defaultModelId,
    );
    _markNavigationChanged();
    notifyListeners();
  }

  void updateThreadDraft({String? title, String? toolsConfig}) {
    if (selectedThread != null) return;
    final String? normalizedTitle = title?.trim();
    pendingDraftTitle = normalizedTitle == null || normalizedTitle.isEmpty
        ? null
        : normalizedTitle;
    pendingDraftToolsConfig = toolsConfig;
    notifyListeners();
  }

  Future<EngineLlmProvider> materializeThreadDraft(String firstMessage) async {
    final Workspace? workspace = threadsWorkspace;
    final RestEngineClient? client = repository?.rest;
    final EngineLlmProvider? draftProvider = chatProvider;
    if (workspace == null || client == null || draftProvider == null) {
      throw StateError('Choose a chat workspace before sending a message.');
    }
    if (selectedThread != null) return draftProvider;

    final String? draftTitle = pendingDraftTitle?.trim();
    final ThreadInfo created = await client
        .createThread(
          workspaceUuid: workspace.uuid,
          title: draftTitle == null || draftTitle.isEmpty
              ? _titleFromFirstMessage(firstMessage)
              : draftTitle,
          toolsConfig: pendingDraftToolsConfig,
        )
        .timeout(requestTimeout);
    if (_disposed ||
        selectedThread != null ||
        !identical(chatProvider, draftProvider) ||
        threadsWorkspace?.uuid != workspace.uuid) {
      throw StateError('The active draft changed while it was being created.');
    }

    threads = <ThreadInfo>[
      created,
      for (final ThreadInfo thread in threads)
        if (thread.uuid != created.uuid) thread,
    ];
    selectedThread = created;
    pendingDraftTitle = null;
    pendingDraftToolsConfig = null;
    _threadsWorkspaceUuid = workspace.uuid;
    _setRememberedThread(workspace.uuid, created.uuid);
    draftProvider.bindThread(created.uuid);
    _markNavigationChanged();
    notifyListeners();
    return draftProvider;
  }

  Future<void> createThread({String? title, String? toolsConfig}) async {
    final Workspace? workspace = threadsWorkspace;
    final RestEngineClient? client = repository?.rest;
    if (workspace == null || client == null) {
      throw StateError('Choose a chat workspace before creating a thread.');
    }
    final ThreadInfo created = await client
        .createThread(
          workspaceUuid: workspace.uuid,
          title: title,
          toolsConfig: toolsConfig,
        )
        .timeout(requestTimeout);
    threads = <ThreadInfo>[
      created,
      for (final ThreadInfo thread in threads)
        if (thread.uuid != created.uuid) thread,
    ];
    await selectThread(created);
  }

  static String _titleFromFirstMessage(String content) {
    final String normalized = content.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return 'New conversation';
    return normalized.length <= 60
        ? normalized
        : '${normalized.substring(0, 57)}…';
  }

  Future<void> updateThreadSettings({
    required ThreadInfo thread,
    String? title,
    String? toolsConfig,
    bool clearToolsConfig = false,
  }) async {
    final RestEngineClient client =
        repository?.rest ??
        (throw StateError('The Subconscious engine is not connected.'));
    final ThreadInfo updated = await client
        .updateThread(
          threadUuid: thread.uuid,
          title: title,
          toolsConfig: toolsConfig,
          clearToolsConfig: clearToolsConfig,
        )
        .timeout(requestTimeout);
    threads = threads
        .map((ThreadInfo item) => item.uuid == updated.uuid ? updated : item)
        .toList(growable: false);
    if (selectedThread?.uuid == updated.uuid) selectedThread = updated;
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
    required String? description,
    required String? defaultModelId,
    required String toolsConfig,
    required String directories,
    required String approvalConfig,
    required String ragConfig,
  }) async {
    final RestEngineClient client =
        repository?.rest ??
        (throw StateError('The Subconscious engine is not connected.'));
    final Workspace updated = await client
        .updateWorkspace(
          workspaceUuid: workspace.uuid,
          name: name,
          description: description,
          defaultModelId: defaultModelId,
          toolsConfig: toolsConfig,
          directories: directories,
          approvalConfig: approvalConfig,
          ragConfig: ragConfig,
        )
        .timeout(requestTimeout);
    workspaces = workspaces
        .map((Workspace item) => item.uuid == updated.uuid ? updated : item)
        .toList(growable: false);
    if (selectedWorkspace?.uuid == updated.uuid) selectedWorkspace = updated;
    if (activeWorkspace?.uuid == updated.uuid) activeWorkspace = updated;
    notifyListeners();
  }

  Future<void> deleteWorkspace(Workspace workspace) async {
    final RestEngineClient client =
        repository?.rest ??
        (throw StateError('The Subconscious engine is not connected.'));
    await client.deleteWorkspace(workspace.uuid).timeout(requestTimeout);
    _forgetWorkspace(workspace.uuid);

    final bool wasSelected = selectedWorkspace?.uuid == workspace.uuid;
    final bool wasThreadWorkspace = threadsWorkspace?.uuid == workspace.uuid;
    workspaces = workspaces
        .where((Workspace item) => item.uuid != workspace.uuid)
        .toList(growable: false);
    final Workspace? nextWorkspace = workspaces.firstOrNull;
    if (wasSelected) {
      if (nextWorkspace == null) settings.showUtility();
      await selectWorkspace(nextWorkspace);
    }
    if (wasThreadWorkspace) {
      await selectThreadWorkspace(nextWorkspace);
    }
    if (!wasSelected && !wasThreadWorkspace) notifyListeners();
  }

  List<WorkspaceFileEntry>? directoryEntries(int rootIndex, String path) =>
      _directoryEntries[_directoryKey(rootIndex, path)];

  bool isDirectoryLoading(int rootIndex, String path) =>
      _loadingDirectories.contains(_directoryKey(rootIndex, path));

  String fileTreeNodeKey(int rootIndex, String path) =>
      _directoryKey(rootIndex, path);

  void selectFileTreeNode(int rootIndex, String path) {
    selectedFileTreeNodeKey = _directoryKey(rootIndex, path);
    notifyListeners();
  }

  Future<void> loadDirectory(int rootIndex, String path) async {
    final Workspace? workspace = _filesWorkspace;
    final RestEngineClient? client = repository?.rest;
    final String key = _directoryKey(rootIndex, path);
    if (workspace == null ||
        client == null ||
        _loadingDirectories.contains(key)) {
      return;
    }
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
    filesError = null;
    notifyListeners();
    await Future.wait(<Future<void>>[
      for (final WorkspaceDirectoryRoot root in fileRoots)
        loadDirectory(root.index, ''),
    ]);
  }

  Future<OpenWorkspaceFile?> readWorkspaceFile(
    int rootIndex,
    String path,
  ) async {
    final Workspace? workspace = _filesWorkspace;
    final RestEngineClient? client = repository?.rest;
    if (workspace == null || client == null) return null;
    if (OpenWorkspaceFile.supportsPreview(path)) {
      final WorkspaceFilePreview preview = await client
          .previewFile(
            workspaceUuid: workspace.uuid,
            rootIndex: rootIndex,
            path: path,
          )
          .timeout(requestTimeout);
      return OpenWorkspaceFile(
        rootIndex: rootIndex,
        path: path,
        content: '',
        previewBytes: preview.bytes,
        previewKind: preview.kind,
        mediaType: preview.mediaType,
      );
    }
    final WorkspaceFileContent result = await client
        .readFile(
          workspaceUuid: workspace.uuid,
          rootIndex: rootIndex,
          path: path,
        )
        .timeout(requestTimeout);
    return OpenWorkspaceFile(
      rootIndex: rootIndex,
      path: path,
      content: result.content,
    );
  }

  Future<bool> openWorkspaceFile(
    int rootIndex,
    String path, {
    bool remember = true,
  }) async {
    final Workspace? workspace = _filesWorkspace;
    if (workspace == null || repository?.rest == null) return false;
    final int requestVersion = ++_fileRequestVersion;
    selectedFileTreeNodeKey = _directoryKey(rootIndex, path);
    isLoadingFile = true;
    filesError = null;
    notifyListeners();
    bool opened = false;
    try {
      final OpenWorkspaceFile? openedFile = await readWorkspaceFile(
        rootIndex,
        path,
      );
      if (openedFile != null && requestVersion == _fileRequestVersion) {
        openFile = openedFile;
        opened = true;
        if (remember) {
          _filesWorkspaceUuid = workspace.uuid;
          _filesRootIndex = rootIndex;
          _filesPath = path;
          _markNavigationChanged();
        }
      }
    } on Object catch (caughtError) {
      if (requestVersion == _fileRequestVersion) filesError = caughtError;
    } finally {
      if (requestVersion == _fileRequestVersion) {
        isLoadingFile = false;
        notifyListeners();
      }
    }
    return opened;
  }

  Future<void> saveOpenFile(String content) async {
    final Workspace? workspace = _filesWorkspace;
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

  void activateOpenFile(OpenWorkspaceFile file) {
    openFile = file;
    selectedFileTreeNodeKey = _directoryKey(file.rootIndex, file.path);
    _filesWorkspaceUuid = _filesWorkspace?.uuid;
    _filesRootIndex = file.rootIndex;
    _filesPath = file.path;
    _markNavigationChanged();
    notifyListeners();
  }

  void closeOpenFile() {
    openFile = null;
    selectedFileTreeNodeKey = null;
    _filesRootIndex = null;
    _filesPath = null;
    _markNavigationChanged();
    notifyListeners();
  }

  Future<void> createFile({
    required int rootIndex,
    required String path,
  }) async {
    final Workspace? workspace = _filesWorkspace;
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
    final Workspace? workspace = _filesWorkspace;
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

  _WorkspaceViewerState? get _currentViewerState {
    final String? workspaceUuid = selectedWorkspace?.uuid;
    return workspaceUuid == null ? null : _workspaceViewerStates[workspaceUuid];
  }

  Workspace? _workspaceByUuid(String? uuid) {
    if (uuid == null) return null;
    for (final Workspace workspace in workspaces) {
      if (workspace.uuid == uuid) return workspace;
    }
    return null;
  }

  ThreadInfo? _threadByUuid(String? uuid) {
    if (uuid == null) return null;
    for (final ThreadInfo thread in threads) {
      if (thread.uuid == uuid) return thread;
    }
    return null;
  }

  void _setRememberedThread(String workspaceUuid, String? threadUuid) {
    if (threadUuid == null) {
      _threadUuidsByWorkspace.remove(workspaceUuid);
    } else {
      _threadUuidsByWorkspace[workspaceUuid] = threadUuid;
    }
    if (_threadsWorkspaceUuid == workspaceUuid) {
      _threadsThreadUuid = threadUuid;
    }
  }

  void _forgetWorkspace(String workspaceUuid) {
    bool changed = _workspaceViewerStates.remove(workspaceUuid) != null;
    if (_threadUuidsByWorkspace.remove(workspaceUuid) != null) changed = true;
    if (_workspacesWorkspaceUuid == workspaceUuid) {
      _workspacesWorkspaceUuid = null;
      changed = true;
    }
    if (_threadsWorkspaceUuid == workspaceUuid) {
      _threadsWorkspaceUuid = null;
      _threadsThreadUuid = null;
      changed = true;
    }
    if (_filesWorkspaceUuid == workspaceUuid) {
      _filesWorkspaceUuid = null;
      _filesRootIndex = null;
      _filesPath = null;
      changed = true;
    }
    if (changed) _markNavigationChanged();
  }

  static Map<String, dynamic> _objectValue(Object? value) => value is Map
      ? value.map((Object? key, Object? item) => MapEntry('$key', item))
      : <String, dynamic>{};

  static String? _stringValue(Object? value) => value is String ? value : null;

  static int? _nonNegativeIntValue(Object? value) {
    if (value is int) return value >= 0 ? value : null;
    if (value is num && value.isFinite && value == value.truncateToDouble()) {
      final int converted = value.toInt();
      return converted >= 0 ? converted : null;
    }
    return null;
  }

  static bool? _boolValue(Object? value) => value is bool ? value : null;

  static double? _doubleValue(Object? value) {
    if (value is! num) return null;
    final double converted = value.toDouble();
    return converted.isFinite ? converted : null;
  }

  static double? _positiveDoubleValue(Object? value) {
    final double? converted = _doubleValue(value);
    return converted != null && converted > 0 ? converted : null;
  }

  static bool _isFinite(double? value) => value != null && value.isFinite;

  static bool _isPositiveFinite(double? value) =>
      value != null && value.isFinite && value > 0;

  static T? _enumValue<T extends Enum>(List<T> values, Object? value) {
    if (value is! String) return null;
    for (final T candidate in values) {
      if (candidate.name == value) return candidate;
    }
    return null;
  }

  void _setChatScope({
    String? workspaceUuid,
    String? threadUuid,
    String? modelId,
  }) {
    _chatRequestVersion++;
    chatProvider?.dispose();
    chatError = null;
    isLoadingChat = false;
    final EngineRepository? currentRepository = repository;
    chatProvider =
        currentRepository == null ||
            (workspaceUuid == null && threadUuid == null)
        ? null
        : EngineLlmProvider(
            repository: currentRepository,
            workspaceUuid: workspaceUuid,
            threadUuid: threadUuid,
            modelId: modelId,
          );
  }

  void _clearFiles() {
    _directoryEntries.clear();
    _loadingDirectories.clear();
    openFile = null;
    selectedFileTreeNodeKey = null;
    filesError = null;
    _fileRequestVersion++;
  }

  String _directoryKey(int rootIndex, String path) =>
      '$rootIndex:${path.replaceAll('\\', '/')}';

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _appStateSaveTimer?.cancel();
    chatProvider?.dispose();
    settings.dispose();
    unawaited(repository?.socket.dispose());
    unawaited(repository?.rest.close());
    super.dispose();
  }
}
