import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleListener, AppLifecycleState;
import 'package:url_launcher/url_launcher.dart';

import '../../chat/engine_llm_provider.dart';
import '../../editor/controller/editor_document_store.dart';
import '../../editor/controller/editor_tab.dart';
import '../../editor/controller/file_gateway.dart';
import '../../editor/controller/workspace_paths.dart';
import '../../editor/data/engine_draft_store.dart';
import '../../extension/extension_host.dart';
import '../../hive/executor_selection.dart';
import '../../settings/controller/settings_controller.dart';

enum EngineConnectionStatus { disconnected, connecting, connected }

enum DashboardSection { workspaces, threads, files, settings }

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

final class WorkspaceFileTreeNode {
  const WorkspaceFileTreeNode({
    required this.rootIndex,
    required this.path,
    required this.isDirectory,
  });

  final int rootIndex;
  final String path;
  final bool isDirectory;
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
    this.executors,
    this.engineStartup,
    this.oauthLauncher = _launchExternally,
    ExtensionHost? extensionHost,
  }) : _explicitEndpoint = initialEndpoint,
       _explicitToken = initialToken,
       _extensionHost = extensionHost ?? ExtensionHost.instance {
    if (_extensionHost.isExtension) {
      // The host watches the page for WebMCP tools only while the panel is
      // shown.
      _extensionHost.setVisible(true);
      _visibilityListener = AppLifecycleListener(
        onStateChange: (AppLifecycleState state) => _extensionHost.setVisible(
          state == AppLifecycleState.resumed ||
              state == AppLifecycleState.inactive,
        ),
      );
    }
    settings = DashboardSettingsController(
      repositoryProvider: () => repository,
      urlLauncher: oauthLauncher,
    );
    documents =
        EditorDocumentStore(
            gateway: _EngineFileGateway(this),
            drafts: EngineDraftStore(
              clientProvider: () => repository?.rest,
              clientName: DashboardSettingsController.settingsClient,
            ),
          )
          ..onTabsChanged = _onEditorTabsChanged
          ..onActiveChanged = _onEditorActiveChanged;
  }

  final ExtensionHost _extensionHost;

  static const Duration reconnectInterval = Duration(seconds: 3);
  static const Duration requestTimeout = Duration(seconds: 5);

  /// Setting up a new engine session (discovery plus, for a remote engine, a
  /// WebRTC handshake) legitimately takes longer than one request. A shorter
  /// limit abandons a link that is about to come up, leaving the device list
  /// saying "Connected" while the session is down.
  static const Duration resolveTimeout = Duration(seconds: 30);

  /// Called when the local engine is quit from its tray and asks this client
  /// to close with it.
  VoidCallback? onEngineQuit;

  /// Called when a connection attempt fails, even if the visible status did
  /// not change, so a link that was set up for it can be abandoned.
  VoidCallback? onConnectionAttemptFailed;
  static const Duration healthProbeInterval = Duration(seconds: 30);
  DateTime? _lastHealthProbe;
  static const Duration appStateSaveDebounce = Duration(milliseconds: 300);
  static const String appStateKey = 'dashboard_state_v2';
  static const String navigationKey = 'dashboard_navigation_v1';
  static const String navigationTag = 'navigation';

  final EngineRepositoryResolver _repositoryResolver;

  /// Opens a sign-in page outside the app; returns whether it was opened.
  final Future<bool> Function(Uri uri) oauthLauncher;

  static Future<bool> _launchExternally(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  /// Starts the local engine before the first connection attempt (production
  /// desktop only); null leaves starting the engine to the user.
  final Future<void> Function()? engineStartup;

  /// Why the engine could not be started, shown until a connection succeeds.
  Object? _engineStartupError;

  /// Executor choices for the composer picker (the hive runtime in the app);
  /// null hides the picker.
  final ExecutorDirectory? executors;
  final String? initialWorkspaceUuid;
  late final DashboardSettingsController settings;

  /// Every open editor tab, the unsaved text in them, and the rules that keep
  /// that text safe. It outlives the editor widget, so edits survive leaving
  /// the Files view, switching workspaces and restarting the app.
  late final EditorDocumentStore documents;
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

  /// Last messages loaded per thread, shown while the engine is away.
  final Map<String, List<ChatMessage>> _messageCache =
      <String, List<ChatMessage>>{};

  /// Providers whose turn is still running after the user opened another
  /// thread. They keep working in the background and are reused when the user
  /// returns to the thread.
  final Map<String, EngineLlmProvider> _runningProviders =
      <String, EngineLlmProvider>{};

  /// Releases [provider] unless it is mid-turn, in which case it keeps
  /// running and is disposed once the turn ends and nobody is viewing it.
  void _retireProvider(EngineLlmProvider? provider) {
    if (provider == null) return;
    final String? thread = provider.threadUuid;
    if (!provider.isBusy || thread == null) {
      if (thread != null && identical(_runningProviders[thread], provider)) {
        _runningProviders.remove(thread);
      }
      provider.dispose();
      return;
    }
    _runningProviders[thread] = provider;
    if (_releaseListeners.containsKey(provider)) return;
    void release() {
      if (provider.isBusy) return;
      provider.removeListener(release);
      _releaseListeners.remove(provider);
      // Only providers nobody is viewing are disposed; the viewed one is
      // disposed when the user leaves it.
      if (identical(_runningProviders[thread], provider)) {
        _runningProviders.remove(thread);
        // Not inside notifyListeners: disposing there asserts.
        scheduleMicrotask(provider.dispose);
      }
    }

    _releaseListeners[provider] = release;
    provider.addListener(release);
  }

  final Map<EngineLlmProvider, VoidCallback> _releaseListeners =
      <EngineLlmProvider, VoidCallback>{};
  EngineConnectionStatus connectionStatus = EngineConnectionStatus.connecting;
  DashboardSection selectedSection = DashboardSection.threads;
  bool accountShortcutSelected = false;
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

  /// Stand-in for [chatProvider] while no thread is loaded (or it failed to
  /// load), so the chat panel and its disabled composer are always shown.
  final EngineLlmProvider fallbackChatProvider = EngineLlmProvider();
  Object? filesError;
  Object? navigationError;
  ToolApprovalRequest? pendingToolApproval;
  final List<ToolApprovalRequest> _toolApprovalQueue = <ToolApprovalRequest>[];
  final Map<String, int> _approvedUiToolActions = <String, int>{};

  /// Head of the queue of tool sign-ins waiting on the user.
  OAuthAuthorization? pendingOAuth;
  final List<OAuthAuthorization> _oauthQueue = <OAuthAuthorization>[];
  final Map<String, Timer> _oauthExpiryTimers = <String, Timer>{};

  /// Why the sign-in card could not proceed (browser, paste or cancel failed).
  Object? oauthError;
  bool isSubmittingOAuth = false;
  bool isLoadingWorkspaces = false;
  bool isLoadingThreads = false;
  bool isLoadingChat = false;
  bool isCreatingWorkspace = false;
  bool hasLoadedNavigationState = false;
  String? selectedFileTreeNodeKey;
  WorkspaceFileTreeNode? selectedFileTreeNode;
  bool isMovingWorkspaceNode = false;

  bool chatPanelVisible = true;
  bool mainPanelVisible = true;
  bool contextPanelVisible = true;

  /// True while the window shows only the chat, small and above other windows
  /// (for asking the assistant to drive something else). Not saved: the layout
  /// before it is what a restart restores.
  bool chatOnly = false;
  ({bool chat, bool main, bool context})? _layoutBeforeChatOnly;

  /// Resizes the window and pins it on top; set by the desktop window bar. Null
  /// where the app has no window of its own (mobile, web).
  Future<void> Function(bool enabled)? chatOnlyWindowHandler;

  bool get supportsChatOnly => chatOnlyWindowHandler != null;

  Future<void> setChatOnly(bool enabled) async {
    final Future<void> Function(bool)? handler = chatOnlyWindowHandler;
    if (handler == null || chatOnly == enabled) return;
    if (enabled) {
      _layoutBeforeChatOnly = (
        chat: chatPanelVisible,
        main: mainPanelVisible,
        context: contextPanelVisible,
      );
      chatOnly = true;
      chatPanelVisible = true;
      mainPanelVisible = false;
      contextPanelVisible = false;
    } else {
      final ({bool chat, bool main, bool context})? before =
          _layoutBeforeChatOnly;
      _layoutBeforeChatOnly = null;
      chatOnly = false;
      if (before != null) {
        chatPanelVisible = before.chat;
        mainPanelVisible = before.main;
        contextPanelVisible = before.context;
      }
    }
    notifyListeners();
    try {
      await handler(enabled);
    } on Object catch (error) {
      debugPrint('Could not change the chat-only window: $error');
    }
  }

  double chatPanelWidth = 280;
  double contextPanelWidth = 280;
  double? windowX;
  double? windowY;
  double? windowWidth;
  double? windowHeight;
  bool windowMaximized = false;

  /// Position and size of the chat-only window, kept apart from the normal
  /// window above so resizing one never moves the other.
  double? chatWindowX;
  double? chatWindowY;
  double? chatWindowWidth;
  double? chatWindowHeight;

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
  StreamSubscription<WireFrame>? _engineEventSubscription;
  EngineRepository? _engineEventRepository;
  bool _connectionCheckInProgress = false;
  bool _tokenRejected = false;
  bool _isRestoringNavigation = false;
  Future<void>? _appStateWriteFuture;
  bool _disposed = false;
  int _threadRequestVersion = 0;
  int _chatRequestVersion = 0;
  int _sectionActivationVersion = 0;
  int _engineEventVersion = 0;
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

  bool get hasChatWindowBounds =>
      _isFinite(chatWindowX) &&
      _isFinite(chatWindowY) &&
      _isPositiveFinite(chatWindowWidth) &&
      _isPositiveFinite(chatWindowHeight);

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

  /// Remembers where the chat-only window sits (see [chatWindowX]).
  void updateChatWindowState({
    required double x,
    required double y,
    required double width,
    required double height,
  }) {
    if (!_isFinite(x) ||
        !_isFinite(y) ||
        !_isPositiveFinite(width) ||
        !_isPositiveFinite(height)) {
      return;
    }
    if (x == chatWindowX &&
        y == chatWindowY &&
        width == chatWindowWidth &&
        height == chatWindowHeight) {
      return;
    }
    chatWindowX = x;
    chatWindowY = y;
    chatWindowWidth = width;
    chatWindowHeight = height;
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
    accountShortcutSelected = false;
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
      final bool matchesActiveWorkspace =
          _filesWorkspaceUuid == activeWorkspace?.uuid;
      final int? rootIndex = matchesActiveWorkspace ? _filesRootIndex : null;
      final String? path = matchesActiveWorkspace ? _filesPath : null;
      if (rootIndex != null && path != null && documents.active == null) {
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
    accountShortcutSelected = false;
    settings.openSettingsPage(page);
    _markNavigationChanged();
    notifyListeners();
  }

  void openAccountShortcut() {
    selectedSection = DashboardSection.settings;
    accountShortcutSelected = true;
    settings.openSettingsPage(SettingsPage.account);
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

  /// When a failed read of the saved state may be tried again, so a broken
  /// settings route is not hit on every connection check.
  DateTime? _navigationRetryAt;
  static const Duration navigationRetryInterval = Duration(seconds: 15);

  bool get _navigationRetryDue {
    final DateTime? at = _navigationRetryAt;
    return at == null || !DateTime.now().isBefore(at);
  }

  Future<void> _loadNavigationState() async {
    if (hasLoadedNavigationState) return;
    final RestEngineClient? client = repository?.rest;
    if (client == null) return;
    bool migratedLegacyState = false;
    bool loadedSuccessfully = false;
    try {
      final List<EngineSetting> loaded = await client
          .getSettings(key: appStateKey)
          .timeout(requestTimeout);
      _isRestoringNavigation = true;
      if (loaded.isEmpty) {
        migratedLegacyState = await _loadLegacyNavigationState(client);
      } else {
        _restoreAppState(loaded.last.value);
      }
      navigationError = null;
      loadedSuccessfully = true;
    } on Object catch (caughtError) {
      navigationError = caughtError;
      _navigationRetryAt = DateTime.now().add(navigationRetryInterval);
    } finally {
      _isRestoringNavigation = false;
      // A failed read (the engine was still starting, a timeout) must not
      // count as "loaded": the saved layout, open files and last thread would
      // then be overwritten by the next change. The next connection check
      // tries again, and nothing is written until a read has succeeded.
      if (loadedSuccessfully) hasLoadedNavigationState = true;
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

    final Map<String, dynamic> chatWindow = _objectValue(root['chatWindow']);
    chatWindowX = _doubleValue(chatWindow['x']);
    chatWindowY = _doubleValue(chatWindow['y']);
    chatWindowWidth = _positiveDoubleValue(chatWindow['width']);
    chatWindowHeight = _positiveDoubleValue(chatWindow['height']);
  }

  void _restoreNavigation(Map<String, dynamic> root) {
    final bool legacyAccountSection = root['activeSection'] == 'account';
    selectedSection = legacyAccountSection
        ? DashboardSection.settings
        : _enumValue(DashboardSection.values, root['activeSection']) ??
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
    settings.activePage = legacyAccountSection
        ? SettingsPage.account
        : _enumValue(SettingsPage.values, settingsState['page']) ??
              SettingsPage.general;
    final String? savedSidebarSelection = _stringValue(
      root['sidebarSelection'],
    );
    accountShortcutSelected =
        legacyAccountSection ||
        savedSidebarSelection == 'account' ||
        (savedSidebarSelection == null &&
            selectedSection == DashboardSection.settings &&
            settings.activePage == SettingsPage.account);
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
    'sidebarSelection': accountShortcutSelected
        ? 'account'
        : selectedSection.name,
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
      'chatPanelVisible': _layoutBeforeChatOnly?.chat ?? chatPanelVisible,
      'mainPanelVisible': _layoutBeforeChatOnly?.main ?? mainPanelVisible,
      'contextPanelVisible':
          _layoutBeforeChatOnly?.context ?? contextPanelVisible,
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
    if (hasChatWindowBounds)
      'chatWindow': <String, dynamic>{
        'x': chatWindowX,
        'y': chatWindowY,
        'width': chatWindowWidth,
        'height': chatWindowHeight,
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
    // Never write before the saved state has been read, or a fresh default
    // layout replaces it.
    if (client == null || !hasLoadedNavigationState) return;
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

  AppLifecycleListener? _resumeListener;

  /// A phone that slept comes back with a connection that looks alive and is
  /// not. Check it as soon as the app is shown again, and rebuild it if dead.
  void _onAppResumed() {
    if (_disposed) return;
    final EngineRepository? current = _repository;
    if (current == null || !isConnected) {
      unawaited(_checkConnection());
      return;
    }
    unawaited(_verifyConnectionAfterResume(current));
  }

  Future<void> _verifyConnectionAfterResume(EngineRepository current) async {
    try {
      await current.rest.health().timeout(const Duration(seconds: 5));
      _lastHealthProbe = DateTime.now();
      if (!current.socket.isConnected) await _checkConnection();
    } on Object {
      if (_disposed || !identical(_repository, current)) return;
      onConnectionAttemptFailed?.call();
      await reconnectNow();
    }
  }

  Future<void> load() async {
    _resumeListener ??= AppLifecycleListener(onResume: _onAppResumed);
    documents.observeAppLifecycle();
    _reconnectTimer ??= Timer.periodic(
      reconnectInterval,
      (_) => unawaited(_checkConnection()),
    );
    // Startup runs at most once per session; only retryEngineStart repeats it.
    if (!_engineStartAttempted) await _runEngineStartup();
    if (_disposed) return;
    await _checkConnection();
  }

  bool _engineStartAttempted = false;

  Future<void> _runEngineStartup() async {
    final Future<void> Function()? startEngine = engineStartup;
    if (startEngine == null) return;
    _engineStartAttempted = true;
    _engineStartupError = null;
    try {
      await startEngine();
    } on Object catch (caughtError) {
      _engineStartupError = caughtError;
    }
  }

  /// User-initiated retry: starts the engine once more, then reconnects.
  Future<void> retryEngineStart() async {
    _engineStartAttempted = false;
    await _runEngineStartup();
    if (_disposed) return;
    await reconnectNow();
  }

  Future<void> reconnectNow() => _checkConnection(forceConnectingState: true);

  /// Updates the connection state and notifies only when it actually changed,
  /// so background retries while the engine is away do not rebuild the UI.
  void _setConnection(EngineConnectionStatus status, {Object? failure}) {
    final bool changed =
        connectionStatus != status ||
        (error == null) != (failure == null) ||
        error.toString() != failure.toString();
    connectionStatus = status;
    error = failure;
    if (changed) notifyListeners();
  }

  Future<void> _checkConnection({bool forceConnectingState = false}) async {
    if (_connectionCheckInProgress || _disposed) return;
    // A rejected token is only re-probed on an explicit Retry.
    if (forceConnectingState) {
      _tokenRejected = false;
    } else if (_tokenRejected) {
      return;
    }
    _connectionCheckInProgress = true;
    final EngineRepository? currentRepository = _repository;
    final bool canReuseCurrent =
        !forceConnectingState && currentRepository != null && isConnected;
    // Background ticks keep "disconnected" (or the initial "connecting") as is;
    // only an explicit retry or a dropped live connection shows "connecting".
    if (forceConnectingState ||
        (isConnected &&
            (!canReuseCurrent || !currentRepository.socket.isConnected))) {
      _setConnection(EngineConnectionStatus.connecting, failure: error);
    }

    try {
      if (canReuseCurrent) {
        try {
          // While the websocket is up it is the liveness signal; the REST
          // health probe only runs as an occasional cross-check.
          final DateTime now = DateTime.now();
          final DateTime? lastProbe = _lastHealthProbe;
          if (!currentRepository.socket.isConnected ||
              lastProbe == null ||
              now.difference(lastProbe) >= healthProbeInterval) {
            await currentRepository.rest.health().timeout(requestTimeout);
            _lastHealthProbe = now;
          }
          if (!currentRepository.socket.isConnected) {
            await currentRepository.connect().timeout(requestTimeout);
          }
          await _listenToEngineEvents(currentRepository);
          _engineStartupError = null;
          _setConnection(EngineConnectionStatus.connected);
          // A failed load is not retried on every tick; Retry reloads it.
          if (!settings.hasLoadedGeneralSettings &&
              settings.generalError == null) {
            await settings.loadGeneralSettings(silent: true);
          }
          if (!hasLoadedNavigationState && _navigationRetryDue) {
            await _loadNavigationState();
          }
          if (workspaces.isEmpty) {
            await loadWorkspaces();
          }
          _schedulePendingNavigationSave();
          return;
        } on Object {
          await _closeRepository(currentRepository);
          // The session is dead; a peer link under it may be too, and would
          // otherwise be reused by the reconnect below.
          onConnectionAttemptFailed?.call();
        }
      } else if (currentRepository != null) {
        await _closeRepository(currentRepository);
      }

      final EngineRepository? discoveredRepository = await _repositoryResolver(
        explicitEndpoint: _explicitEndpoint,
        explicitToken: _explicitToken,
      ).timeout(resolveTimeout);
      if (discoveredRepository == null) {
        throw StateError(
          'No reachable Subconscious engine was discovered. Start the engine or configure an explicit endpoint.',
        );
      }
      _repository = discoveredRepository;
      await discoveredRepository.rest.health().timeout(resolveTimeout);
      _lastHealthProbe = DateTime.now();
      await discoveredRepository.connect().timeout(resolveTimeout);
      await _listenToEngineEvents(discoveredRepository);
      chatProvider?.replaceRepository(discoveredRepository);
      for (final EngineLlmProvider provider in _runningProviders.values) {
        provider.replaceRepository(discoveredRepository);
      }
      await settings.loadGeneralSettings(
        force: true,
        silent: !forceConnectingState,
      );
      final Object? settingsFailure = settings.generalError;
      if (settingsFailure is EngineApiException &&
          settingsFailure.statusCode == 401) {
        _tokenRejected = true;
        throw StateError(
          'The engine on port ${settingsFailure.uri.port} rejected this '
          "app's token. Another Subconscious engine may be running; close "
          'it and press Retry.',
        );
      }
      await _loadNavigationState();
      _engineStartupError = null;
      _setConnection(EngineConnectionStatus.connected);
      await loadWorkspaces();
      // Tabs that could not be read while the engine was away come back now,
      // and files edited in the meantime are compared with the disk.
      final ThreadInfo? openThread = selectedThread;
      if (openThread != null) {
        // The thread was opened while offline: load the live history now.
        unawaited(_refreshSelectedThreadHistory(openThread.uuid));
      }
      unawaited(documents.retryRestore());
      unawaited(documents.checkExternalChanges());
      _schedulePendingNavigationSave();
    } on Object catch (caughtError) {
      final EngineRepository? failedRepository = _repository;
      if (failedRepository != null) await _closeRepository(failedRepository);
      _setConnection(
        EngineConnectionStatus.disconnected,
        failure: _engineStartupError ?? caughtError,
      );
      onConnectionAttemptFailed?.call();
    } finally {
      _connectionCheckInProgress = false;
    }
  }

  Future<void> _listenToEngineEvents(EngineRepository eventRepository) async {
    if (identical(_engineEventRepository, eventRepository) &&
        _engineEventSubscription != null) {
      // Already registered when this socket was first subscribed; the socket
      // has no internal reconnect (a new socket means a new repository), so
      // re-sending tool.register on every connection check was pure spam.
      return;
    }
    await _engineEventSubscription?.cancel();
    if (_disposed) return;
    pendingToolApproval = null;
    _toolApprovalQueue.clear();
    _approvedUiToolActions.clear();
    _clearOAuth();
    _engineEventRepository = eventRepository;
    _watchedThread = null;
    _engineEventSubscription = eventRepository.socket.frames.listen(
      _handleEngineEvent,
      onError: (_) {},
    );
    eventRepository.socket.registerUiTools();
    _startExtensionTools(eventRepository.socket);
    final ThreadInfo? openThread = selectedThread;
    if (openThread != null) _watchThread(eventRepository, openThread.uuid);
    unawaited(_recoverPendingOAuth(eventRepository));
  }

  /// Tool ids of every group the browser extension registered on the current
  /// socket (empty outside the extension).
  final Map<String, Set<String>> _extensionTools = <String, Set<String>>{};
  void Function()? _unsubscribeExtensionTools;
  AppLifecycleListener? _visibilityListener;

  /// Registers the extension's tool groups on [socket] and keeps them in sync
  /// while the host reports changes (for example WebMCP tools of a new page).
  void _startExtensionTools(EngineSocket socket) {
    _unsubscribeExtensionTools?.call();
    _unsubscribeExtensionTools = null;
    _extensionTools.clear();
    if (!_extensionHost.isExtension) return;
    _syncExtensionTools(socket, _extensionHost.toolGroups());
    _unsubscribeExtensionTools = _extensionHost.onToolGroupsChanged((
      List<ClientToolGroup> groups,
    ) {
      final EngineSocket? current = _engineEventRepository?.socket;
      if (_disposed || current == null || !identical(current, socket)) return;
      _syncExtensionTools(current, groups);
    });
  }

  /// Sends one `tool.register` per group; a group that disappeared is sent
  /// with no tools so the engine forgets it.
  void _syncExtensionTools(EngineSocket socket, List<ClientToolGroup> groups) {
    final List<ClientToolGroup> present = <ClientToolGroup>[
      for (final ClientToolGroup group in groups)
        if (!group.isEmpty) group,
    ];
    final Map<String, Set<String>> next = <String, Set<String>>{
      for (final ClientToolGroup group in present)
        group.group: <String>{
          for (final ClientToolDefinition tool in group.tools) tool.id,
        },
    };
    final List<ClientToolGroup> toSend = <ClientToolGroup>[
      ...present,
      for (final String removed in _extensionTools.keys)
        if (!next.containsKey(removed))
          ClientToolGroup(
            group: removed,
            title: removed,
            tools: const <ClientToolDefinition>[],
          ),
    ];
    _extensionTools
      ..clear()
      ..addAll(next);
    if (toSend.isEmpty) return;
    try {
      socket.registerClientTools(toSend);
    } on Object catch (error) {
      debugPrint('Could not register the extension tools: $error');
    }
  }

  /// Runs a tool of an extension group and answers the engine.
  Future<void> _handleExtensionToolRequest(
    EngineSocket socket,
    String turnId,
    String requestId,
    String group,
    String? toolName,
    Object? rawArguments,
  ) async {
    void fail(String message) => socket.sendClientToolResult(
      turnId: turnId,
      requestId: requestId,
      ok: false,
      error: message,
    );
    final Set<String>? tools = _extensionTools[group];
    if (!_extensionHost.isExtension || tools == null) {
      fail('The tool group "$group" is not available.');
      return;
    }
    if (toolName == null || !tools.contains(toolName)) {
      fail('The tool "$toolName" is not available in "$group".');
      return;
    }
    if (rawArguments != null && rawArguments is! Map) {
      fail('The tool arguments are malformed.');
      return;
    }
    try {
      final ExtensionToolResult outcome = await _extensionHost.callTool(
        group,
        toolName,
        jsonEncode(rawArguments ?? const <String, dynamic>{}),
      );
      if (outcome.ok) {
        socket.sendClientToolResult(
          turnId: turnId,
          requestId: requestId,
          ok: true,
          result: outcome.result,
        );
      } else {
        fail(outcome.error ?? 'The browser tool failed.');
      }
    } on Object catch (caughtError) {
      fail('$caughtError');
    }
  }

  void _handleEngineEvent(WireFrame frame) {
    if (_disposed) return;
    final Map<String, dynamic> data = frame.data ?? <String, dynamic>{};
    switch (frame.type) {
      case 'tool.approval.request':
        _enqueueToolApproval(frame, data);
        return;
      case 'tool.approval.resolved':
        // Another UI answered; dismiss the prompt here.
        final Object? resolved = data['approval_id'];
        if (resolved is String) _dismissToolApproval(resolved);
        return;
      case 'oauth.request':
        if (parseTaskEvent(frame) case OAuthRequested(:final authorization)) {
          _enqueueOAuth(authorization);
        } else {
          debugPrint('Ignored a malformed oauth.request frame.');
        }
        return;
      case 'oauth.resolved':
        if (parseTaskEvent(frame) case OAuthResolved(
          :final authId,
          :final status,
        )) {
          _dismissOAuth(authId);
          if (status == OAuthStatus.authorized) {
            unawaited(settings.refreshTools());
          }
        } else {
          debugPrint('Ignored a malformed oauth.resolved frame.');
        }
        return;
      case 'task.status':
        final Object? taskThread = data['thread_uuid'];
        final Object? taskStatus = data['status'];
        if (taskThread is String &&
            selectedThread?.uuid == taskThread &&
            TaskStatus.parse(taskStatus).isTerminal) {
          unawaited(_refreshSelectedThreadHistory(taskThread));
        }
        return;
      case 'engine.shutdown':
        onEngineQuit?.call();
        return;
      case 'client.tool.request':
        unawaited(_handleClientToolRequest(frame, data));
        return;
      case 'chat.done':
      case 'chat.error':
      case 'chat.cancelled':
        if (frame.id case final String turnId) {
          _approvedUiToolActions.removeWhere(
            (String key, int _) => key.startsWith('$turnId\u0000'),
          );
        }
        return;
      case 'message.created':
        final Object? threadId = data['threadId'];
        if (threadId is String && selectedThread?.uuid == threadId) {
          unawaited(_refreshSelectedThreadHistory(threadId));
        }
        return;
      case 'thread.created':
        final Object? workspaceId = data['workspaceId'];
        if (workspaceId is String && activeWorkspace?.uuid == workspaceId) {
          unawaited(_refreshThreadsForActiveWorkspace(workspaceId));
        }
        return;
    }
  }

  void _enqueueToolApproval(WireFrame frame, Map<String, dynamic> data) {
    final String? turnId = frame.id;
    final Object? rawArguments = data['arguments'];
    // A hive peer's request for one of our exported tools has no thread.
    final bool remote = data['remote'] == true;
    if (turnId == null ||
        data['approval_id'] is! String ||
        (data['thread_uuid'] is! String && !remote) ||
        data['tool_name'] is! String ||
        rawArguments is! Map) {
      return;
    }
    final ToolApprovalRequest request = ToolApprovalRequest(
      turnId: turnId,
      approvalId: data['approval_id']! as String,
      threadUuid: data['thread_uuid'] is String
          ? data['thread_uuid']! as String
          : '',
      toolName: data['tool_name']! as String,
      arguments: rawArguments.cast<String, dynamic>(),
      operation: data['operation'] is String
          ? data['operation']! as String
          : 'update',
      remote: remote,
      peerName: data['peer_name'] is String
          ? data['peer_name']! as String
          : null,
      peerNodeId: data['peer_node_id'] is String
          ? data['peer_node_id']! as String
          : null,
    );
    if (pendingToolApproval?.approvalId == request.approvalId ||
        _toolApprovalQueue.any(
          (ToolApprovalRequest item) => item.approvalId == request.approvalId,
        )) {
      return;
    }
    if (pendingToolApproval == null) {
      pendingToolApproval = request;
    } else {
      _toolApprovalQueue.add(request);
    }
    // Surface consent even when the chat panel is hidden. The selected section
    // is left alone so a background thread never pulls the user away from the
    // panel they are using; the mobile view reveals the chat by itself while an
    // approval is pending.
    chatPanelVisible = true;
    notifyListeners();
  }

  String? _watchedThread;

  /// `thread.subscribe` for live updates of tasks started elsewhere (a thin
  /// client sees deltas and status of work running on other nodes).
  void _watchThread(EngineRepository current, String threadUuid) {
    if (_watchedThread == threadUuid) return;
    try {
      final String? previous = _watchedThread;
      if (previous != null) current.socket.unsubscribeThread(previous);
      current.socket.subscribeThread(threadUuid);
      _watchedThread = threadUuid;
    } on Object {
      // Older engines or a closed socket: updates arrive after a refresh.
      _watchedThread = null;
    }
  }

  void _dismissToolApproval(String approvalId) {
    final int before = _toolApprovalQueue.length;
    _toolApprovalQueue.removeWhere(
      (ToolApprovalRequest item) => item.approvalId == approvalId,
    );
    bool changed = _toolApprovalQueue.length != before;
    if (pendingToolApproval?.approvalId == approvalId) {
      pendingToolApproval = _toolApprovalQueue.isEmpty
          ? null
          : _toolApprovalQueue.removeAt(0);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  Future<void> respondToToolApproval(bool approved) async {
    final ToolApprovalRequest? request = pendingToolApproval;
    final EngineSocket? socket = repository?.socket;
    if (request == null || socket == null) return;
    pendingToolApproval = _toolApprovalQueue.isEmpty
        ? null
        : _toolApprovalQueue.removeAt(0);
    notifyListeners();
    try {
      socket.respondToolApproval(
        turnId: request.turnId,
        approvalId: request.approvalId,
        approved: approved,
      );
      if (approved && _uiToolNames.contains(request.toolName)) {
        final String key = _uiToolActionKey(
          request.turnId,
          request.toolName,
          request.arguments,
        );
        _approvedUiToolActions[key] = (_approvedUiToolActions[key] ?? 0) + 1;
      }
    } on Object catch (caughtError) {
      error = caughtError;
      notifyListeners();
    }
  }

  void _enqueueOAuth(OAuthAuthorization authorization) {
    if (pendingOAuth?.authId == authorization.authId ||
        _oauthQueue.any(
          (OAuthAuthorization item) => item.authId == authorization.authId,
        )) {
      return;
    }
    final DateTime? expiresAt = authorization.expiresAt;
    if (expiresAt != null) {
      final Duration remaining = expiresAt.difference(DateTime.now());
      if (remaining <= Duration.zero) return;
      _oauthExpiryTimers[authorization.authId] = Timer(
        remaining,
        () => _dismissOAuth(authorization.authId),
      );
    }
    if (pendingOAuth == null) {
      pendingOAuth = authorization;
      oauthError = null;
    } else {
      _oauthQueue.add(authorization);
    }
    // Like an approval: consent must be visible even when the chat is hidden.
    chatPanelVisible = true;
    notifyListeners();
  }

  void _dismissOAuth(String authId) {
    _oauthExpiryTimers.remove(authId)?.cancel();
    final int before = _oauthQueue.length;
    _oauthQueue.removeWhere((OAuthAuthorization item) => item.authId == authId);
    bool changed = _oauthQueue.length != before;
    if (pendingOAuth?.authId == authId) {
      pendingOAuth = _oauthQueue.isEmpty ? null : _oauthQueue.removeAt(0);
      oauthError = null;
      changed = true;
    }
    if (changed && !_disposed) notifyListeners();
  }

  void _clearOAuth() {
    for (final Timer timer in _oauthExpiryTimers.values) {
      timer.cancel();
    }
    _oauthExpiryTimers.clear();
    _oauthQueue.clear();
    pendingOAuth = null;
    oauthError = null;
  }

  /// Picks up sign-ins that started while this client was not listening.
  Future<void> _recoverPendingOAuth(EngineRepository source) async {
    try {
      final List<OAuthAuthorization> pending = await source.rest
          .listPendingOAuth()
          .timeout(requestTimeout);
      if (_disposed || !identical(_engineEventRepository, source)) return;
      pending.forEach(_enqueueOAuth);
    } on Object catch (caughtError) {
      // An older engine has no such route; frames still deliver new prompts.
      debugPrint('Could not list pending OAuth sign-ins: $caughtError');
    }
  }

  /// Opens the sign-in page of [pendingOAuth] in the browser.
  Future<void> openOAuthSignIn() async {
    final OAuthAuthorization? authorization = pendingOAuth;
    if (authorization == null) return;
    oauthError = null;
    final Uri? uri = Uri.tryParse(authorization.url);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      oauthError = 'The sign-in address is not a web link.';
      notifyListeners();
      return;
    }
    try {
      if (!await oauthLauncher(uri)) {
        oauthError =
            'Could not open the browser. Copy this address and open '
            'it yourself: ${authorization.url}';
        notifyListeners();
      }
    } on Object catch (caughtError) {
      debugPrint('Opening the OAuth sign-in page failed: $caughtError');
      oauthError = 'Could not open the browser: $caughtError';
      notifyListeners();
    }
  }

  /// Finishes [pendingOAuth] with what the user pasted: the full address the
  /// browser ended on, a `code=...&state=...` query, or a bare code. The card
  /// stays (with the engine's reason in [oauthError]) when the engine refuses.
  Future<void> completeOAuthFromPaste(String pasted) async {
    final OAuthAuthorization? authorization = pendingOAuth;
    final RestEngineClient? client = repository?.rest;
    if (authorization == null || client == null || isSubmittingOAuth) return;
    final OAuthPaste? parsed = parseOAuthPaste(pasted);
    if (parsed == null) {
      oauthError = 'Paste the address from your browser or the code.';
      notifyListeners();
      return;
    }
    oauthError = null;
    isSubmittingOAuth = true;
    notifyListeners();
    try {
      await client
          .completeOAuth(
            authorization.authId,
            redirectUrl: parsed.redirectUrl,
            code: parsed.code,
            state: parsed.state,
          )
          .timeout(requestTimeout);
      isSubmittingOAuth = false;
      _dismissOAuth(authorization.authId);
      unawaited(settings.refreshTools());
    } on Object catch (caughtError) {
      isSubmittingOAuth = false;
      oauthError = caughtError is EngineApiException
          ? (caughtError.engineMessage ?? caughtError.toString())
          : caughtError;
      if (!_disposed) notifyListeners();
    }
  }

  /// Abandons [pendingOAuth]; the engine fails the waiting tool call.
  Future<void> cancelOAuth() async {
    final OAuthAuthorization? authorization = pendingOAuth;
    final RestEngineClient? client = repository?.rest;
    if (authorization == null || client == null) return;
    oauthError = null;
    try {
      await client.cancelOAuth(authorization.authId).timeout(requestTimeout);
      _dismissOAuth(authorization.authId);
    } on EngineApiException catch (caughtError) {
      if (caughtError.statusCode == 404) {
        // Already finished or expired on the engine.
        _dismissOAuth(authorization.authId);
        return;
      }
      oauthError = caughtError.engineMessage ?? caughtError.toString();
      if (!_disposed) notifyListeners();
    } on Object catch (caughtError) {
      oauthError = caughtError;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _handleClientToolRequest(
    WireFrame frame,
    Map<String, dynamic> data,
  ) async {
    final EngineSocket? socket = repository?.socket;
    final String? turnId = frame.id;
    final String? requestId = data['request_id'] is String
        ? data['request_id']! as String
        : null;
    final String? toolName = data['tool_name'] is String
        ? data['tool_name']! as String
        : null;
    final Object? rawArguments = data['arguments'];
    if (socket == null || turnId == null || requestId == null) return;
    final Object? rawGroup = data['group'];
    if (rawGroup is String && rawGroup.isNotEmpty) {
      // A client tool group (browser extension), not one of the UI tools.
      await _handleExtensionToolRequest(
        socket,
        turnId,
        requestId,
        rawGroup,
        toolName,
        rawArguments,
      );
      return;
    }
    if (toolName == null || rawArguments is! Map) {
      socket.sendClientToolResult(
        turnId: turnId,
        requestId: requestId,
        ok: false,
        error: 'The UI tool request is malformed.',
      );
      return;
    }
    final Map<String, dynamic> arguments = rawArguments.cast<String, dynamic>();
    final String approvalKey = _uiToolActionKey(turnId, toolName, arguments);
    final int approvalCount = _approvedUiToolActions[approvalKey] ?? 0;
    if (approvalCount <= 0) {
      socket.sendClientToolResult(
        turnId: turnId,
        requestId: requestId,
        ok: false,
        error: 'The UI tool request was not explicitly approved.',
      );
      return;
    }
    if (approvalCount == 1) {
      _approvedUiToolActions.remove(approvalKey);
    } else {
      _approvedUiToolActions[approvalKey] = approvalCount - 1;
    }
    try {
      final Object? result = await _executeUiTool(toolName, arguments);
      socket.sendClientToolResult(
        turnId: turnId,
        requestId: requestId,
        ok: true,
        result: result,
      );
    } on Object catch (caughtError) {
      socket.sendClientToolResult(
        turnId: turnId,
        requestId: requestId,
        ok: false,
        error: '$caughtError',
      );
    }
  }

  Future<Object?> _executeUiTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) async => switch (toolName) {
    'set_ui_theme_color' => _setUiThemeColor(arguments),
    'set_ui_lighting_mode' => _setUiLightingMode(arguments),
    'open_ui_workspace_file' => _openUiWorkspaceFile(arguments),
    'navigate_ui' => _navigateUi(arguments),
    'set_workspace_builtin_tool_enabled' => _setWorkspaceBuiltinToolEnabled(
      arguments,
    ),
    _ => throw StateError('The requested UI tool is not allowed.'),
  };

  Future<Map<String, dynamic>> _setUiThemeColor(
    Map<String, dynamic> arguments,
  ) async {
    final String color = _requiredString(arguments, 'color').toLowerCase();
    final String value = switch (color) {
      'device' => 'Device',
      'neutral' => 'Default',
      'blue' => 'Blue',
      'purple' => 'Purple',
      'green' => 'Green',
      'orange' => 'Orange',
      'red' => 'Red',
      _ => throw ArgumentError('Unsupported theme color.'),
    };
    await settings.updateGeneralSetting(
      DashboardSettingsController.colourThemeKey,
      value,
    );
    return <String, dynamic>{'color': color};
  }

  Future<Map<String, dynamic>> _setUiLightingMode(
    Map<String, dynamic> arguments,
  ) async {
    final String mode = _requiredString(arguments, 'mode').toLowerCase();
    final String value = switch (mode) {
      'device' => 'Device',
      'light' => 'Light',
      'dark' => 'Dark',
      _ => throw ArgumentError('Unsupported lighting mode.'),
    };
    await settings.updateGeneralSetting(
      DashboardSettingsController.modeKey,
      value,
    );
    return <String, dynamic>{'mode': mode};
  }

  Future<Map<String, dynamic>> _openUiWorkspaceFile(
    Map<String, dynamic> arguments,
  ) async {
    final Object? rawRootIndex = arguments['root_index'];
    final String path = _requiredString(arguments, 'path');
    if (rawRootIndex is! int || rawRootIndex < 0) {
      throw ArgumentError('root_index must be a non-negative integer.');
    }
    await activateSection(DashboardSection.files);
    if (!await openWorkspaceFile(rawRootIndex, path)) {
      throw StateError('The workspace file could not be opened.');
    }
    return <String, dynamic>{'rootIndex': rawRootIndex, 'path': path};
  }

  Future<Map<String, dynamic>> _navigateUi(
    Map<String, dynamic> arguments,
  ) async {
    final String destination = _requiredString(
      arguments,
      'destination',
    ).toLowerCase();
    switch (destination) {
      case 'workspaces':
        await activateSection(DashboardSection.workspaces);
      case 'threads':
        await activateSection(DashboardSection.threads);
      case 'files':
        await activateSection(DashboardSection.files);
      case 'settings':
        await activateSection(DashboardSection.settings);
      case 'account':
        updateLayoutState(contextPanelVisible: true);
        openAccountShortcut();
      case 'show_chat':
        updateLayoutState(chatPanelVisible: true);
      case 'hide_chat':
        updateLayoutState(chatPanelVisible: false);
      case 'show_main':
        updateLayoutState(mainPanelVisible: true);
      case 'hide_main':
        updateLayoutState(mainPanelVisible: false);
      case 'show_context':
        updateLayoutState(contextPanelVisible: true);
      case 'hide_context':
        updateLayoutState(contextPanelVisible: false);
      default:
        throw ArgumentError('Unsupported UI destination.');
    }
    return <String, dynamic>{'destination': destination};
  }

  Future<Map<String, dynamic>> _setWorkspaceBuiltinToolEnabled(
    Map<String, dynamic> arguments,
  ) async {
    final Workspace workspace =
        activeWorkspace ??
        (throw StateError('No active workspace is selected.'));
    final String group = _requiredString(arguments, 'group');
    final String tool = arguments['tool'] is String
        ? (arguments['tool']! as String).trim()
        : '';
    final Object? rawEnabled = arguments['enabled'];
    if (rawEnabled is! bool) {
      throw ArgumentError('enabled must be a boolean.');
    }
    final ToolCatalog catalog =
        await (repository?.rest ??
                (throw StateError('The Subconscious engine is not connected.')))
            .listToolCatalog();
    final List<BuiltinToolCatalogEntry>? groupCatalog = catalog.builtin[group];
    if (groupCatalog == null ||
        (tool.isNotEmpty &&
            !groupCatalog.any(
              (BuiltinToolCatalogEntry item) => item.name == tool,
            ))) {
      throw ArgumentError('The requested built-in tool is not registered.');
    }
    final Map<String, dynamic> config = _decodeJsonObject(
      workspace.toolsConfig,
    );
    final Map<String, dynamic> builtin = _objectValue(config['builtin']);
    final Map<String, dynamic> groupConfig = _objectValue(builtin[group]);
    if (tool.isEmpty) {
      groupConfig['enabled'] = rawEnabled;
    } else {
      final Map<String, dynamic> tools = _objectValue(groupConfig['tools']);
      tools[tool] = rawEnabled;
      groupConfig['tools'] = tools;
    }
    builtin[group] = groupConfig;
    config['builtin'] = builtin;
    await updateWorkspace(
      workspace,
      name: workspace.name,
      description: workspace.description,
      defaultModelId: workspace.defaultModelId,
      toolsConfig: jsonEncode(config),
      directories: workspace.directories ?? '[]',
      approvalConfig: workspace.approvalConfig ?? '{}',
      ragConfig: workspace.ragConfig ?? '{}',
    );
    return <String, dynamic>{
      'group': group,
      if (tool.isNotEmpty) 'tool': tool,
      'enabled': rawEnabled,
    };
  }

  static const Set<String> _uiToolNames = <String>{
    'set_ui_theme_color',
    'set_ui_lighting_mode',
    'open_ui_workspace_file',
    'navigate_ui',
    'set_workspace_builtin_tool_enabled',
  };

  static String _requiredString(Map<String, dynamic> arguments, String key) {
    final Object? value = arguments[key];
    if (value is! String || value.trim().isEmpty) {
      throw ArgumentError('$key must be a non-empty string.');
    }
    return value.trim();
  }

  static String _uiToolActionKey(
    String turnId,
    String toolName,
    Map<String, dynamic> arguments,
  ) =>
      '$turnId\u0000$toolName\u0000${jsonEncode(_sortedJson(_normalizedUiArguments(toolName, arguments)))}';

  static Map<String, dynamic> _normalizedUiArguments(
    String toolName,
    Map<String, dynamic> arguments,
  ) => switch (toolName) {
    'set_ui_theme_color' => <String, dynamic>{
      'color': arguments['color'] is String
          ? (arguments['color']! as String).trim().toLowerCase()
          : arguments['color'],
    },
    'set_ui_lighting_mode' => <String, dynamic>{
      'mode': arguments['mode'] is String
          ? (arguments['mode']! as String).trim().toLowerCase()
          : arguments['mode'],
    },
    'navigate_ui' => <String, dynamic>{
      'destination': arguments['destination'] is String
          ? (arguments['destination']! as String).trim().toLowerCase()
          : arguments['destination'],
    },
    'open_ui_workspace_file' => <String, dynamic>{
      'root_index': arguments['root_index'],
      'path': arguments['path'] is String
          ? (arguments['path']! as String).trim()
          : arguments['path'],
    },
    'set_workspace_builtin_tool_enabled' => <String, dynamic>{
      'group': arguments['group'] is String
          ? (arguments['group']! as String).trim()
          : arguments['group'],
      'enabled': arguments['enabled'],
      'tool': arguments['tool'] is String
          ? (arguments['tool']! as String).trim()
          : '',
    },
    _ => arguments,
  };

  static Object? _sortedJson(Object? value) {
    if (value is List) return value.map(_sortedJson).toList(growable: false);
    if (value is Map) {
      final List<String> keys = value.keys.map((Object? key) => '$key').toList()
        ..sort();
      return <String, dynamic>{
        for (final String key in keys) key: _sortedJson(value[key]),
      };
    }
    return value;
  }

  static Map<String, dynamic> _decodeJsonObject(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <String, dynamic>{};
    try {
      return _objectValue(jsonDecode(raw));
    } on FormatException {
      return <String, dynamic>{};
    }
  }

  Future<void> _refreshSelectedThreadHistory(String threadUuid) async {
    final EngineRepository? currentRepository = repository;
    final EngineLlmProvider? provider = chatProvider;
    if (currentRepository == null || provider == null) return;
    final int eventVersion = ++_engineEventVersion;
    try {
      final List<ChatMessage> messages = await currentRepository
          .listMessages(threadUuid)
          .timeout(requestTimeout);
      if (_disposed ||
          eventVersion != _engineEventVersion ||
          !identical(repository, currentRepository) ||
          !identical(chatProvider, provider) ||
          selectedThread?.uuid != threadUuid) {
        return;
      }
      _messageCache[threadUuid] = messages;
      provider.replaceEngineHistory(messages);
    } on Object {
      // Remote updates are opportunistic; the current view remains usable on failure.
    }
  }

  Future<void> _refreshThreadsForActiveWorkspace(String workspaceUuid) async {
    final EngineRepository? currentRepository = repository;
    if (currentRepository == null || activeWorkspace?.uuid != workspaceUuid) {
      return;
    }
    final int eventVersion = ++_engineEventVersion;
    try {
      final List<ThreadInfo> loaded = await currentRepository
          .listThreads(workspaceUuid)
          .timeout(requestTimeout);
      if (_disposed ||
          eventVersion != _engineEventVersion ||
          !identical(repository, currentRepository) ||
          activeWorkspace?.uuid != workspaceUuid) {
        return;
      }
      threads = loaded;
      final String? selectedThreadUuid = selectedThread?.uuid;
      if (selectedThreadUuid != null) {
        selectedThread = _threadByUuid(selectedThreadUuid);
      }
      notifyListeners();
    } on Object {
      // A later navigation load will reconcile the sidebar after a transient failure.
    }
  }

  Future<void> _closeRepository(EngineRepository repositoryToClose) async {
    if (identical(_repository, repositoryToClose)) _repository = null;
    if (identical(_engineEventRepository, repositoryToClose)) {
      _engineEventRepository = null;
      _engineEventVersion++;
      final StreamSubscription<WireFrame>? subscription =
          _engineEventSubscription;
      _engineEventSubscription = null;
      await subscription?.cancel();
    }
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
    if (changed) {
      final _WorkspaceViewerState? viewerState = workspace == null
          ? null
          : _workspaceViewerStates[workspace.uuid];
      WorkspaceFileReference? activeReference;
      for (final WorkspaceFileReference reference
          in viewerState?.openFiles ?? const <WorkspaceFileReference>[]) {
        if (reference.key == viewerState?.activeFileKey) {
          activeReference = reference;
          break;
        }
      }
      _filesRootIndex = activeReference?.rootIndex;
      _filesPath = activeReference?.path;
      // The editor shows the tabs of the workspace that became active. Its
      // saved tabs and any stored drafts are read in the background.
      unawaited(
        documents.switchWorkspace(
          workspace?.uuid,
          remembered:
              viewerState?.openFiles ?? const <WorkspaceFileReference>[],
          activeKey: viewerState?.activeFileKey,
        ),
      );
    }
    if (remember) _markNavigationChanged();
    notifyListeners();
    if (repository == null || !isConnected) return;
    if (workspace == null) {
      await _loadThreadsOfAllWorkspaces();
      return;
    }

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

  /// "All workspaces": the threads of every workspace in one list, newest
  /// first. A thread opened from it keeps its own workspace; creating a thread
  /// still needs a workspace to be chosen.
  Future<void> _loadThreadsOfAllWorkspaces() async {
    final EngineRepository? currentRepository = repository;
    if (currentRepository == null) return;
    final int requestVersion = ++_threadRequestVersion;
    isLoadingThreads = true;
    threadsError = null;
    notifyListeners();
    try {
      Object? firstFailure;
      int failures = 0;
      final List<List<ThreadInfo>> lists = await Future.wait(
        <Future<List<ThreadInfo>>>[
          for (final Workspace workspace in workspaces)
            currentRepository
                .listThreads(workspace.uuid)
                .timeout(requestTimeout)
                .catchError((Object error) {
                  failures++;
                  firstFailure ??= error;
                  return const <ThreadInfo>[];
                }),
        ],
      );
      if (requestVersion != _threadRequestVersion) return;
      final List<ThreadInfo> merged = <ThreadInfo>[
        for (final List<ThreadInfo> list in lists) ...list,
      ];
      final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
      merged.sort(
        (ThreadInfo a, ThreadInfo b) => (b.updatedAt ?? b.createdAt ?? epoch)
            .compareTo(a.updatedAt ?? a.createdAt ?? epoch),
      );
      threads = merged;
      if (failures > 0 && failures == workspaces.length) {
        threadsError = firstFailure;
      }
    } on Object catch (caughtError) {
      if (requestVersion == _threadRequestVersion) threadsError = caughtError;
    } finally {
      if (requestVersion == _threadRequestVersion) {
        isLoadingThreads = false;
        notifyListeners();
      }
    }
  }

  /// The name of a workspace, or null when it is not in the loaded list.
  String? workspaceName(String uuid) => _workspaceByUuid(uuid)?.name;

  Future<void> selectThread(ThreadInfo thread, {bool remember = true}) async {
    final EngineRepository? currentRepository = repository;
    final int requestVersion = ++_chatRequestVersion;
    selectedThread = thread;
    pendingDraftTitle = null;
    pendingDraftToolsConfig = null;
    chatSessionVersion++;
    // Opened from the all-workspaces list the thread keeps its own workspace;
    // the list stays on "all" rather than switching to that workspace.
    final String? workspaceUuid = threadsWorkspace?.uuid;
    if (workspaceUuid != null) {
      _threadsWorkspaceUuid = workspaceUuid;
      _setRememberedThread(workspaceUuid, thread.uuid);
      if (remember) _markNavigationChanged();
    }
    _retireProvider(chatProvider);
    chatProvider = null;
    chatError = null;
    isLoadingChat = true;
    notifyListeners();
    if (currentRepository == null || !isConnected) {
      // Offline: show what was loaded earlier. The composer stays on screen
      // (disabled); it never gives way to an error.
      final EngineLlmProvider offline =
          _runningProviders.remove(thread.uuid) ??
          EngineLlmProvider(
            threadUuid: thread.uuid,
            modelId: thread.defaultModelId ?? threadsWorkspace?.defaultModelId,
          );
      offline.replaceEngineHistory(
        _messageCache[thread.uuid] ?? const <ChatMessage>[],
      );
      chatProvider = offline;
      isLoadingChat = false;
      notifyListeners();
      return;
    }

    try {
      final List<ChatMessage> messages = await currentRepository
          .listMessages(thread.uuid)
          .timeout(requestTimeout);
      _messageCache[thread.uuid] = messages;
      if (_disposed ||
          requestVersion != _chatRequestVersion ||
          selectedThread?.uuid != thread.uuid) {
        return;
      }
      // A turn started earlier may still be running for this thread.
      final EngineLlmProvider provider =
          _runningProviders.remove(thread.uuid) ??
          EngineLlmProvider(
            repository: currentRepository,
            threadUuid: thread.uuid,
            modelId: thread.defaultModelId ?? threadsWorkspace?.defaultModelId,
          );
      provider.replaceRepository(currentRepository);
      provider.replaceEngineHistory(messages);
      chatProvider = provider;
      _watchThread(currentRepository, thread.uuid);
    } on Object catch (caughtError) {
      if (!_disposed && requestVersion == _chatRequestVersion) {
        chatError = caughtError;
        // Keep the composer: fall back to the cached history.
        chatProvider ??=
            EngineLlmProvider(
              repository: currentRepository,
              threadUuid: thread.uuid,
              modelId:
                  thread.defaultModelId ?? threadsWorkspace?.defaultModelId,
            )..replaceEngineHistory(
              _messageCache[thread.uuid] ?? const <ChatMessage>[],
            );
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
          defaultModelId: draftProvider.modelId,
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
          defaultModelId: workspace.defaultModelId,
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
    String? defaultModelId,
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
          defaultModelId: defaultModelId,
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

  void selectFileTreeNode(
    int rootIndex,
    String path, {
    required bool isDirectory,
  }) {
    selectedFileTreeNodeKey = _directoryKey(rootIndex, path);
    selectedFileTreeNode = WorkspaceFileTreeNode(
      rootIndex: rootIndex,
      path: path,
      isDirectory: isDirectory,
    );
    notifyListeners();
  }

  ({int rootIndex, String path})? get selectedCreationDirectory {
    final WorkspaceFileTreeNode? node = selectedFileTreeNode;
    if (node == null ||
        !fileRoots.any(
          (WorkspaceDirectoryRoot root) => root.index == node.rootIndex,
        )) {
      return null;
    }
    return (
      rootIndex: node.rootIndex,
      path: node.isDirectory ? node.path : _parentDirectory(node.path),
    );
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

  /// The file shown in the main panel, for features that need to know what the
  /// user is looking at, such as the chat's active-file context.
  WorkspaceFileReference? get activeFileReference => documents.activeReference;

  /// Opens a file in the editor, or switches to it when it is already open.
  Future<bool> openWorkspaceFile(
    int rootIndex,
    String path, {
    bool remember = true,
  }) async {
    final Workspace? workspace = _filesWorkspace;
    if (workspace == null || repository?.rest == null) return false;
    selectedFileTreeNodeKey = _directoryKey(rootIndex, path);
    selectedFileTreeNode = WorkspaceFileTreeNode(
      rootIndex: rootIndex,
      path: path,
      isDirectory: false,
    );
    filesError = null;
    notifyListeners();
    try {
      final EditorTab? tab = await documents.open(rootIndex, path);
      if (tab == null) return false;
      if (remember) {
        _filesWorkspaceUuid = workspace.uuid;
        _filesRootIndex = rootIndex;
        _filesPath = path;
        _markNavigationChanged();
      }
      return true;
    } on Object catch (caughtError) {
      filesError = caughtError;
      return false;
    } finally {
      notifyListeners();
    }
  }

  /// Checks the open files against the disk, for example after the assistant
  /// finished a turn that may have edited one.
  Future<void> refreshOpenFile() => documents.checkExternalChanges();

  void _onEditorTabsChanged(
    String workspaceUuid,
    List<WorkspaceFileReference> files,
    String? activeKey,
  ) {
    if (activeWorkspace?.uuid != workspaceUuid) return;
    rememberOpenFiles(files, activeKey: activeKey);
  }

  void _onEditorActiveChanged(EditorTab? tab) {
    if (tab == null) {
      selectedFileTreeNodeKey = null;
      selectedFileTreeNode = null;
      _filesRootIndex = null;
      _filesPath = null;
    } else {
      selectedFileTreeNodeKey = _directoryKey(tab.rootIndex, tab.path);
      selectedFileTreeNode = WorkspaceFileTreeNode(
        rootIndex: tab.rootIndex,
        path: tab.path,
        isDirectory: false,
      );
      _filesWorkspaceUuid = tab.workspaceUuid;
      _filesRootIndex = tab.rootIndex;
      _filesPath = tab.path;
    }
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

  bool canMoveWorkspaceNode({
    required int sourceRootIndex,
    required String sourcePath,
    required bool sourceIsDirectory,
    required int destinationRootIndex,
    required String destinationPath,
  }) {
    if (isMovingWorkspaceNode || sourceRootIndex != destinationRootIndex) {
      return false;
    }
    final String source = sourcePath.replaceAll('\\', '/');
    final String destination = destinationPath.replaceAll('\\', '/');
    if (source.isEmpty || destination == _parentDirectory(source)) return false;
    return !sourceIsDirectory ||
        (destination != source && !destination.startsWith('$source/'));
  }

  Future<void> moveWorkspaceNode({
    required int sourceRootIndex,
    required String sourcePath,
    required bool sourceIsDirectory,
    required int destinationRootIndex,
    required String destinationPath,
  }) async {
    if (isMovingWorkspaceNode || sourceRootIndex != destinationRootIndex) {
      return;
    }
    final Workspace? workspace = _filesWorkspace;
    final RestEngineClient? client = repository?.rest;
    if (workspace == null || client == null) return;

    isMovingWorkspaceNode = true;
    filesError = null;
    notifyListeners();
    try {
      final WorkspaceFileEntry moved = await client
          .moveWorkspacePath(
            workspaceUuid: workspace.uuid,
            sourceRootIndex: sourceRootIndex,
            sourcePath: sourcePath,
            destinationRootIndex: destinationRootIndex,
            destinationPath: destinationPath,
          )
          .timeout(requestTimeout);
      final WorkspaceFileMove move = WorkspaceFileMove(
        sourceRootIndex: sourceRootIndex,
        sourcePath: sourcePath,
        destinationRootIndex: destinationRootIndex,
        destinationPath: moved.relativePath,
        isDirectory: sourceIsDirectory,
      );
      _applyWorkspaceFileMove(move);
      await _reloadMoveParents(move);
      _markNavigationChanged();
    } on Object catch (caughtError) {
      filesError = caughtError;
    } finally {
      isMovingWorkspaceNode = false;
      notifyListeners();
    }
  }

  /// The absolute path of a file or folder on the machine the engine runs on.
  String? absoluteWorkspacePath(int rootIndex, String path) {
    for (final WorkspaceDirectoryRoot root in fileRoots) {
      if (root.index != rootIndex) continue;
      final String base = root.path.replaceAll('\\', '/');
      final String relative = path.replaceAll('\\', '/');
      if (relative.isEmpty) return root.path;
      final String joined = base.endsWith('/')
          ? '$base$relative'
          : '$base/$relative';
      // Keep the separators the user entered the root with.
      return root.path.contains('\\') ? joined.replaceAll('/', '\\') : joined;
    }
    return null;
  }

  /// Renames a file or folder in place. Returns the failure, if any, so the
  /// caller can tell the user why.
  Future<Object?> renameWorkspaceNode({
    required int rootIndex,
    required String path,
    required bool isDirectory,
    required String newName,
  }) async {
    if (isMovingWorkspaceNode) return null;
    final Workspace? workspace = _filesWorkspace;
    final RestEngineClient? client = repository?.rest;
    if (workspace == null || client == null) return null;
    isMovingWorkspaceNode = true;
    filesError = null;
    notifyListeners();
    try {
      final WorkspaceFileEntry renamed = await client
          .moveWorkspacePath(
            workspaceUuid: workspace.uuid,
            sourceRootIndex: rootIndex,
            sourcePath: path,
            destinationRootIndex: rootIndex,
            destinationPath: _parentDirectory(path.replaceAll('\\', '/')),
            newName: newName,
          )
          .timeout(requestTimeout);
      final WorkspaceFileMove move = WorkspaceFileMove(
        sourceRootIndex: rootIndex,
        sourcePath: path,
        destinationRootIndex: rootIndex,
        destinationPath: renamed.relativePath,
        isDirectory: isDirectory,
      );
      _applyWorkspaceFileMove(move);
      await _reloadMoveParents(move);
      _markNavigationChanged();
      return null;
    } on Object catch (caughtError) {
      return caughtError;
    } finally {
      isMovingWorkspaceNode = false;
      notifyListeners();
    }
  }

  void _applyWorkspaceFileMove(WorkspaceFileMove move) {
    final WorkspaceFileTreeNode? selectedNode = selectedFileTreeNode;
    if (selectedNode != null) {
      final String? rebased = _rebaseWorkspacePath(
        rootIndex: selectedNode.rootIndex,
        path: selectedNode.path,
        move: move,
      );
      if (rebased != null) {
        selectedFileTreeNode = WorkspaceFileTreeNode(
          rootIndex: move.destinationRootIndex,
          path: rebased,
          isDirectory: selectedNode.isDirectory,
        );
        selectedFileTreeNodeKey = _directoryKey(
          move.destinationRootIndex,
          rebased,
        );
      }
    }

    documents.applyMove(move);

    if (_filesRootIndex != null && _filesPath != null) {
      final String? rebased = _rebaseWorkspacePath(
        rootIndex: _filesRootIndex!,
        path: _filesPath!,
        move: move,
      );
      if (rebased != null) {
        _filesRootIndex = move.destinationRootIndex;
        _filesPath = rebased;
      }
    }

    for (final _WorkspaceViewerState state in _workspaceViewerStates.values) {
      final String? activeKey = state.activeFileKey;
      String? rebasedActivePath;
      if (activeKey != null) {
        for (final WorkspaceFileReference reference in state.openFiles) {
          if (reference.key == activeKey) {
            rebasedActivePath = _rebaseWorkspacePath(
              rootIndex: reference.rootIndex,
              path: reference.path,
              move: move,
            );
            break;
          }
        }
      }
      state.openFiles = <WorkspaceFileReference>[
        for (final WorkspaceFileReference reference in state.openFiles)
          if (_rebaseWorkspacePath(
                rootIndex: reference.rootIndex,
                path: reference.path,
                move: move,
              )
              case final String rebased)
            WorkspaceFileReference(
              rootIndex: move.destinationRootIndex,
              path: rebased,
            )
          else
            reference,
      ];
      if (rebasedActivePath != null) {
        state.activeFileKey = WorkspaceFileReference(
          rootIndex: move.destinationRootIndex,
          path: rebasedActivePath,
        ).key;
      }
      final Set<String> rebasedExpanded = <String>{
        for (final String key in state.expandedDirectoryKeys)
          _rebaseDirectoryKey(key, move) ?? key,
      };
      state.expandedDirectoryKeys
        ..clear()
        ..addAll(rebasedExpanded);
    }
  }

  Future<void> _reloadMoveParents(WorkspaceFileMove move) async {
    final Set<String> parents = <String>{
      _directoryKey(move.sourceRootIndex, _parentDirectory(move.sourcePath)),
      _directoryKey(
        move.destinationRootIndex,
        _parentDirectory(move.destinationPath),
      ),
    };
    for (final String key in parents) {
      _directoryEntries.remove(key);
    }
    await Future.wait(<Future<void>>[
      for (final String key in parents)
        loadDirectory(
          int.parse(key.substring(0, key.indexOf(':'))),
          key.substring(key.indexOf(':') + 1),
        ),
    ]);
  }

  static String? _rebaseWorkspacePath({
    required int rootIndex,
    required String path,
    required WorkspaceFileMove move,
  }) => rebaseWorkspacePath(rootIndex: rootIndex, path: path, move: move);

  String? _rebaseDirectoryKey(String key, WorkspaceFileMove move) {
    final int separator = key.indexOf(':');
    if (separator < 1) return null;
    final int? rootIndex = int.tryParse(key.substring(0, separator));
    if (rootIndex == null) return null;
    final String? path = _rebaseWorkspacePath(
      rootIndex: rootIndex,
      path: key.substring(separator + 1),
      move: move,
    );
    return path == null ? null : _directoryKey(move.destinationRootIndex, path);
  }

  Future<void> _reloadParent(int rootIndex, String path) async {
    final String parent = _parentDirectory(path);
    _directoryEntries.remove(_directoryKey(rootIndex, parent));
    await loadDirectory(rootIndex, parent);
  }

  _WorkspaceViewerState? get _currentViewerState {
    final String? workspaceUuid = activeWorkspace?.uuid;
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
    unawaited(documents.forgetWorkspace(workspaceUuid));
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
    _retireProvider(chatProvider);
    chatError = null;
    isLoadingChat = false;
    final EngineRepository? currentRepository = repository;
    chatProvider = (workspaceUuid == null && threadUuid == null)
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
    selectedFileTreeNodeKey = null;
    selectedFileTreeNode = null;
    filesError = null;
  }

  static String _parentDirectory(String path) {
    final String normalized = path.replaceAll('\\', '/');
    final int separator = normalized.lastIndexOf('/');
    return separator < 0 ? '' : normalized.substring(0, separator);
  }

  String _directoryKey(int rootIndex, String path) =>
      '$rootIndex:${path.replaceAll('\\', '/')}';

  /// Stops this window's timers and closes its own sockets without waiting on
  /// a close handshake. The engine outlives the GUI and is never asked to
  /// stop here.
  Future<void> shutdownConnections() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _appStateSaveTimer?.cancel();
    _appStateSaveTimer = null;
    for (final Timer timer in _oauthExpiryTimers.values) {
      timer.cancel();
    }
    _oauthExpiryTimers.clear();
    final StreamSubscription<WireFrame>? subscription =
        _engineEventSubscription;
    _engineEventSubscription = null;
    unawaited(subscription?.cancel() ?? Future<void>.value());
    final EngineRepository? current = repository;
    if (current != null) {
      await Future.wait(<Future<void>>[
        current.socket.close(),
        current.rest.close(),
      ]);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _appStateSaveTimer?.cancel();
    for (final Timer timer in _oauthExpiryTimers.values) {
      timer.cancel();
    }
    _oauthExpiryTimers.clear();
    _engineEventRepository = null;
    _unsubscribeExtensionTools?.call();
    _unsubscribeExtensionTools = null;
    _extensionTools.clear();
    _visibilityListener?.dispose();
    _resumeListener?.dispose();
    _resumeListener = null;
    _visibilityListener = null;
    if (_extensionHost.isExtension) _extensionHost.setVisible(false);
    final StreamSubscription<WireFrame>? subscription =
        _engineEventSubscription;
    _engineEventSubscription = null;
    unawaited(subscription?.cancel() ?? Future<void>.value());
    chatProvider?.dispose();
    fallbackChatProvider.dispose();
    for (final EngineLlmProvider provider in _runningProviders.values) {
      if (!identical(provider, chatProvider)) provider.dispose();
    }
    _runningProviders.clear();
    documents.dispose();
    settings.dispose();
    unawaited(repository?.socket.dispose());
    unawaited(repository?.rest.close());
    super.dispose();
  }
}

/// Reads and writes workspace files for the editor through the engine's REST
/// API, translating its failures into the editor's own exceptions.
final class _EngineFileGateway implements FileGateway {
  _EngineFileGateway(this._controller);

  /// Writes can carry a megabyte, so they get more time than a status call.
  static const Duration _timeout = Duration(seconds: 15);

  final DashboardController _controller;

  RestEngineClient get _client =>
      _controller.repository?.rest ?? (throw const FileUnavailableException());

  @override
  bool get isAvailable =>
      _controller.isConnected && _controller.repository != null;

  @override
  Future<FileSnapshot> readText(
    String workspaceUuid,
    int rootIndex,
    String path,
  ) => _translate(() async {
    final WorkspaceFileContent result = await _client
        .readFile(
          workspaceUuid: workspaceUuid,
          rootIndex: rootIndex,
          path: path,
        )
        .timeout(_timeout);
    return FileSnapshot(text: result.content, version: result.version);
  });

  @override
  Future<PreviewSnapshot> readPreview(
    String workspaceUuid,
    int rootIndex,
    String path,
  ) => _translate(() async {
    final WorkspaceFilePreview preview = await _client
        .previewFile(
          workspaceUuid: workspaceUuid,
          rootIndex: rootIndex,
          path: path,
        )
        .timeout(_timeout);
    return PreviewSnapshot(
      bytes: preview.bytes,
      kind: switch (preview.kind) {
        WorkspacePreviewKind.image => PreviewKind.image,
        WorkspacePreviewKind.pdf => PreviewKind.pdf,
        WorkspacePreviewKind.docx => PreviewKind.docx,
      },
      mediaType: preview.mediaType,
    );
  });

  @override
  Future<String?> write(
    String workspaceUuid,
    int rootIndex,
    String path,
    String content, {
    String? expectedVersion,
  }) => _translate(() async {
    final WorkspaceFileContent result = await _client
        .writeFile(
          workspaceUuid: workspaceUuid,
          rootIndex: rootIndex,
          path: path,
          content: content,
          expectedVersion: expectedVersion,
        )
        .timeout(_timeout);
    return result.version;
  });

  @override
  Future<String?> create(
    String workspaceUuid,
    int rootIndex,
    String path,
    String content,
  ) => _translate(() async {
    try {
      final WorkspaceFileContent result = await _client
          .createFile(
            workspaceUuid: workspaceUuid,
            rootIndex: rootIndex,
            path: path,
            content: content,
          )
          .timeout(_timeout);
      return result.version;
    } on EngineApiException catch (error) {
      // Something already exists at the path again: treat it as a conflict so
      // the user chooses between the two versions.
      if (error.statusCode == 409) throw const FileConflictException();
      rethrow;
    }
  });

  @override
  Future<String> currentVersion(
    String workspaceUuid,
    int rootIndex,
    String path,
  ) => _translate(() async {
    final WorkspaceFileVersion result = await _client
        .fileVersion(
          workspaceUuid: workspaceUuid,
          rootIndex: rootIndex,
          path: path,
        )
        .timeout(_timeout);
    return result.version;
  });

  Future<T> _translate<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on EngineApiException catch (error) {
      if (error.isVersionConflict) {
        throw FileConflictException(currentVersion: error.currentVersion);
      }
      if (error.statusCode == 404) throw const FileMissingException();
      rethrow;
    }
  }
}
