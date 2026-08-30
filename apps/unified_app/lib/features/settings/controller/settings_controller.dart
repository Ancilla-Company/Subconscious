import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/foundation.dart';

enum MainPanelDestination { utility, files, settings }

enum SettingsPage { general, models, tools, skills, about }

typedef EngineRepositoryProvider = EngineRepository? Function();

final class DashboardSettingsController extends ChangeNotifier {
  DashboardSettingsController({required this.repositoryProvider});

  static const Duration requestTimeout = Duration(seconds: 5);
  static const String settingsClient = 'flutter';

  final EngineRepositoryProvider repositoryProvider;

  MainPanelDestination destination = MainPanelDestination.utility;
  SettingsPage activePage = SettingsPage.general;
  Map<String, String> generalSettings = const <String, String>{};
  List<ModelConfiguration> modelConfigurations = const <ModelConfiguration>[];
  List<ToolRegistryEntry> tools = const <ToolRegistryEntry>[];
  bool isLoadingGeneral = false;
  bool isLoadingModels = false;
  bool isLoadingTools = false;
  Object? generalError;
  Object? modelsError;
  Object? toolsError;

  String generalValue(String key, String fallback) =>
      generalSettings[key] ?? fallback;

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

  Future<void> loadGeneralSettings() async {
    if (isLoadingGeneral) return;
    isLoadingGeneral = true;
    generalError = null;
    notifyListeners();
    try {
      final List<EngineSetting> loaded = await _client
          .getSettings(client: settingsClient)
          .timeout(requestTimeout);
      generalSettings = <String, String>{
        for (final EngineSetting setting in loaded) setting.key: setting.value,
      };
    } on Object catch (error) {
      generalError = error;
    } finally {
      isLoadingGeneral = false;
      notifyListeners();
    }
  }

  Future<void> updateGeneralSetting(String key, String value) async {
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
