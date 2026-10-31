import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

enum MainPanelDestination { utility, workspace, agent, files, settings }

enum SettingsPage { general, models, tools, skills, account, about }

enum AppLightingMode { device, light, dark }

enum AppAccentTheme { device, neutral, blue, purple, green, orange, red }

enum DashboardSidebarPosition { left, right }

enum DashboardPanel { context, chat, main }

typedef EngineRepositoryProvider = EngineRepository? Function();

/// What the user pasted to finish an OAuth sign-in: exactly one of
/// [redirectUrl] or [code] is set.
typedef OAuthPaste = ({String? redirectUrl, String? code, String? state});

/// Reads a pasted full address (sent as is), a `code=...&state=...` query or a
/// bare code. Null when [pasted] is empty.
OAuthPaste? parseOAuthPaste(String pasted) {
  final String text = pasted.trim();
  if (text.isEmpty) return null;
  if (text.contains('://')) return (redirectUrl: text, code: null, state: null);
  if (text.contains('code=')) {
    try {
      final Map<String, String> query = Uri.splitQueryString(
        text.startsWith('?') ? text.substring(1) : text,
      );
      final String? code = query['code'];
      if (code != null && code.isNotEmpty) {
        return (redirectUrl: null, code: code, state: query['state']);
      }
    } on FormatException {
      // Not a query string after all: treat it as the code itself.
    }
  }
  return (redirectUrl: null, code: text, state: null);
}

Future<bool> _openExternally(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

final class DashboardSettingsController extends ChangeNotifier {
  DashboardSettingsController({
    required this.repositoryProvider,
    this.urlLauncher = _openExternally,
  });

  /// Opens a web page outside the app (OAuth sign-in); returns whether it
  /// was opened.
  final Future<bool> Function(Uri uri) urlLauncher;

  static const Duration requestTimeout = Duration(seconds: 5);
  static const String settingsClient = 'flutter';
  static const String modeKey = 'mode';
  static const String colourThemeKey = 'colour_theme';
  static const String sidebarPositionKey = 'sidebar_position';
  static const String panelConfigurationKey = 'panel_configuration';

  final EngineRepositoryProvider repositoryProvider;
  final Map<String, int> _generalUpdateVersions = <String, int>{};
  int _generalLoadVersion = 0;

  MainPanelDestination destination = MainPanelDestination.utility;
  SettingsPage activePage = SettingsPage.general;
  Map<String, String> generalSettings = const <String, String>{};
  List<ModelConfiguration> modelConfigurations = const <ModelConfiguration>[];
  List<ToolRegistryEntry> tools = const <ToolRegistryEntry>[];
  bool isLoadingGeneral = false;
  bool hasLoadedGeneralSettings = false;
  bool isLoadingModels = false;
  bool isLoadingTools = false;
  List<SkillEntry> skills = const <SkillEntry>[];
  bool isLoadingSkills = false;
  Object? skillsError;

  /// Last connection-test result per tool uuid, and the tests in flight.
  final Map<String, ToolTestResult> toolTestResults =
      <String, ToolTestResult>{};
  final Set<String> testingToolUuids = <String>{};
  Object? generalError;
  Object? modelsError;
  Object? toolsError;

  AppLightingMode get lightingMode =>
      switch (generalSettings[modeKey]?.toLowerCase()) {
        'device' => AppLightingMode.device,
        'dark' => AppLightingMode.dark,
        _ => AppLightingMode.light,
      };

  AppAccentTheme get accentTheme =>
      switch (generalSettings[colourThemeKey]?.toLowerCase()) {
        'device' => AppAccentTheme.device,
        'blue' => AppAccentTheme.blue,
        'purple' => AppAccentTheme.purple,
        'green' => AppAccentTheme.green,
        'orange' => AppAccentTheme.orange,
        'red' => AppAccentTheme.red,
        _ => AppAccentTheme.neutral, // 'default', missing, or unrecognised
      };

  DashboardSidebarPosition get sidebarPosition =>
      generalSettings[sidebarPositionKey]?.toLowerCase() == 'right'
      ? DashboardSidebarPosition.right
      : DashboardSidebarPosition.left;

  List<DashboardPanel> get panelOrder =>
      switch (_normalizedGeneralValue(panelConfigurationKey)) {
        'contextchatmain' => const <DashboardPanel>[
          DashboardPanel.context,
          DashboardPanel.chat,
          DashboardPanel.main,
        ],
        'chatcontextmain' => const <DashboardPanel>[
          DashboardPanel.chat,
          DashboardPanel.context,
          DashboardPanel.main,
        ],
        'contextmainchat' => const <DashboardPanel>[
          DashboardPanel.context,
          DashboardPanel.main,
          DashboardPanel.chat,
        ],
        'maincontextchat' => const <DashboardPanel>[
          DashboardPanel.main,
          DashboardPanel.context,
          DashboardPanel.chat,
        ],
        'mainchatcontext' => const <DashboardPanel>[
          DashboardPanel.main,
          DashboardPanel.chat,
          DashboardPanel.context,
        ],
        _ => const <DashboardPanel>[
          DashboardPanel.chat,
          DashboardPanel.main,
          DashboardPanel.context,
        ],
      };

  String get modeValue => switch (lightingMode) {
    AppLightingMode.device => 'Device',
    AppLightingMode.light => 'Light',
    AppLightingMode.dark => 'Dark',
  };

  String get colourThemeValue => switch (accentTheme) {
    AppAccentTheme.device => 'Device',
    AppAccentTheme.neutral => 'Default',
    AppAccentTheme.blue => 'Blue',
    AppAccentTheme.purple => 'Purple',
    AppAccentTheme.green => 'Green',
    AppAccentTheme.orange => 'Orange',
    AppAccentTheme.red => 'Red',
  };

  String get sidebarPositionValue =>
      sidebarPosition == DashboardSidebarPosition.right ? 'Right' : 'Left';

  String get panelConfigurationValue => panelOrder
      .map(
        (DashboardPanel panel) => switch (panel) {
          DashboardPanel.context => 'Context',
          DashboardPanel.chat => 'Chat',
          DashboardPanel.main => 'Main',
        },
      )
      .join(' · ');

  String generalValue(String key, String fallback) =>
      generalSettings[key] ?? fallback;

  String _normalizedGeneralValue(String key) => (generalSettings[key] ?? '')
      .toLowerCase()
      .replaceAll(RegExp('[^a-z]'), '');

  void showUtility() {
    destination = MainPanelDestination.utility;
    notifyListeners();
  }

  void showWorkspace() {
    destination = MainPanelDestination.workspace;
    notifyListeners();
  }

  void showAgent() {
    destination = MainPanelDestination.agent;
    notifyListeners();
  }

  void showFiles() {
    destination = MainPanelDestination.files;
    notifyListeners();
  }

  void showSettings() => openSettingsPage(activePage);

  void openSettingsPage(SettingsPage page) {
    activePage = page;
    destination = MainPanelDestination.settings;
    notifyListeners();
    switch (page) {
      case SettingsPage.general:
        unawaited(loadGeneralSettings());
      case SettingsPage.models:
        unawaited(loadModelConfigurations());
      case SettingsPage.tools:
        unawaited(loadTools());
      case SettingsPage.skills:
        unawaited(loadSkills());
      case SettingsPage.account:
      case SettingsPage.about:
        break;
    }
  }

  /// Changes made while the engine was away; sent after the next load.
  final Map<String, String> _pendingGeneral = <String, String>{};

  bool get hasPendingGeneral => _pendingGeneral.isNotEmpty;

  /// Reloads the general settings after a failure (the Retry button).
  Future<void> retryGeneral() => loadGeneralSettings(force: true);

  /// [silent] loads (background reconnects) show no progress and notify only
  /// when the outcome changes, so the page does not flicker.
  Future<void> loadGeneralSettings({
    bool force = false,
    bool silent = false,
  }) async {
    if ((isLoadingGeneral || hasLoadedGeneralSettings) && !force) return;
    final int version = ++_generalLoadVersion;
    final Map<String, int> updateVersionsAtStart = Map<String, int>.of(
      _generalUpdateVersions,
    );
    final Object? errorAtStart = generalError;
    if (force) hasLoadedGeneralSettings = false;
    if (!silent) {
      isLoadingGeneral = true;
      generalError = null;
      notifyListeners();
    }
    try {
      final List<EngineSetting> loaded = await _client
          .getSettings(client: settingsClient)
          .timeout(requestTimeout);
      if (version != _generalLoadVersion) return;
      final Map<String, String> loadedSettings = <String, String>{
        for (final EngineSetting setting in loaded) setting.key: setting.value,
      };
      for (final MapEntry<String, int> update
          in _generalUpdateVersions.entries) {
        if (update.value == updateVersionsAtStart[update.key]) continue;
        final String? currentValue = generalSettings[update.key];
        if (currentValue != null) loadedSettings[update.key] = currentValue;
      }
      loadedSettings.addAll(_pendingGeneral);
      generalSettings = loadedSettings;
      hasLoadedGeneralSettings = true;
      generalError = null;
      await _flushPendingGeneral();
    } on Object catch (error) {
      if (version == _generalLoadVersion) generalError = error;
    } finally {
      if (version == _generalLoadVersion) {
        final bool wasLoading = isLoadingGeneral;
        isLoadingGeneral = false;
        if (!silent ||
            wasLoading ||
            hasLoadedGeneralSettings ||
            '$errorAtStart' != '$generalError') {
          notifyListeners();
        }
      }
    }
  }

  Future<void> _flushPendingGeneral() async {
    if (_pendingGeneral.isEmpty) return;
    final Map<String, String> sending = Map<String, String>.of(_pendingGeneral);
    try {
      await _client
          .putSettings(<EngineSetting>[
            for (final MapEntry<String, String> entry in sending.entries)
              EngineSetting(
                key: entry.key,
                value: entry.value,
                client: settingsClient,
              ),
          ])
          .timeout(requestTimeout);
      for (final MapEntry<String, String> entry in sending.entries) {
        if (_pendingGeneral[entry.key] == entry.value) {
          _pendingGeneral.remove(entry.key);
        }
      }
    } on Object catch (error) {
      // Kept pending; sent after the next successful load.
      debugPrint('Could not save pending settings: $error');
    }
  }

  Future<void> updateGeneralSetting(String key, String value) async {
    final String? previousValue = generalSettings[key];
    final int version = (_generalUpdateVersions[key] ?? 0) + 1;
    _generalUpdateVersions[key] = version;
    generalSettings = <String, String>{...generalSettings, key: value};
    if (repositoryProvider() == null) {
      // Engine away: keep the choice locally and save it once it is back.
      _pendingGeneral[key] = value;
      notifyListeners();
      return;
    }
    generalError = null;
    notifyListeners();
    try {
      await _client
          .putSettings(<EngineSetting>[
            EngineSetting(key: key, value: value, client: settingsClient),
          ])
          .timeout(requestTimeout);
      if (_pendingGeneral[key] == value) _pendingGeneral.remove(key);
    } on Object catch (error) {
      if (_generalUpdateVersions[key] != version) {
        return;
      }
      final Map<String, String> restoredSettings = <String, String>{
        ...generalSettings,
      }..remove(key);
      if (previousValue != null) {
        restoredSettings[key] = previousValue;
      }
      generalSettings = restoredSettings;
      generalError = error;
      notifyListeners();
    }
  }

  Future<void> loadModelConfigurations() async {
    if (isLoadingModels) return;
    isLoadingModels = true;
    modelsError = null;
    notifyListeners();
    try {
      modelConfigurations = await _client.listModelConfigurations().timeout(
        requestTimeout,
      );
    } on Object catch (error) {
      modelsError = error;
    } finally {
      isLoadingModels = false;
      notifyListeners();
    }
  }

  Future<bool> saveModelConfiguration({
    ModelConfiguration? existing,
    required ModelConfigurationRequest request,
  }) async {
    modelsError = null;
    try {
      final ModelConfiguration saved = existing == null
          ? await _client
                .createModelConfiguration(request)
                .timeout(requestTimeout)
          : await _client
                .updateModelConfiguration(
                  id: existing.id,
                  configuration: request,
                )
                .timeout(requestTimeout);
      modelConfigurations = <ModelConfiguration>[
        for (final ModelConfiguration configuration in modelConfigurations)
          if (configuration.id == saved.id) saved else configuration,
        if (existing == null) saved,
      ];
      notifyListeners();
      return true;
    } on Object catch (error) {
      modelsError = error;
      notifyListeners();
      return false;
    }
  }

  Future<bool> deleteModelConfiguration(
    ModelConfiguration configuration,
  ) async {
    modelsError = null;
    try {
      await _client
          .deleteModelConfiguration(configuration.id)
          .timeout(requestTimeout);
      modelConfigurations = modelConfigurations
          .where((ModelConfiguration item) => item.id != configuration.id)
          .toList(growable: false);
      notifyListeners();
      return true;
    } on Object catch (error) {
      modelsError = error;
      notifyListeners();
      return false;
    }
  }

  Future<void> loadTools() async {
    if (isLoadingTools) return;
    isLoadingTools = true;
    toolsError = null;
    notifyListeners();
    try {
      tools = await _client.listTools().timeout(requestTimeout);
    } on Object catch (error) {
      toolsError = error;
    } finally {
      isLoadingTools = false;
      notifyListeners();
    }
  }

  Future<bool> saveTool({
    ToolRegistryEntry? existing,
    required ToolRegistryRequest request,
  }) async {
    toolsError = null;
    try {
      final ToolRegistryEntry saved = existing == null
          ? await _client.createTool(request).timeout(requestTimeout)
          : await _client
                .updateTool(uuid: existing.uuid, tool: request)
                .timeout(requestTimeout);
      tools = <ToolRegistryEntry>[
        for (final ToolRegistryEntry tool in tools)
          if (tool.uuid == saved.uuid) saved else tool,
        if (existing == null) saved,
      ];
      notifyListeners();
      return true;
    } on Object catch (error) {
      toolsError = error;
      notifyListeners();
      return false;
    }
  }

  Future<bool> deleteTool(ToolRegistryEntry tool) async {
    toolsError = null;
    try {
      await _client.deleteTool(tool.uuid).timeout(requestTimeout);
      tools = tools
          .where((ToolRegistryEntry item) => item.uuid != tool.uuid)
          .toList(growable: false);
      notifyListeners();
      return true;
    } on Object catch (error) {
      toolsError = error;
      notifyListeners();
      return false;
    }
  }

  /// Connects to the tool's server and lists what it offers. Returns null when
  /// the request itself failed ([toolsError] is set then).
  Future<ToolTestResult?> testTool(ToolRegistryEntry tool) async {
    toolsError = null;
    testingToolUuids.add(tool.uuid);
    toolTestResults.remove(tool.uuid);
    notifyListeners();
    try {
      final ToolTestResult result = await _client
          .testTool(tool.uuid)
          .timeout(requestTimeout);
      toolTestResults[tool.uuid] = result;
      return result;
    } on Object catch (error) {
      toolsError = error;
      return null;
    } finally {
      testingToolUuids.remove(tool.uuid);
      notifyListeners();
    }
  }

  /// Starts an OAuth sign-in for [tool]. A `connected` result means a valid
  /// token already exists (the tool list is refreshed). Returns null when the
  /// request failed ([toolsError] is set then).
  Future<ToolAuthorizeResult?> authorizeTool(ToolRegistryEntry tool) async {
    toolsError = null;
    try {
      final ToolAuthorizeResult result = await _client
          .authorizeTool(tool.uuid)
          .timeout(requestTimeout);
      if (result.isConnected) await _reloadTools();
      return result;
    } on Object catch (error) {
      toolsError = error;
      notifyListeners();
      return null;
    }
  }

  /// Forgets the stored OAuth tokens of [tool].
  Future<bool> disconnectTool(ToolRegistryEntry tool) async {
    toolsError = null;
    try {
      await _client.disconnectToolOAuth(tool.uuid).timeout(requestTimeout);
      await _reloadTools();
      return true;
    } on Object catch (error) {
      toolsError = error;
      notifyListeners();
      return false;
    }
  }

  /// Finishes a sign-in with the pasted [redirectUrl] (or [code]/[state]) and
  /// refreshes the tools. On failure [toolsError] holds the engine's reason.
  Future<bool> completeOAuth(
    String authId, {
    String? redirectUrl,
    String? code,
    String? state,
  }) async {
    toolsError = null;
    try {
      await _client
          .completeOAuth(
            authId,
            redirectUrl: redirectUrl,
            code: code,
            state: state,
          )
          .timeout(requestTimeout);
      await _reloadTools();
      return true;
    } on Object catch (error) {
      toolsError = error;
      notifyListeners();
      return false;
    }
  }

  /// Re-reads the registry; unlike [loadTools] it is never skipped because a
  /// load is already running, and it keeps [toolsError] from a failed refresh.
  Future<void> _reloadTools() async {
    try {
      tools = await _client.listTools().timeout(requestTimeout);
    } on Object catch (error) {
      toolsError = error;
    }
    // Refreshes fire without being awaited, so the page may be gone by now.
    if (!_disposed) notifyListeners();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Refreshes [tools] after the engine reported a finished sign-in.
  Future<void> refreshTools() => _reloadTools();

  Future<void> loadSkills() async {
    if (isLoadingSkills) return;
    isLoadingSkills = true;
    skillsError = null;
    notifyListeners();
    try {
      skills = await _client.listSkills().timeout(requestTimeout);
    } on Object catch (error) {
      skillsError = error;
    } finally {
      isLoadingSkills = false;
      notifyListeners();
    }
  }

  Future<bool> saveSkill({
    SkillEntry? existing,
    required SkillRequest request,
  }) async {
    skillsError = null;
    try {
      final SkillEntry saved = existing == null
          ? await _client.createSkill(request).timeout(requestTimeout)
          : await _client
                .updateSkill(uuid: existing.uuid, skill: request)
                .timeout(requestTimeout);
      skills = <SkillEntry>[
        for (final SkillEntry skill in skills)
          if (skill.uuid == saved.uuid) saved else skill,
        if (existing == null) saved,
      ];
      notifyListeners();
      return true;
    } on Object catch (error) {
      skillsError = error;
      notifyListeners();
      return false;
    }
  }

  Future<bool> deleteSkill(SkillEntry skill) async {
    skillsError = null;
    try {
      await _client.deleteSkill(skill.uuid).timeout(requestTimeout);
      skills = skills
          .where((SkillEntry item) => item.uuid != skill.uuid)
          .toList(growable: false);
      notifyListeners();
      return true;
    } on Object catch (error) {
      skillsError = error;
      notifyListeners();
      return false;
    }
  }

  String? get joiningToken => repositoryProvider()?.rest.token;

  RestEngineClient get _client {
    final RestEngineClient? client = repositoryProvider()?.rest;
    if (client == null) {
      throw StateError('The Subconscious engine is not connected.');
    }
    return client;
  }
}
