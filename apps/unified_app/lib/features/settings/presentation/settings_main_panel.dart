import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import '../../account/account_controller.dart';
import '../../account/presentation/account_panel.dart';
import '../../connection/engine_bootstrap.dart';
import '../../connection/engine_connection_resolver.dart';
import '../../dashboard/controller/dashboard_controller.dart';
import '../controller/settings_controller.dart';

final class SettingsMainPanel extends StatelessWidget {
  const SettingsMainPanel({
    required this.controller,
    required this.dashboardController,
    required this.accountController,
    super.key,
  });

  final DashboardSettingsController controller;
  final DashboardController dashboardController;
  final AccountController accountController;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (BuildContext context, Widget? child) => Theme(
      data: appFormTheme(context),
      child: SizedBox.expand(
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surface,
          child: switch (controller.activePage) {
            SettingsPage.general => _GeneralSettingsPage(
              controller: controller,
              dashboardController: dashboardController,
            ),
            SettingsPage.models => _ModelsSettingsPage(controller: controller),
            SettingsPage.tools => _ToolsSettingsPage(controller: controller),
            SettingsPage.skills => _SkillsSettingsPage(controller: controller),
            SettingsPage.account => AccountPanel(
              controller: accountController,
              lanAccess: _supportsRemoteEngineConnection
                  ? null
                  : _LanAccessSection(token: controller.joiningToken),
            ),
            SettingsPage.about => const _AboutSettingsPage(),
          },
        ),
      ),
    ),
  );
}

final class _SettingsBody extends StatelessWidget {
  const _SettingsBody({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 750),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );
}

final class _GeneralSettingsPage extends StatelessWidget {
  const _GeneralSettingsPage({
    required this.controller,
    required this.dashboardController,
  });

  final DashboardSettingsController controller;
  final DashboardController dashboardController;

  static const List<String> _modes = <String>['Device', 'Light', 'Dark'];
  static const List<String> _colours = <String>[
    'Device',
    'Default',
    'Blue',
    'Purple',
    'Green',
    'Orange',
    'Red',
  ];
  static const List<String> _sidebarPositions = <String>['Left', 'Right'];
  static const List<String> _panelConfigurations = <String>[
    'Context · Chat · Main',
    'Context · Main · Chat',
    'Chat · Context · Main',
    'Chat · Main · Context',
    'Main · Context · Chat',
    'Main · Chat · Context',
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: dashboardController,
    builder: (BuildContext context, Widget? child) {
      final bool engineAway =
          dashboardController.connectionStatus ==
          EngineConnectionStatus.disconnected;
      return _SettingsBody(
        children: <Widget>[
          const AppSectionHeading(title: 'General Settings'),
          if (_supportsRemoteEngineConnection) ...<Widget>[
            const AppFieldLabel('Engine Connection'),
            _RemoteEngineConnectionForm(controller: dashboardController),
          ],
          // Fixed height so the form does not jump while a load runs.
          SizedBox(
            height: 4,
            child: controller.isLoadingGeneral && !engineAway
                ? const LinearProgressIndicator()
                : null,
          ),
          if (engineAway)
            _EngineStatusBanner(
              message: 'Engine not connected.',
              detail: _engineProblemText(dashboardController.error),
              onRetry: dashboardController.retryEngineStart,
            )
          else if (controller.generalError case final Object error)
            _EngineStatusBanner(
              message: 'Settings could not be loaded.',
              detail: _engineProblemText(error),
              onRetry: controller.retryGeneral,
            ),
          if (controller.hasPendingGeneral)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Changes are applied here and will be saved when the engine '
                'connects.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ..._fields(),
        ],
      );
    },
  );

  List<Widget> _fields() => <Widget>[
    AppDropdown(
      label: 'Mode',
      value: controller.modeValue,
      options: _modes,
      onChanged: (String value) => controller.updateGeneralSetting(
        DashboardSettingsController.modeKey,
        value,
      ),
    ),
    AppDropdown(
      label: 'Colour Theme',
      value: controller.colourThemeValue,
      options: _colours,
      onChanged: (String value) => controller.updateGeneralSetting(
        DashboardSettingsController.colourThemeKey,
        value,
      ),
    ),
    AppDropdown(
      label: 'Sidebar position',
      value: controller.sidebarPositionValue,
      options: _sidebarPositions,
      onChanged: (String value) => controller.updateGeneralSetting(
        DashboardSettingsController.sidebarPositionKey,
        value,
      ),
    ),
    AppDropdown(
      label: 'Panel configuration',
      value: controller.panelConfigurationValue,
      options: _panelConfigurations,
      onChanged: (String value) => controller.updateGeneralSetting(
        DashboardSettingsController.panelConfigurationKey,
        value,
      ),
    ),
    if (!_supportsRemoteEngineConnection) ...<Widget>[
      const AppFieldLabel('Data Folder'),
      const _DataDirectoryField(),
    ],
  ];
}

/// LAN joining and management for this computer's engine: the joining token
/// other devices need, plus the Windows firewall rule. Shown on the Account
/// page, below the account itself.
final class _LanAccessSection extends StatelessWidget {
  const _LanAccessSection({required this.token});

  final String? token;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Text('LAN access', style: Theme.of(context).textTheme.titleMedium),
      const AppFieldLabel('Joining Token'),
      _JoiningTokenField(token: token),
      if (_supportsWindowsFirewall) const _WindowsFirewallSettings(),
    ],
  );
}

/// Plain-language text for an engine problem; the raw error goes to the log.
String _engineProblemText(Object? error) {
  if (error == null) {
    return 'The Subconscious engine is not running. Press Retry to start it.';
  }
  debugPrint('Engine problem: $error');
  if (error is EngineStartException) return error.message;
  if (error is StateError) return error.message;
  if (error is TimeoutException) return 'The engine did not respond in time.';
  if (error is EngineApiException) {
    return 'The engine refused the request (status ${error.statusCode}).';
  }
  return 'The engine could not be reached.';
}

final class _EngineStatusBanner extends StatelessWidget {
  const _EngineStatusBanner({
    required this.message,
    required this.detail,
    required this.onRetry,
  });

  final String message;
  final String detail;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: AppBanner(
      tone: AppBannerTone.error,
      title: message,
      message: detail,
      actions: <Widget>[
        OutlinedButton(
          onPressed: () => unawaited(onRetry()),
          child: const Text('Retry'),
        ),
      ],
    ),
  );
}

final bool _supportsRemoteEngineConnection =
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);
final bool _supportsWindowsFirewall =
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
const bool _preferDevEngine = bool.fromEnvironment('SUBCONSCIOUS_ENGINE_DEV');
const MethodChannel _windowsFirewallChannel = MethodChannel(
  'company.ancilla.subconscious/windows_firewall',
);

final class _WindowsFirewallSettings extends StatefulWidget {
  const _WindowsFirewallSettings();

  @override
  State<_WindowsFirewallSettings> createState() =>
      _WindowsFirewallSettingsState();
}

final class _WindowsFirewallSettingsState
    extends State<_WindowsFirewallSettings> {
  Uri? _engineEndpoint;
  String? _error;
  bool _isLoadingEndpoint = true;
  bool _isUpdating = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshEndpoint());
  }

  Future<Uri?> _refreshEndpoint() async {
    final Uri? endpoint = await discoverLocalEngineLanEndpoint(
      preferDev: _preferDevEngine,
    );
    if (mounted) {
      setState(() {
        _engineEndpoint = endpoint;
        _isLoadingEndpoint = false;
      });
    }
    return endpoint;
  }

  Future<void> _setFirewallRule(bool enabled) async {
    setState(() {
      _error = null;
      _isUpdating = true;
    });
    try {
      final Uri? endpoint = enabled ? await _refreshEndpoint() : null;
      final int? port = endpoint?.port;
      if (enabled && endpoint == null) {
        throw StateError(
          'No running local engine was found. Start the engine before enabling LAN access.',
        );
      }
      await _windowsFirewallChannel.invokeMethod<void>(
        'setEngineRule',
        <String, Object>{'enabled': enabled, 'port': ?port},
      );
      if (!mounted) return;
      showAppSnack(
        context,
        enabled
            ? 'Windows Firewall now allows local-subnet access on TCP $port.'
            : 'The Subconscious Engine firewall rule was removed.',
      );
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.code == 'cancelled'
            ? 'The Windows administrator prompt was cancelled.'
            : error.message ?? 'Windows could not update the firewall rule.';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _isUpdating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Uri? endpoint = _engineEndpoint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const AppFieldLabel('Engine IP Address'),
        _EngineConnectionValueField(
          value: endpoint?.host,
          unavailableText: _isLoadingEndpoint
              ? 'Finding the local engine…'
              : 'No running local engine detected',
          copyMessage: 'Engine IP address copied',
          icon: FluentIcons.globe_20_regular,
        ),
        const AppFieldLabel('Engine Port'),
        _EngineConnectionValueField(
          value: endpoint?.port.toString(),
          unavailableText: _isLoadingEndpoint
              ? 'Finding the local engine…'
              : 'No running local engine detected',
          copyMessage: 'Engine port copied',
          icon: FluentIcons.plug_connected_20_regular,
        ),
        const AppFieldLabel('Mobile and LAN Access'),
        const Text(
          'Allow devices on the local subnet to reach this computer’s engine. Windows will request administrator approval. The engine must also be started with --lan.',
        ),
        const SizedBox(height: 8),
        Text(
          endpoint == null
              ? 'No firewall port is currently available.'
              : 'Rule scope: TCP ${endpoint.port} · LocalSubnet · active Private/Public profile',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (_error != null) AppFormError(error: _error!),
        const SizedBox(height: 12),
        AppButtonRow(
          children: <Widget>[
            OutlinedButton(
              onPressed: _isUpdating ? null : () => _setFirewallRule(false),
              child: const Text('Remove access'),
            ),
            FilledButton.icon(
              onPressed: _isUpdating || _isLoadingEndpoint || endpoint == null
                  ? null
                  : () => _setFirewallRule(true),
              icon: const Icon(FluentIcons.shield_20_regular, size: 16),
              label: Text(
                _isUpdating ? 'Waiting for Windows…' : 'Allow access',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

final class _EngineConnectionValueField extends StatelessWidget {
  const _EngineConnectionValueField({
    required this.value,
    required this.unavailableText,
    required this.copyMessage,
    required this.icon,
  });

  final String? value;
  final String unavailableText;
  final String copyMessage;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Expanded(
        child: AppTextField(
          key: ValueKey<String?>(value),
          initialValue: value ?? unavailableText,
          readOnly: true,
          height: 32,
          prefixIcon: Icon(icon, size: 17),
        ),
      ),
      const SizedBox(width: 8),
      _WindowsIconButton(
        tooltip: copyMessage,
        icon: FluentIcons.copy_20_regular,
        onPressed: value == null
            ? null
            : () async {
                await Clipboard.setData(ClipboardData(text: value!));
                if (context.mounted) {
                  showAppSnack(context, copyMessage);
                }
              },
      ),
    ],
  );
}

final class _RemoteEngineConnectionForm extends StatefulWidget {
  const _RemoteEngineConnectionForm({required this.controller});

  final DashboardController controller;

  @override
  State<_RemoteEngineConnectionForm> createState() =>
      _RemoteEngineConnectionFormState();
}

final class _RemoteEngineConnectionFormState
    extends State<_RemoteEngineConnectionForm> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  final TextEditingController _token = TextEditingController();
  String? _error;
  bool _isConnecting = false;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: widget.controller.explicitHost);
    _port = TextEditingController(text: widget.controller.explicitPort);
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _error = null;
      _isConnecting = true;
    });
    final String? error = await widget.controller.connectToRemoteEngine(
      host: _host.text,
      port: _port.text,
      token: _token.text,
    );
    if (!mounted) return;
    setState(() {
      _error = error;
      _isConnecting = false;
      if (error == null) _token.clear();
    });
    if (error == null) {
      showAppSnack(context, 'Connected to the engine.');
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      const Text(
        'Connect to an engine on this Wi-Fi network. Enter the address and port shown by the engine, then its joining token.',
      ),
      AppTextField(
        label: 'Engine host or IP address',
        controller: _host,
        enabled: !_isConnecting,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.next,
        hintText: '192.168.1.42',
      ),
      AppTextField(
        label: 'Engine port',
        controller: _port,
        enabled: !_isConnecting,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.next,
        hintText: 'Port shown by the engine',
      ),
      AppTextField(
        label: 'Joining token',
        controller: _token,
        enabled: !_isConnecting,
        autocorrect: false,
        enableSuggestions: false,
        obscureText: true,
        hintText: widget.controller.hasExplicitToken
            ? 'A token is already configured'
            : 'Paste the joining token',
        helperText: widget.controller.hasExplicitToken
            ? 'Leave blank to reuse the configured token for this session.'
            : 'The token is retained only for this app session.',
        onSubmitted: (_) => _isConnecting ? null : _connect(),
      ),
      if (_error != null) AppFormError(error: _error!),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton.icon(
          onPressed: _isConnecting ? null : _connect,
          icon: const Icon(FluentIcons.plug_connected_20_regular, size: 16),
          label: Text(_isConnecting ? 'Connecting…' : 'Connect'),
        ),
      ),
    ],
  );
}

final class _ModelsSettingsPage extends StatefulWidget {
  const _ModelsSettingsPage({required this.controller});

  final DashboardSettingsController controller;

  @override
  State<_ModelsSettingsPage> createState() => _ModelsSettingsPageState();
}

final class _ModelsSettingsPageState extends State<_ModelsSettingsPage> {
  String? _expandedModelId;
  bool _isCreating = false;

  void _startCreating() {
    setState(() {
      _isCreating = true;
      _expandedModelId = null;
    });
  }

  void _toggleModel(String id) {
    setState(() {
      _isCreating = false;
      _expandedModelId = _expandedModelId == id ? null : id;
    });
  }

  void _closeEditor() {
    if (!mounted) return;
    setState(() {
      _isCreating = false;
      _expandedModelId = null;
    });
  }

  Future<void> _reload() async {
    _closeEditor();
    await widget.controller.loadModelConfigurations();
  }

  @override
  Widget build(BuildContext context) {
    final bool expandedModelExists = widget.controller.modelConfigurations.any(
      (ModelConfiguration configuration) =>
          configuration.id == _expandedModelId,
    );
    final bool hasOpenEditor = _isCreating || expandedModelExists;
    return _SettingsBody(
      children: <Widget>[
        _SettingsToolbar(
          title: 'Models',
          reload: _reload,
          addLabel: 'New configuration',
          add: _startCreating,
        ),
        const Text(
          'Configurations are stored encrypted by the local engine. Saved API keys are never returned to this app.',
        ),
        if (widget.controller.isLoadingModels) const LinearProgressIndicator(),
        if (!hasOpenEditor && widget.controller.modelsError != null)
          AppFormError(error: widget.controller.modelsError!),
        if (!widget.controller.isLoadingModels &&
            widget.controller.modelConfigurations.isEmpty &&
            !_isCreating)
          const AppEmptyMessage(
            'No model configurations yet. Add one to get started.',
          ),
        if (_isCreating)
          _SettingsExpansionCard(
            title: 'New configuration',
            subtitle: 'Configure a model provider and model',
            trailing: 'unsaved',
            expanded: true,
            onToggle: _closeEditor,
            editor: _ModelEditor(
              key: const ValueKey<String>('new-model-configuration'),
              controller: widget.controller,
              onSaved: _closeEditor,
              onDeleted: _closeEditor,
              onCancel: _closeEditor,
            ),
          ),
        for (final ModelConfiguration configuration
            in widget.controller.modelConfigurations)
          _SettingsExpansionCard(
            title: configuration.alias?.trim().isNotEmpty ?? false
                ? configuration.alias!
                : configuration.model,
            subtitle: '${configuration.provider} · ${configuration.model}',
            trailing: configuration.hasApiKey ? 'API key saved' : null,
            expanded: _expandedModelId == configuration.id,
            onToggle: () => _toggleModel(configuration.id),
            editor: _expandedModelId == configuration.id
                ? _ModelEditor(
                    key: ValueKey<String>(configuration.id),
                    controller: widget.controller,
                    existing: configuration,
                    onSaved: _closeEditor,
                    onDeleted: _closeEditor,
                    onCancel: _closeEditor,
                  )
                : null,
          ),
      ],
    );
  }
}

const List<String> _modelProviders = <String>[
  'Anthropic',
  'Bedrock',
  'Cerebras',
  'Cohere',
  'Gemini',
  'Groq',
  'Hugging Face',
  'Mistral',
  'OpenAI',
  'OpenRouter',
  'xAI',
  'Azure AI Foundry',
  'DeepSeek',
  'Fireworks AI',
  'GitHub Models',
  'LiteLLM',
  'Ollama',
  'Custom',
  'LM Studio',
  'Perplexity',
  'Together AI',
];

final class _ModelEditor extends StatefulWidget {
  const _ModelEditor({
    required this.controller,
    required this.onSaved,
    required this.onDeleted,
    required this.onCancel,
    this.existing,
    super.key,
  });

  final DashboardSettingsController controller;
  final ModelConfiguration? existing;
  final VoidCallback onSaved;
  final VoidCallback onDeleted;
  final VoidCallback onCancel;

  @override
  State<_ModelEditor> createState() => _ModelEditorState();
}

const List<(String, String)> _capabilityChoices = <(String, String)>[
  ('chat', 'Chat model'),
  ('speech_to_text', 'Speech to text (dictation)'),
  ('text_to_speech', 'Text to speech (read aloud)'),
  ('realtime', 'Realtime voice'),
  ('audio_input', 'Accepts audio input'),
];

final class _ModelEditorState extends State<_ModelEditor> {
  late final TextEditingController _alias;
  late final TextEditingController _model;
  late final TextEditingController _apiKey;
  late final TextEditingController _baseUrl;
  late final TextEditingController _contextWindow;
  late String _provider;

  /// What the user says this model can do. A flag that is absent is left to
  /// the engine to infer (the 'Auto' choice).
  late Map<String, bool> _capabilities;
  String? _error;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    final ModelConfiguration? existing = widget.existing;
    _capabilities = <String, bool>{...?existing?.capabilities};
    _alias = TextEditingController(text: existing?.alias);
    _model = TextEditingController(text: existing?.model);
    _apiKey = TextEditingController();
    _baseUrl = TextEditingController(text: existing?.baseUrl);
    _contextWindow = TextEditingController(
      text: existing?.contextWindow?.toString(),
    );
    _provider = existing?.provider ?? 'OpenAI';
  }

  @override
  void dispose() {
    _alias.dispose();
    _model.dispose();
    _apiKey.dispose();
    _baseUrl.dispose();
    _contextWindow.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String contextText = _contextWindow.text.trim();
    final int? parsedContext = contextText.isEmpty
        ? null
        : int.tryParse(contextText);
    if (_model.text.trim().isEmpty ||
        (contextText.isNotEmpty &&
            (parsedContext == null || parsedContext <= 0))) {
      setState(
        () => _error = 'Model is required and context window must be positive.',
      );
      return;
    }
    setState(() {
      _error = null;
      _isSubmitting = true;
    });
    final bool saved = await widget.controller.saveModelConfiguration(
      existing: widget.existing,
      request: ModelConfigurationRequest(
        provider: _provider,
        model: _model.text.trim(),
        alias: _nullIfEmpty(_alias.text),
        baseUrl: _nullIfEmpty(_baseUrl.text),
        contextWindow: parsedContext,
        apiKey: _nullIfEmpty(_apiKey.text),
        clearApiKey: false,
        capabilities: Map<String, bool>.unmodifiable(_capabilities),
      ),
    );
    if (!mounted) return;
    if (saved) {
      widget.onSaved();
      return;
    }
    setState(() {
      _error = '${widget.controller.modelsError}';
      _isSubmitting = false;
    });
  }

  Future<void> _delete() async {
    final ModelConfiguration? existing = widget.existing;
    if (existing == null) return;
    setState(() {
      _error = null;
      _isSubmitting = true;
    });
    final bool deleted = await widget.controller.deleteModelConfiguration(
      existing,
    );
    if (!mounted) return;
    if (deleted) {
      widget.onDeleted();
      return;
    }
    setState(() {
      _error = '${widget.controller.modelsError}';
      _isSubmitting = false;
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      AppTextField(
        label: 'Alias',
        controller: _alias,
        enabled: !_isSubmitting,
        hintText: 'Configuration name',
      ),
      AppDropdown(
        label: 'Provider',
        value: _modelProviders.contains(_provider) ? _provider : 'Custom',
        options: _modelProviders,
        enabled: !_isSubmitting,
        onChanged: (String value) => setState(() => _provider = value),
      ),
      AppTextField(
        label: 'Model',
        controller: _model,
        enabled: !_isSubmitting,
        hintText: 'Model name',
      ),
      AppTextField(
        label: 'API Key',
        controller: _apiKey,
        enabled: !_isSubmitting,
        obscureText: true,
        helperText: widget.existing?.hasApiKey ?? false
            ? 'Leave blank to keep the saved API key.'
            : 'Stored encrypted by the engine.',
      ),
      AppTextField(
        label: 'Base URL',
        controller: _baseUrl,
        enabled: !_isSubmitting,
        hintText: 'Optional endpoint URL',
      ),
      AppTextField(
        label: 'Context Window (tokens)',
        controller: _contextWindow,
        enabled: !_isSubmitting,
        keyboardType: TextInputType.number,
        hintText: 'Optional token limit',
      ),
      const AppFieldLabel('Capabilities'),
      const Text(
        'Auto lets the engine decide from what it knows about the model. '
        'Set a value only to correct it. Features such as dictation, read '
        'aloud and realtime voice appear when a model supports them.',
      ),
      for (final (String flag, String label) in _capabilityChoices)
        AppDropdown(
          label: label,
          value: switch (_capabilities[flag]) {
            true => 'Yes',
            false => 'No',
            null => 'Auto',
          },
          options: const <String>['Auto', 'Yes', 'No'],
          enabled: !_isSubmitting,
          onChanged: (String value) => setState(() {
            if (value == 'Auto') {
              _capabilities.remove(flag);
            } else {
              _capabilities[flag] = value == 'Yes';
            }
          }),
        ),
      if (_error != null) AppFormError(error: _error!),
      const SizedBox(height: 18),
      AppButtonRow(
        children: <Widget>[
          if (widget.existing != null)
            TextButton(
              onPressed: _isSubmitting ? null : _delete,
              child: const Text('Delete'),
            ),
          TextButton(
            onPressed: _isSubmitting ? null : widget.onCancel,
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _isSubmitting ? null : _save,
            child: Text(_isSubmitting ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    ],
  );
}

final class _ToolsSettingsPage extends StatefulWidget {
  const _ToolsSettingsPage({required this.controller});

  final DashboardSettingsController controller;

  @override
  State<_ToolsSettingsPage> createState() => _ToolsSettingsPageState();
}

final class _ToolsSettingsPageState extends State<_ToolsSettingsPage> {
  String? _expandedToolUuid;
  bool _isCreating = false;

  void _startCreating() {
    setState(() {
      _isCreating = true;
      _expandedToolUuid = null;
    });
  }

  void _toggleTool(String uuid) {
    setState(() {
      _isCreating = false;
      _expandedToolUuid = _expandedToolUuid == uuid ? null : uuid;
    });
  }

  void _closeEditor() {
    if (!mounted) return;
    setState(() {
      _isCreating = false;
      _expandedToolUuid = null;
    });
  }

  Future<void> _reload() async {
    _closeEditor();
    await widget.controller.loadTools();
  }

  @override
  Widget build(BuildContext context) {
    final bool expandedToolExists = widget.controller.tools.any(
      (ToolRegistryEntry tool) => tool.uuid == _expandedToolUuid,
    );
    final bool hasOpenEditor = _isCreating || expandedToolExists;
    return _SettingsBody(
      children: <Widget>[
        _SettingsToolbar(
          title: 'Tools',
          reload: _reload,
          addLabel: 'New tool',
          add: _startCreating,
        ),
        const Text(
          'Register MCP servers and command line tools the assistant can use. Credentials are stored encrypted and are never returned to this app.',
        ),
        if (widget.controller.isLoadingTools) const LinearProgressIndicator(),
        if (!hasOpenEditor && widget.controller.toolsError != null)
          AppFormError(error: widget.controller.toolsError!),
        if (!widget.controller.isLoadingTools &&
            widget.controller.tools.isEmpty &&
            !_isCreating)
          const AppEmptyMessage(
            'No configured tools yet. Add one to make it available in policies.',
          ),
        if (_isCreating)
          _SettingsExpansionCard(
            title: 'New tool',
            subtitle: 'Register an MCP server or command line tool',
            trailing: 'unsaved',
            expanded: true,
            onToggle: _closeEditor,
            editor: _ToolEditor(
              key: const ValueKey<String>('new-tool'),
              controller: widget.controller,
              onSaved: _closeEditor,
              onDeleted: _closeEditor,
              onCancel: _closeEditor,
            ),
          ),
        for (final ToolRegistryEntry tool in widget.controller.tools)
          _SettingsExpansionCard(
            title: tool.alias?.trim().isNotEmpty ?? false
                ? tool.alias!
                : tool.name,
            subtitle: <String>[
              _toolTypeLabel(tool.toolType),
              if (_toolLocation(tool) != null) _toolLocation(tool)!,
            ].join(' · '),
            trailing: tool.authType == 'oauth'
                ? (tool.oauthConnected ?? false)
                      ? 'Connected'
                      : 'Not connected'
                : tool.hasAuthConfig
                ? 'Credentials saved'
                : tool.status,
            expanded: _expandedToolUuid == tool.uuid,
            onToggle: () => _toggleTool(tool.uuid),
            editor: _expandedToolUuid == tool.uuid
                ? _ToolEditor(
                    key: ValueKey<String>(tool.uuid),
                    controller: widget.controller,
                    existing: tool,
                    onSaved: _closeEditor,
                    onDeleted: _closeEditor,
                    onCancel: _closeEditor,
                  )
                : null,
          ),
      ],
    );
  }
}

final class _SettingsExpansionCard extends StatelessWidget {
  const _SettingsExpansionCard({
    required this.title,
    required this.subtitle,
    required this.expanded,
    required this.onToggle,
    this.trailing,
    this.editor,
  });

  final String title;
  final String subtitle;
  final String? trailing;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget? editor;

  @override
  Widget build(BuildContext context) => AppSectionCard(
    title: title,
    subtitle: subtitle,
    margin: const EdgeInsets.only(top: 10),
    expanded: expanded && editor != null,
    onToggle: onToggle,
    trailing: trailing == null
        ? null
        : ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              trailing!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
    child: editor ?? const SizedBox.shrink(),
  );
}

const String _mcpToolLabel = 'MCP server';
const String _cliToolLabel = 'Command line tool';
const String _stdioConnectionLabel = 'Command (stdio)';
const String _httpConnectionLabel = 'HTTP URL';

String _toolTypeLabel(String toolType) => switch (toolType) {
  'mcp' => _mcpToolLabel,
  'cli' => _cliToolLabel,
  'script' => 'Script (legacy)',
  'api' => 'API (legacy)',
  _ => toolType,
};

String? _toolLocation(ToolRegistryEntry tool) {
  final String? value = switch (tool.toolType) {
    'script' => tool.scriptPath,
    'cli' => tool.command,
    'mcp' =>
      (tool.command?.trim().isNotEmpty ?? false)
          ? tool.command
          : tool.endpointUrl,
    _ => tool.endpointUrl,
  };
  return value == null || value.trim().isEmpty ? null : value;
}

final class _ToolEditor extends StatefulWidget {
  const _ToolEditor({
    required this.controller,
    required this.onSaved,
    required this.onDeleted,
    required this.onCancel,
    this.existing,
    super.key,
  });

  final DashboardSettingsController controller;
  final ToolRegistryEntry? existing;
  final VoidCallback onSaved;
  final VoidCallback onDeleted;
  final VoidCallback onCancel;

  @override
  State<_ToolEditor> createState() => _ToolEditorState();
}

final class _ToolEditorState extends State<_ToolEditor> {
  static const List<String> _scriptLanguages = <String>[
    'python',
    'javascript',
    'typescript',
  ];
  static const List<String> _authenticationTypes = <String>['None', 'API key'];
  static const List<String> _mcpAuthenticationTypes = <String>[
    'None',
    'API key',
    'OAuth',
  ];
  static const List<String> _connectionLabels = <String>[
    _stdioConnectionLabel,
    _httpConnectionLabel,
  ];

  late final TextEditingController _alias;
  late final TextEditingController _description;
  late final TextEditingController _scriptPath;
  late final TextEditingController _endpointUrl;
  late final TextEditingController _authConfig;
  late final TextEditingController _oauthClientId;
  late final TextEditingController _oauthClientSecret;
  late final TextEditingController _oauthScopes;
  final TextEditingController _oauthPaste = TextEditingController();
  late final TextEditingController _command;
  late final TextEditingController _args;
  late final TextEditingController _cwd;
  late final TextEditingController _env;
  late String _toolType;
  late bool _isHttp;
  late String _scriptLanguage;
  late String _authType;
  String? _error;
  bool _isSubmitting = false;

  /// The sign-in started by Connect that is waiting for the pasted address.
  String? _pendingAuthId;
  bool _isConnecting = false;

  /// Legacy rows keep their own type in the dropdown so nothing is lost.
  List<String> get _toolTypes => <String>[
    'mcp',
    'cli',
    if (widget.existing?.toolType == 'script' ||
        widget.existing?.toolType == 'api')
      widget.existing!.toolType,
  ];

  @override
  void initState() {
    super.initState();
    final ToolRegistryEntry? existing = widget.existing;
    _alias = TextEditingController(text: existing?.alias ?? existing?.name);
    _description = TextEditingController(text: existing?.description);
    _scriptPath = TextEditingController(text: existing?.scriptPath);
    _endpointUrl = TextEditingController(text: existing?.endpointUrl);
    _authConfig = TextEditingController();
    _oauthClientId = TextEditingController(text: existing?.oauthClientId);
    // Write-only: the saved secret is never shown or prefilled.
    _oauthClientSecret = TextEditingController();
    _oauthScopes = TextEditingController(text: existing?.oauthScopes);
    _oauthPaste.addListener(_onPasteChanged);
    _command = TextEditingController(text: existing?.command);
    _args = TextEditingController(text: existing?.args.join('\n'));
    _cwd = TextEditingController(text: existing?.cwd);
    _env = TextEditingController(
      text: existing?.env.entries
          .map(
            (MapEntry<String, String> entry) => '${entry.key}=${entry.value}',
          )
          .join('\n'),
    );
    _toolType =
        <String>['mcp', 'cli', 'script', 'api'].contains(existing?.toolType)
        ? existing!.toolType
        : 'mcp';
    _isHttp =
        existing != null &&
        (existing.transport == 'http' ||
            ((existing.endpointUrl?.trim().isNotEmpty ?? false) &&
                !(existing.command?.trim().isNotEmpty ?? false)));
    _scriptLanguage = _scriptLanguages.contains(existing?.scriptLanguage)
        ? existing!.scriptLanguage!
        : 'python';
    _authType = existing?.authType?.toLowerCase() == 'oauth'
        ? 'oauth'
        : existing?.authType?.toLowerCase() == 'api_key' ||
              (existing?.hasAuthConfig ?? false)
        ? 'api_key'
        : 'None';
  }

  void _onPasteChanged() => setState(() {});

  @override
  void dispose() {
    _alias.dispose();
    _description.dispose();
    _scriptPath.dispose();
    _endpointUrl.dispose();
    _authConfig.dispose();
    _oauthClientId.dispose();
    _oauthClientSecret.dispose();
    _oauthScopes.dispose();
    _oauthPaste.removeListener(_onPasteChanged);
    _oauthPaste.dispose();
    _command.dispose();
    _args.dispose();
    _cwd.dispose();
    _env.dispose();
    super.dispose();
  }

  bool get _isScript => _toolType == 'script';
  bool get _isCli => _toolType == 'cli';
  bool get _isStdio => _toolType == 'mcp' && !_isHttp;
  bool get _isEndpoint => _toolType == 'api' || (_toolType == 'mcp' && _isHttp);
  bool get _hasCommand => _isCli || _isStdio;

  /// OAuth only exists for MCP servers reached over HTTP.
  bool get _isOAuth => _toolType == 'mcp' && _isHttp && _authType == 'oauth';

  String get _authenticationLabel => switch (_authType) {
    'api_key' => 'API key',
    'oauth' => 'OAuth',
    _ => 'None',
  };

  List<String> _parseArgs() => <String>[
    for (final String line in _args.text.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  /// Null when a line is not `KEY=value`.
  Map<String, String>? _parseEnv() {
    final Map<String, String> env = <String, String>{};
    for (final String raw in _env.text.split('\n')) {
      final String line = raw.trim();
      if (line.isEmpty) continue;
      final int separator = line.indexOf('=');
      if (separator <= 0) return null;
      env[line.substring(0, separator).trim()] = line.substring(separator + 1);
    }
    return env;
  }

  String? _validate() {
    if (_alias.text.trim().isEmpty) {
      return _isScript || _toolType == 'api'
          ? 'Alias and the selected tool location are required.'
          : 'Alias is required.';
    }
    if (_isScript && _scriptPath.text.trim().isEmpty) {
      return 'Alias and the selected tool location are required.';
    }
    if (_isEndpoint) {
      final String url = _endpointUrl.text.trim();
      if (url.isEmpty) {
        return _toolType == 'api'
            ? 'Alias and the selected tool location are required.'
            : 'Endpoint URL is required.';
      }
      if (_toolType == 'mcp') {
        final Uri? uri = Uri.tryParse(url);
        if (uri == null ||
            !(uri.scheme == 'http' || uri.scheme == 'https') ||
            uri.host.isEmpty) {
          return _isOAuth
              ? 'OAuth needs an endpoint URL starting with http:// or https://.'
              : 'Endpoint URL must start with http:// or https://.';
        }
      }
    }
    if (_hasCommand && _command.text.trim().isEmpty) {
      return 'Command is required.';
    }
    if (_isCli && _description.text.trim().isEmpty) {
      return 'Description is required for command line tools.';
    }
    if (_isStdio && _parseEnv() == null) {
      return 'Environment lines must look like KEY=value.';
    }
    return null;
  }

  Future<void> _save() async {
    final String? problem = _validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _error = null;
      _isSubmitting = true;
    });
    final ToolRegistryEntry? existing = widget.existing;
    final bool hadCommand = existing?.command?.trim().isNotEmpty ?? false;
    final bool hadEndpoint = existing?.endpointUrl?.trim().isNotEmpty ?? false;
    final bool hadClientId =
        existing?.oauthClientId?.trim().isNotEmpty ?? false;
    final bool saved = await widget.controller.saveTool(
      existing: existing,
      request: ToolRegistryRequest(
        alias: _alias.text.trim(),
        description: _nullIfEmpty(_description.text),
        toolType: _toolType,
        scriptPath: _isScript ? _scriptPath.text.trim() : null,
        scriptLanguage: _isScript ? _scriptLanguage : null,
        endpointUrl: _isEndpoint ? _endpointUrl.text.trim() : null,
        clearEndpointUrl: !_isEndpoint && hadEndpoint,
        authType: _isOAuth
            ? 'oauth'
            : _isEndpoint && _authType == 'api_key'
            ? 'api_key'
            : null,
        authConfigJson: _isEndpoint && _authType == 'api_key'
            ? _nullIfEmpty(_authConfig.text)
            : null,
        clearAuthConfig: !_isEndpoint || _authType != 'api_key',
        oauthClientId: _isOAuth
            ? _oauthValue(_oauthClientId, hadClientId)
            : null,
        oauthClientSecret: _isOAuth
            ? _nullIfEmpty(_oauthClientSecret.text)
            : null,
        // Dropping a custom client id back to automatic registration also
        // drops the secret that belonged to it.
        clearOauthClientSecret:
            _isOAuth &&
            hadClientId &&
            _oauthClientId.text.trim().isEmpty &&
            _oauthClientSecret.text.trim().isEmpty,
        oauthScopes: _isOAuth
            ? _oauthValue(
                _oauthScopes,
                existing?.oauthScopes?.trim().isNotEmpty ?? false,
              )
            : null,
        command: _hasCommand ? _command.text.trim() : null,
        args: _hasCommand ? _parseArgs() : null,
        env: _isStdio ? _parseEnv() : null,
        cwd: _hasCommand ? _nullIfEmpty(_cwd.text) : null,
        clearCommand: !_hasCommand && hadCommand,
        status: existing?.status,
      ),
    );
    if (!mounted) return;
    if (saved) {
      widget.onSaved();
      return;
    }
    setState(() {
      _error = '${widget.controller.toolsError}';
      _isSubmitting = false;
    });
  }

  Future<void> _delete() async {
    final ToolRegistryEntry? existing = widget.existing;
    if (existing == null) return;
    setState(() {
      _error = null;
      _isSubmitting = true;
    });
    final bool deleted = await widget.controller.deleteTool(existing);
    if (!mounted) return;
    if (deleted) {
      widget.onDeleted();
      return;
    }
    setState(() {
      _error = '${widget.controller.toolsError}';
      _isSubmitting = false;
    });
  }

  /// The trimmed text, or null to leave the saved value alone. An empty string
  /// is sent only to clear a value that was saved before.
  String? _oauthValue(TextEditingController field, bool hadValue) {
    final String? value = _nullIfEmpty(field.text);
    return value ?? (hadValue ? '' : null);
  }

  String _describeToolError(Object error) =>
      error is EngineApiException ? error.engineMessage ?? '$error' : '$error';

  /// Starts the browser sign-in; the address the browser ends on can be pasted
  /// back below when this device cannot be reached by the redirect.
  Future<void> _connect() async {
    final ToolRegistryEntry? existing = widget.existing;
    if (existing == null) return;
    setState(() {
      _error = null;
      _isConnecting = true;
    });
    final ToolAuthorizeResult? result = await widget.controller.authorizeTool(
      existing,
    );
    if (!mounted) return;
    if (result == null) {
      setState(() {
        _error = _describeToolError(widget.controller.toolsError!);
        _isConnecting = false;
      });
      return;
    }
    final String? url = result.url;
    final String? authId = result.authId;
    String? problem;
    if (!result.isConnected && url != null && authId != null) {
      _oauthPaste.clear();
      final Uri? uri = Uri.tryParse(url);
      if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
        problem = 'The sign-in address is not a web link.';
      } else {
        try {
          if (!await widget.controller.urlLauncher(uri)) {
            problem =
                'Could not open the browser. Open this address '
                'yourself: $url';
          }
        } on Object catch (error) {
          debugPrint('Opening the OAuth sign-in page failed: $error');
          problem = 'Could not open the browser: $error';
        }
      }
    } else if (!result.isConnected) {
      problem = 'The engine did not return a sign-in address.';
    }
    if (!mounted) return;
    setState(() {
      _pendingAuthId = result.isConnected ? null : authId;
      _error = problem;
      _isConnecting = false;
    });
  }

  Future<void> _submitPaste() async {
    final String? authId = _pendingAuthId;
    final OAuthPaste? parsed = parseOAuthPaste(_oauthPaste.text);
    if (authId == null || parsed == null) return;
    setState(() {
      _error = null;
      _isConnecting = true;
    });
    final bool done = await widget.controller.completeOAuth(
      authId,
      redirectUrl: parsed.redirectUrl,
      code: parsed.code,
      state: parsed.state,
    );
    if (!mounted) return;
    setState(() {
      _isConnecting = false;
      if (done) {
        _pendingAuthId = null;
        _oauthPaste.clear();
      } else {
        _error = _describeToolError(widget.controller.toolsError!);
      }
    });
  }

  Future<void> _disconnect() async {
    final ToolRegistryEntry? existing = widget.existing;
    if (existing == null) return;
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => AppDialog(
        title: 'Disconnect',
        content: Text(
          'Forget the saved sign-in for ${_toolTitle(existing)}? '
          'You will need to sign in again to use it.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _error = null;
      _isConnecting = true;
    });
    final bool done = await widget.controller.disconnectTool(existing);
    if (!mounted) return;
    setState(() {
      _isConnecting = false;
      if (done) {
        _pendingAuthId = null;
      } else {
        _error = _describeToolError(widget.controller.toolsError!);
      }
    });
  }

  String _toolTitle(ToolRegistryEntry tool) =>
      tool.alias?.trim().isNotEmpty ?? false ? tool.alias! : tool.name;

  List<Widget> _oauthFields(ToolRegistryEntry? existing) {
    // Connecting needs a saved tool whose registry row already says OAuth.
    final bool canConnect = existing != null && existing.authType == 'oauth';
    final bool connected = existing?.oauthConnected ?? false;
    final bool showPaste = _pendingAuthId != null && !connected;
    final bool busy = _isSubmitting || _isConnecting;
    return <Widget>[
      AppTextField(
        label: 'Client ID (optional)',
        controller: _oauthClientId,
        enabled: !_isSubmitting,
        hintText: 'Leave blank to register automatically',
      ),
      AppTextField(
        label: 'Client secret (optional)',
        controller: _oauthClientSecret,
        enabled: !_isSubmitting,
        obscureText: true,
        enableSuggestions: false,
        autocorrect: false,
        helperText: 'Stored encrypted. Leave blank to keep the saved secret.',
      ),
      AppTextField(
        label: 'Scopes (optional)',
        controller: _oauthScopes,
        enabled: !_isSubmitting,
        hintText: 'Space separated',
      ),
      if (canConnect) ...<Widget>[
        const AppFieldLabel('Sign-in'),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                connected ? 'Connected' : 'Not connected',
                key: const ValueKey<String>('oauth-status'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Wrap(
              spacing: 8,
              children: <Widget>[
                if (connected)
                  TextButton(
                    onPressed: busy ? null : _disconnect,
                    child: const Text('Disconnect'),
                  ),
                FilledButton(
                  onPressed: busy ? null : _connect,
                  child: Text(_isConnecting ? 'Connecting…' : 'Connect'),
                ),
              ],
            ),
          ],
        ),
        if (showPaste) ...<Widget>[
          const AppFieldLabel('Paste the address or code'),
          Text(
            'Finish signing in in your browser. If you land on a page that '
            'cannot be reached, copy its address and paste it here.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          AppTextField(
            controller: _oauthPaste,
            enabled: !busy,
            onSubmitted: (_) => unawaited(_submitPaste()),
            hintText: 'Paste the address or code',
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: busy || _oauthPaste.text.trim().isEmpty
                  ? null
                  : _submitPaste,
              child: const Text('Submit'),
            ),
          ),
        ],
      ],
    ];
  }

  Future<void> _test() async {
    final ToolRegistryEntry? existing = widget.existing;
    if (existing == null) return;
    setState(() => _error = null);
    final ToolTestResult? result = await widget.controller.testTool(existing);
    if (!mounted) return;
    if (result == null) {
      setState(() => _error = '${widget.controller.toolsError}');
    }
  }

  List<Widget> _commandFields({required bool withEnvironment}) => <Widget>[
    AppTextField(
      label: 'Command',
      controller: _command,
      enabled: !_isSubmitting,
      hintText: 'Executable, e.g. npx',
    ),
    AppTextField(
      label: 'Arguments (one per line)',
      controller: _args,
      enabled: !_isSubmitting,
      minLines: 2,
      maxLines: 6,
      hintText: 'One argument per line',
    ),
    AppTextField(
      label: 'Working directory (optional)',
      controller: _cwd,
      enabled: !_isSubmitting,
      hintText: 'Defaults to the engine',
    ),
    if (withEnvironment) ...<Widget>[
      AppTextField(
        label: 'Environment (optional)',
        controller: _env,
        enabled: !_isSubmitting,
        minLines: 2,
        maxLines: 6,
        hintText: 'KEY=value, one per line',
        helperText: 'Not encrypted - do not put secrets here.',
      ),
    ],
  ];

  Widget _testResult(ToolTestResult result) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    if (result.needsAuth) {
      return const AppFormError(error: 'Sign-in required');
    }
    if (!result.ok) {
      return AppFormError(error: result.error ?? 'The connection test failed.');
    }
    final int count = result.tools.length;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Connected - $count ${count == 1 ? 'tool' : 'tools'}',
            style: textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          for (final ToolTestTool tool in result.tools)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Tooltip(
                      message: tool.description,
                      child: Text(
                        tool.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(tool.operation, style: textTheme.labelSmall),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ToolRegistryEntry? existing = widget.existing;
    final bool isTesting =
        existing != null &&
        widget.controller.testingToolUuids.contains(existing.uuid);
    final bool busy = _isSubmitting || isTesting;
    final ToolTestResult? testResult = existing == null
        ? null
        : widget.controller.toolTestResults[existing.uuid];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppTextField(
          label: 'Alias',
          controller: _alias,
          enabled: !_isSubmitting,
          hintText: 'Tool name',
        ),
        AppDropdown(
          label: 'Tool Type',
          value: _toolTypeLabel(_toolType),
          options: <String>[
            for (final String type in _toolTypes) _toolTypeLabel(type),
          ],
          enabled: !_isSubmitting,
          onChanged: (String value) => setState(
            () => _toolType = _toolTypes.firstWhere(
              (String type) => _toolTypeLabel(type) == value,
              orElse: () => _toolType,
            ),
          ),
        ),
        if (_toolType == 'mcp')
          AppDropdown(
            label: 'Connection',
            value: _isHttp ? _httpConnectionLabel : _stdioConnectionLabel,
            options: _connectionLabels,
            enabled: !_isSubmitting,
            onChanged: (String value) =>
                setState(() => _isHttp = value == _httpConnectionLabel),
          ),
        if (_hasCommand) ..._commandFields(withEnvironment: _isStdio),
        if (_isScript) ...<Widget>[
          AppDropdown(
            label: 'Language',
            value: _scriptLanguage,
            options: _scriptLanguages,
            enabled: !_isSubmitting,
            onChanged: (String value) =>
                setState(() => _scriptLanguage = value),
          ),
          AppTextField(
            label: 'Script Path',
            controller: _scriptPath,
            enabled: !_isSubmitting,
            hintText: 'Path to the script',
          ),
        ],
        if (_isEndpoint) ...<Widget>[
          AppTextField(
            label: 'Endpoint URL',
            controller: _endpointUrl,
            enabled: !_isSubmitting,
            hintText: 'https://',
          ),
          AppDropdown(
            label: 'Authentication',
            value: _toolType == 'mcp' || _authType != 'oauth'
                ? _authenticationLabel
                : 'None',
            options: _toolType == 'mcp'
                ? _mcpAuthenticationTypes
                : _authenticationTypes,
            enabled: !_isSubmitting,
            onChanged: (String value) => setState(
              () => _authType = switch (value) {
                'API key' => 'api_key',
                'OAuth' => 'oauth',
                _ => 'None',
              },
            ),
          ),
          if (_isOAuth) ..._oauthFields(existing),
          if (_authType == 'api_key') ...<Widget>[
            AppTextField(
              label: 'API key header (JSON)',
              controller: _authConfig,
              enabled: !_isSubmitting,
              minLines: 2,
              maxLines: 4,
              hintText: '{"x-api-key":"your-api-key"}',
              helperText: existing?.hasAuthConfig ?? false
                  ? 'Leave blank to keep the saved credentials.'
                  : 'Stored encrypted by the engine.',
            ),
          ],
        ],
        AppTextField(
          label: 'Description',
          controller: _description,
          enabled: !_isSubmitting,
          minLines: 2,
          maxLines: 4,
          hintText: _isCli
              ? 'Tell the model what this tool does and how to call it'
              : 'Optional description',
        ),
        if (_error != null) AppFormError(error: _error!),
        const SizedBox(height: 18),
        AppButtonRow(
          children: <Widget>[
            if (existing != null)
              OutlinedButton(
                onPressed: busy ? null : _test,
                child: Text(isTesting ? 'Testing…' : 'Test'),
              ),
            if (existing != null)
              TextButton(
                onPressed: busy ? null : _delete,
                child: const Text('Delete'),
              ),
            TextButton(
              onPressed: busy ? null : widget.onCancel,
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: busy ? null : _save,
              child: Text(_isSubmitting ? 'Saving…' : 'Save'),
            ),
          ],
        ),
        if (testResult != null) _testResult(testResult),
      ],
    );
  }
}

final class _SkillsSettingsPage extends StatefulWidget {
  const _SkillsSettingsPage({required this.controller});

  final DashboardSettingsController controller;

  @override
  State<_SkillsSettingsPage> createState() => _SkillsSettingsPageState();
}

final class _SkillsSettingsPageState extends State<_SkillsSettingsPage> {
  String? _expandedSkillUuid;
  bool _isCreating = false;

  void _startCreating() {
    setState(() {
      _isCreating = true;
      _expandedSkillUuid = null;
    });
  }

  void _toggleSkill(String uuid) {
    setState(() {
      _isCreating = false;
      _expandedSkillUuid = _expandedSkillUuid == uuid ? null : uuid;
    });
  }

  void _closeEditor() {
    if (!mounted) return;
    setState(() {
      _isCreating = false;
      _expandedSkillUuid = null;
    });
  }

  Future<void> _reload() async {
    _closeEditor();
    await widget.controller.loadSkills();
  }

  static String _subtitle(SkillEntry skill) {
    final bool isText = skill.sourceType == 'text';
    final String detail = isText
        ? (skill.instructions ?? '').trim().replaceAll(RegExp(r'\s+'), ' ')
        : (skill.source ?? '');
    return <String>[
      isText ? 'Text' : 'Folder',
      if (detail.isNotEmpty) detail,
    ].join(' · ');
  }

  static String? _trailing(SkillEntry skill) {
    final String? error = skill.valid
        ? null
        : ((skill.error?.trim().isNotEmpty ?? false)
              ? skill.error!.trim()
              : 'invalid');
    return switch ((skill.enabled, error)) {
      (true, null) => null,
      (false, null) => 'disabled',
      (true, final String message) => message,
      (false, final String message) => 'disabled · $message',
    };
  }

  @override
  Widget build(BuildContext context) {
    final bool expandedSkillExists = widget.controller.skills.any(
      (SkillEntry skill) => skill.uuid == _expandedSkillUuid,
    );
    final bool hasOpenEditor = _isCreating || expandedSkillExists;
    return _SettingsBody(
      children: <Widget>[
        _SettingsToolbar(
          title: 'Skills',
          reload: _reload,
          addLabel: 'New skill',
          add: _startCreating,
        ),
        const Text(
          'Skills are instructions the assistant can load when relevant. The engine lists enabled skills to the model and reads the full SKILL.md on demand.',
        ),
        if (widget.controller.isLoadingSkills) const LinearProgressIndicator(),
        if (!hasOpenEditor && widget.controller.skillsError != null)
          AppFormError(error: widget.controller.skillsError!),
        if (!widget.controller.isLoadingSkills &&
            widget.controller.skills.isEmpty &&
            !_isCreating)
          const AppEmptyMessage(
            'No skills yet. Add a folder with a SKILL.md or write instructions directly.',
          ),
        if (_isCreating)
          _SettingsExpansionCard(
            title: 'New skill',
            subtitle: 'Add a skill folder or write instructions',
            trailing: 'unsaved',
            expanded: true,
            onToggle: _closeEditor,
            editor: _SkillEditor(
              key: const ValueKey<String>('new-skill'),
              controller: widget.controller,
              onSaved: _closeEditor,
              onDeleted: _closeEditor,
              onCancel: _closeEditor,
            ),
          ),
        for (final SkillEntry skill in widget.controller.skills)
          _SettingsExpansionCard(
            title: skill.alias?.trim().isNotEmpty ?? false
                ? skill.alias!
                : skill.name,
            subtitle: _subtitle(skill),
            trailing: _trailing(skill),
            expanded: _expandedSkillUuid == skill.uuid,
            onToggle: () => _toggleSkill(skill.uuid),
            editor: _expandedSkillUuid == skill.uuid
                ? _SkillEditor(
                    key: ValueKey<String>(skill.uuid),
                    controller: widget.controller,
                    existing: skill,
                    onSaved: _closeEditor,
                    onDeleted: _closeEditor,
                    onCancel: _closeEditor,
                  )
                : null,
          ),
      ],
    );
  }
}

final class _SkillEditor extends StatefulWidget {
  const _SkillEditor({
    required this.controller,
    required this.onSaved,
    required this.onDeleted,
    required this.onCancel,
    this.existing,
    super.key,
  });

  final DashboardSettingsController controller;
  final SkillEntry? existing;
  final VoidCallback onSaved;
  final VoidCallback onDeleted;
  final VoidCallback onCancel;

  @override
  State<_SkillEditor> createState() => _SkillEditorState();
}

final class _SkillEditorState extends State<_SkillEditor> {
  static const List<String> _sourceTypeLabels = <String>['Folder', 'Text'];

  late final TextEditingController _name;
  late final TextEditingController _alias;
  late final TextEditingController _description;
  late final TextEditingController _source;
  late final TextEditingController _instructions;
  late bool _isText;
  late bool _enabled;
  String? _error;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    final SkillEntry? existing = widget.existing;
    _name = TextEditingController(text: existing?.name);
    _alias = TextEditingController(text: existing?.alias);
    _description = TextEditingController(text: existing?.description);
    _source = TextEditingController(text: existing?.source);
    _instructions = TextEditingController(text: existing?.instructions);
    _isText = existing?.sourceType == 'text';
    _enabled = existing?.enabled ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _alias.dispose();
    _description.dispose();
    _source.dispose();
    _instructions.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String? problem = _name.text.trim().isEmpty
        ? 'Name is required.'
        : _isText
        ? (_instructions.text.trim().isEmpty
              ? 'Instructions are required.'
              : null)
        : (_source.text.trim().isEmpty ? 'Folder path is required.' : null);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _error = null;
      _isSubmitting = true;
    });
    final bool saved = await widget.controller.saveSkill(
      existing: widget.existing,
      request: SkillRequest(
        name: _name.text.trim(),
        alias: _nullIfEmpty(_alias.text),
        description: _nullIfEmpty(_description.text),
        sourceType: _isText ? 'text' : 'folder',
        source: _isText ? null : _source.text.trim(),
        instructions: _isText ? _instructions.text.trim() : null,
        enabled: _enabled,
      ),
    );
    if (!mounted) return;
    if (saved) {
      widget.onSaved();
      return;
    }
    setState(() {
      _error = '${widget.controller.skillsError}';
      _isSubmitting = false;
    });
  }

  Future<void> _delete() async {
    final SkillEntry? existing = widget.existing;
    if (existing == null) return;
    setState(() {
      _error = null;
      _isSubmitting = true;
    });
    final bool deleted = await widget.controller.deleteSkill(existing);
    if (!mounted) return;
    if (deleted) {
      widget.onDeleted();
      return;
    }
    setState(() {
      _error = '${widget.controller.skillsError}';
      _isSubmitting = false;
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      AppTextField(
        label: 'Name',
        controller: _name,
        enabled: !_isSubmitting,
        hintText: 'Letters, digits, . _ - (max 64)',
      ),
      AppTextField(
        label: 'Alias',
        controller: _alias,
        enabled: !_isSubmitting,
        hintText: 'Optional display name',
      ),
      AppTextField(
        label: 'Description',
        controller: _description,
        enabled: !_isSubmitting,
        minLines: 2,
        maxLines: 4,
        hintText: _isText
            ? 'Tell the model when to use this skill'
            : 'Filled from SKILL.md when left blank',
      ),
      AppDropdown(
        label: 'Source Type',
        value: _isText ? 'Text' : 'Folder',
        options: _sourceTypeLabels,
        enabled: !_isSubmitting,
        onChanged: (String value) => setState(() => _isText = value == 'Text'),
      ),
      if (_isText) ...<Widget>[
        AppTextField(
          label: 'Instructions',
          controller: _instructions,
          enabled: !_isSubmitting,
          minLines: 6,
          maxLines: 14,
          maxLength: 20000,
          hintText: 'Write the skill instructions',
        ),
      ] else ...<Widget>[
        AppTextField(
          label: 'Folder path',
          controller: _source,
          enabled: !_isSubmitting,
          hintText: 'Folder containing SKILL.md',
        ),
      ],
      const SizedBox(height: 6),
      AppSwitchTile(
        title: 'Enabled',
        value: _enabled,
        onChanged: _isSubmitting
            ? null
            : (bool value) => setState(() => _enabled = value),
      ),
      if (_error != null) AppFormError(error: _error!),
      const SizedBox(height: 18),
      AppButtonRow(
        children: <Widget>[
          if (widget.existing != null)
            TextButton(
              onPressed: _isSubmitting ? null : _delete,
              child: const Text('Delete'),
            ),
          TextButton(
            onPressed: _isSubmitting ? null : widget.onCancel,
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _isSubmitting ? null : _save,
            child: Text(_isSubmitting ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    ],
  );
}

final class _AboutSettingsPage extends StatelessWidget {
  const _AboutSettingsPage();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) =>
        SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 750,
                minHeight: constraints.maxHeight > 60
                    ? constraints.maxHeight - 60
                    : 0,
              ),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Icon(FluentIcons.info_20_regular),
                        SizedBox(width: 6),
                        Text(
                          'About',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Expanded(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Align(
                              alignment: Alignment.center,
                              child: SizedBox.square(
                                dimension: 88,
                                child: SvgPicture.asset(
                                  'windows/runner/resources/icon_title.svg',
                                  fit: BoxFit.contain,
                                  colorFilter: ColorFilter.mode(
                                    Theme.of(context).colorScheme.onSurface,
                                    BlendMode.srcIn,
                                  ),
                                  semanticsLabel: 'Subconscious logo',
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Subconscious',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 40),
                            const Text(
                              'Subconscious is a distributed agentic AI app that allows you to create AI agents that run everywhere on every device at the same time.',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 20),
                            const _CopyLink(
                              label: 'Subconscious.chat',
                              value: 'https://subconscious.chat/',
                            ),
                            const _CopyLink(
                              label: 'View License',
                              value: 'https://github.com/Ancilla-Company/Subconscious/blob/main/LICENSE',
                            ),
                            const _CopyLink(
                              label: 'Report an Issue',
                              value: 'https://github.com/Ancilla-Company/Subconscious/issues',
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'Version: v0.1.0',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 14),
                            const Text(
                              '© 2026 Subconscious',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
  );
}

final class _SettingsToolbar extends StatelessWidget {
  const _SettingsToolbar({
    required this.title,
    required this.addLabel,
    required this.add,
    this.reload,
  });

  final String title;
  final String addLabel;
  final VoidCallback add;
  final VoidCallback? reload;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSectionHeading(title: title),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 10,
          runSpacing: 8,
          children: <Widget>[
            if (reload != null)
              OutlinedButton.icon(
                onPressed: reload,
                icon: const Icon(
                  FluentIcons.arrow_clockwise_20_regular,
                  size: 16,
                ),
                label: const Text('Reload'),
              ),
            FilledButton.icon(
              onPressed: add,
              icon: const Icon(FluentIcons.add_20_regular, size: 16),
              label: Text(addLabel),
            ),
          ],
        ),
      ],
    ),
  );
}

final class _CopyLink extends StatelessWidget {
  const _CopyLink({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () async {
      await Clipboard.setData(ClipboardData(text: value));
      if (context.mounted) {
        showAppSnack(context, '$label link copied');
      }
    },
    child: Text(label),
  );
}

String? _nullIfEmpty(String value) {
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

final class _DataDirectoryField extends StatelessWidget {
  const _DataDirectoryField();

  @override
  Widget build(BuildContext context) {
    const bool preferDev = bool.fromEnvironment('SUBCONSCIOUS_ENGINE_DEV');
    final String? path = engineDataDirectory(preferDev: preferDev);
    return Row(
      children: <Widget>[
        Expanded(
          child: AppTextField(
            key: ValueKey<String?>(path),
            initialValue: path ?? 'Unavailable on this platform',
            readOnly: true,
            height: 32,
            prefixIcon: const Icon(FluentIcons.folder_20_regular, size: 17),
          ),
        ),
        const SizedBox(width: 8),
        _WindowsIconButton(
          tooltip: 'Copy data folder path',
          icon: FluentIcons.copy_20_regular,
          onPressed: path == null
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: path));
                  if (context.mounted) {
                    showAppSnack(context, 'Data folder path copied');
                  }
                },
        ),
        const SizedBox(width: 6),
        _WindowsIconButton(
          tooltip: 'Open data folder',
          icon: FluentIcons.folder_open_20_regular,
          onPressed: path == null
              ? null
              : () async {
                  try {
                    await openEngineDataDirectory(path);
                  } on Object catch (error) {
                    if (context.mounted) {
                      showAppSnack(context, '$error');
                    }
                  }
                },
        ),
      ],
    );
  }
}

final class _JoiningTokenField extends StatelessWidget {
  const _JoiningTokenField({required this.token});

  final String? token;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Expanded(
        child: AppTextField(
          key: ValueKey<String?>(token),
          initialValue: token ?? 'Unavailable while the engine is disconnected',
          readOnly: true,
          height: 32,
          prefixIcon: const Icon(FluentIcons.key_20_regular, size: 17),
        ),
      ),
      const SizedBox(width: 8),
      _WindowsIconButton(
        tooltip: 'Copy joining token',
        icon: FluentIcons.copy_20_regular,
        onPressed: token == null
            ? null
            : () async {
                await Clipboard.setData(ClipboardData(text: token!));
                if (context.mounted) {
                  showAppSnack(context, 'Joining token copied');
                }
              },
      ),
    ],
  );
}

final class _WindowsIconButton extends StatelessWidget {
  const _WindowsIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => AppIconButton(
    outlined: true,
    tooltip: tooltip,
    icon: icon,
    iconSize: 17,
    onPressed: onPressed,
  );
}
