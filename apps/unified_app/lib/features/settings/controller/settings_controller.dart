import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/foundation.dart';

enum MainPanelDestination { utility, files, settings }

enum SettingsPage { general, models, tools, skills, about }

enum AppLightingMode { device, light, dark }

enum AppAccentTheme { device, blue, purple, green, orange, red }

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
        'light' => AppLightingMode.light,
        'dark' => AppLightingMode.dark,
        _ => AppLightingMode.device,
      };

  AppAccentTheme get accentTheme =>
      switch (generalSettings[colourThemeKey]?.toLowerCase()) {
        'blue' => AppAccentTheme.blue,
        'purple' => AppAccentTheme.purple,
        'green' => AppAccentTheme.green,
        'orange' => AppAccentTheme.orange,
        'red' => AppAccentTheme.red,
        _ => AppAccentTheme.device,
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
      case SettingsPage.about:
        break;
    }
  }

  Future<void> loadGeneralSettings({bool force = false}) async {
    if ((isLoadingGeneral || hasLoadedGeneralSettings) && !force) return;
    final int version = ++_generalLoadVersion;
    final Map<String, int> updateVersionsAtStart = Map<String, int>.of(
      _generalUpdateVersions,
    );
    if (force) hasLoadedGeneralSettings = false;
    isLoadingGeneral = true;
    generalError = null;
    notifyListeners();
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
      generalSettings = loadedSettings;
      hasLoadedGeneralSettings = true;
    } on Object catch (error) {
      if (version == _generalLoadVersion) generalError = error;
    } finally {
      if (version == _generalLoadVersion) {
        isLoadingGeneral = false;
        notifyListeners();
      }
    }
  }

  Future<void> updateGeneralSetting(String key, String value) async {
    final String? previousValue = generalSettings[key];
    final int version = (_generalUpdateVersions[key] ?? 0) + 1;
    _generalUpdateVersions[key] = version;
    generalSettings = <String, String>{...generalSettings, key: value};
    generalError = null;
    notifyListeners();
    try {
      await _client
          .putSettings(<EngineSetting>[
            EngineSetting(key: key, value: value, client: settingsClient),
          ])
          .timeout(requestTimeout);
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

  RestEngineClient get _client {
    final RestEngineClient? client = repositoryProvider()?.rest;
    if (client == null) {
      throw StateError('The Subconscious engine is not connected.');
    }
    return client;
  }
}
