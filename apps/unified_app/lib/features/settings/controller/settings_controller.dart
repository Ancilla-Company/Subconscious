import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/foundation.dart';

enum MainPanelDestination { utility, workspace, files, settings }

enum SettingsPage { general, models, tools, skills, account, about }

enum AppLightingMode { device, light, dark }

enum AppAccentTheme { device, neutral, blue, purple, green, orange, red }

enum DashboardSidebarPosition { left, right }

enum DashboardPanel { context, chat, main }

typedef EngineRepositoryProvider = EngineRepository? Function();

final class DashboardSettingsController extends ChangeNotifier {
  DashboardSettingsController({required this.repositoryProvider});

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

  String? get joiningToken => repositoryProvider()?.rest.token;

  RestEngineClient get _client {
    final RestEngineClient? client = repositoryProvider()?.rest;
    if (client == null) {
      throw StateError('The Subconscious engine is not connected.');
    }
    return client;
  }
}
