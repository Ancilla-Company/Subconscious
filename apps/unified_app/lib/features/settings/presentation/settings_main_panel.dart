import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../connection/engine_connection_resolver.dart';
import '../../dashboard/controller/dashboard_controller.dart';
import '../controller/settings_controller.dart';

final class SettingsMainPanel extends StatelessWidget {
  const SettingsMainPanel({
    required this.controller,
    required this.dashboardController,
    super.key,
  });

  final DashboardSettingsController controller;
  final DashboardController dashboardController;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (BuildContext context, Widget? child) => Theme(
      data: settingsFormTheme(context),
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
            SettingsPage.skills => const _SkillsSettingsPage(),
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
  Widget build(BuildContext context) => _SettingsBody(
    children: <Widget>[
      const _SectionHeading(title: 'General Settings'),
      if (_supportsRemoteEngineConnection) ...<Widget>[
        const _FieldLabel('Engine Connection'),
        _RemoteEngineConnectionForm(controller: dashboardController),
      ],
      if (controller.isLoadingGeneral) const LinearProgressIndicator(),
      if (controller.generalError case final Object error)
        _SettingsError(error: error),
      _LabeledDropdown(
        label: 'Mode',
        value: controller.modeValue,
        options: _modes,
        onChanged: (String value) => controller.updateGeneralSetting(
          DashboardSettingsController.modeKey,
          value,
        ),
      ),
      _LabeledDropdown(
        label: 'Colour Theme',
        value: controller.colourThemeValue,
        options: _colours,
        onChanged: (String value) => controller.updateGeneralSetting(
          DashboardSettingsController.colourThemeKey,
          value,
        ),
      ),
      _LabeledDropdown(
        label: 'Sidebar position',
        value: controller.sidebarPositionValue,
        options: _sidebarPositions,
        onChanged: (String value) => controller.updateGeneralSetting(
          DashboardSettingsController.sidebarPositionKey,
          value,
        ),
      ),
      _LabeledDropdown(
        label: 'Panel configuration',
        value: controller.panelConfigurationValue,
        options: _panelConfigurations,
        onChanged: (String value) => controller.updateGeneralSetting(
          DashboardSettingsController.panelConfigurationKey,
          value,
        ),
      ),
      if (!_supportsRemoteEngineConnection) ...<Widget>[
        const _FieldLabel('Data Folder'),
        const _DataDirectoryField(),
        const _FieldLabel('Joining Token'),
        _JoiningTokenField(token: controller.joiningToken),
        if (_supportsWindowsFirewall) const _WindowsFirewallSettings(),
      ],
    ],
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            enabled
                ? 'Windows Firewall now allows local-subnet access on TCP $port.'
                : 'The Subconscious Engine firewall rule was removed.',
          ),
        ),
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
        const _FieldLabel('Engine IP Address'),
        _EngineConnectionValueField(
          value: endpoint?.host,
          unavailableText: _isLoadingEndpoint
              ? 'Finding the local engine…'
              : 'No running local engine detected',
          copyMessage: 'Engine IP address copied',
          icon: FluentIcons.globe_20_regular,
        ),
        const _FieldLabel('Engine Port'),
        _EngineConnectionValueField(
          value: endpoint?.port.toString(),
          unavailableText: _isLoadingEndpoint
              ? 'Finding the local engine…'
              : 'No running local engine detected',
          copyMessage: 'Engine port copied',
          icon: FluentIcons.plug_connected_20_regular,
        ),
        const _FieldLabel('Mobile and LAN Access'),
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
        if (_error != null) _SettingsError(error: _error!),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
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
        child: SizedBox(
          height: 32,
          child: TextFormField(
            key: ValueKey<String?>(value),
            initialValue: value ?? unavailableText,
            readOnly: true,
            textAlignVertical: TextAlignVertical.center,
            decoration: InputDecoration(
              contentPadding: const EdgeInsets.symmetric(horizontal: 10),
              prefixIcon: Icon(icon, size: 17),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 32,
                minHeight: 32,
              ),
            ),
          ),
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
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(copyMessage)));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Connected to the engine.')));
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      const Text(
        'Connect to an engine on this Wi-Fi network. Enter the address and port shown by the engine, then its joining token.',
      ),
      const _FieldLabel('Engine host or IP address'),
      TextField(
        controller: _host,
        enabled: !_isConnecting,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(hintText: '192.168.1.42'),
      ),
      const _FieldLabel('Engine port'),
      TextField(
        controller: _port,
        enabled: !_isConnecting,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(hintText: 'Port shown by the engine'),
      ),
      const _FieldLabel('Joining token'),
      TextField(
        controller: _token,
        enabled: !_isConnecting,
        autocorrect: false,
        enableSuggestions: false,
        obscureText: true,
        decoration: InputDecoration(
          hintText: widget.controller.hasExplicitToken
              ? 'A token is already configured'
              : 'Paste the joining token',
          helperText: widget.controller.hasExplicitToken
              ? 'Leave blank to reuse the configured token for this session.'
              : 'The token is retained only for this app session.',
        ),
        onSubmitted: (_) => _isConnecting ? null : _connect(),
      ),
      if (_error != null) _SettingsError(error: _error!),
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

final class _LabeledDropdown extends StatelessWidget {
  const _LabeledDropdown({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _FieldLabel(label),
        DropdownButtonFormField<String>(
          key: ValueKey<String>('$label:$value'),
          initialValue: options.contains(value) ? value : options.first,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.normal),
          items: <DropdownMenuItem<String>>[
            for (final String option in options)
              DropdownMenuItem<String>(value: option, child: Text(option)),
          ],
          onChanged: !enabled
              ? null
              : (String? next) {
                  if (next != null) onChanged(next);
                },
        ),
      ],
    ),
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
          _SettingsError(error: widget.controller.modelsError!),
        if (!widget.controller.isLoadingModels &&
            widget.controller.modelConfigurations.isEmpty &&
            !_isCreating)
          const _EmptySettingsMessage(
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

final class _ModelEditorState extends State<_ModelEditor> {
  late final TextEditingController _alias;
  late final TextEditingController _model;
  late final TextEditingController _apiKey;
  late final TextEditingController _baseUrl;
  late final TextEditingController _contextWindow;
  late String _provider;
  String? _error;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    final ModelConfiguration? existing = widget.existing;
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
      const _FieldLabel('Alias'),
      TextField(
        controller: _alias,
        enabled: !_isSubmitting,
        decoration: const InputDecoration(hintText: 'Configuration name'),
      ),
      _LabeledDropdown(
        label: 'Provider',
        value: _modelProviders.contains(_provider) ? _provider : 'Custom',
        options: _modelProviders,
        enabled: !_isSubmitting,
        onChanged: (String value) => setState(() => _provider = value),
      ),
      const _FieldLabel('Model'),
      TextField(
        controller: _model,
        enabled: !_isSubmitting,
        decoration: const InputDecoration(hintText: 'Model name'),
      ),
      const _FieldLabel('API Key'),
      TextField(
        controller: _apiKey,
        enabled: !_isSubmitting,
        obscureText: true,
        decoration: InputDecoration(
          helperText: widget.existing?.hasApiKey ?? false
              ? 'Leave blank to keep the saved API key.'
              : 'Stored encrypted by the engine.',
        ),
      ),
      const _FieldLabel('Base URL'),
      TextField(
        controller: _baseUrl,
        enabled: !_isSubmitting,
        decoration: const InputDecoration(hintText: 'Optional endpoint URL'),
      ),
      const _FieldLabel('Context Window (tokens)'),
      TextField(
        controller: _contextWindow,
        enabled: !_isSubmitting,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(hintText: 'Optional token limit'),
      ),
      if (_error != null) _SettingsError(error: _error!),
      const SizedBox(height: 18),
      Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
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
          'Configure scripts, MCP servers, and API tools. Credentials are stored encrypted and are never returned to this app.',
        ),
        if (widget.controller.isLoadingTools) const LinearProgressIndicator(),
        if (!hasOpenEditor && widget.controller.toolsError != null)
          _SettingsError(error: widget.controller.toolsError!),
        if (!widget.controller.isLoadingTools &&
            widget.controller.tools.isEmpty &&
            !_isCreating)
          const _EmptySettingsMessage(
            'No configured tools yet. Add one to make it available in policies.',
          ),
        if (_isCreating)
          _SettingsExpansionCard(
            title: 'New tool',
            subtitle: 'Configure a script, MCP server, or API tool',
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
              tool.toolType,
              if (tool.toolType == 'script' && tool.scriptPath != null)
                tool.scriptPath!,
              if (tool.toolType != 'script' && tool.endpointUrl != null)
                tool.endpointUrl!,
            ].join(' · '),
            trailing: tool.hasAuthConfig ? 'Credentials saved' : tool.status,
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
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: 10),
    clipBehavior: Clip.antiAlias,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(6)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ListTile(
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: onToggle,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (trailing != null)
                Text(trailing!, style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(width: 8),
              Icon(
                expanded
                    ? FluentIcons.chevron_up_20_regular
                    : FluentIcons.chevron_down_20_regular,
                size: 17,
              ),
            ],
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: expanded && editor != null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 2, 16, 16),
                      child: editor,
                    ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    ),
  );
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
  static const List<String> _toolTypes = <String>['script', 'mcp', 'api'];
  static const List<String> _scriptLanguages = <String>[
    'python',
    'javascript',
    'typescript',
  ];
  static const List<String> _authenticationTypes = <String>['None', 'API key'];

  late final TextEditingController _alias;
  late final TextEditingController _scriptPath;
  late final TextEditingController _endpointUrl;
  late final TextEditingController _authConfig;
  late String _toolType;
  late String _scriptLanguage;
  late String _authType;
  String? _error;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    final ToolRegistryEntry? existing = widget.existing;
    _alias = TextEditingController(text: existing?.alias ?? existing?.name);
    _scriptPath = TextEditingController(text: existing?.scriptPath);
    _endpointUrl = TextEditingController(text: existing?.endpointUrl);
    _authConfig = TextEditingController();
    _toolType = _toolTypes.contains(existing?.toolType)
        ? existing!.toolType
        : 'script';
    _scriptLanguage = _scriptLanguages.contains(existing?.scriptLanguage)
        ? existing!.scriptLanguage!
        : 'python';
    _authType =
        existing?.authType?.toLowerCase() == 'api_key' ||
            (existing?.hasAuthConfig ?? false)
        ? 'api_key'
        : 'None';
  }

  @override
  void dispose() {
    _alias.dispose();
    _scriptPath.dispose();
    _endpointUrl.dispose();
    _authConfig.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final bool isScript = _toolType == 'script';
    final bool isEndpoint = _toolType == 'mcp' || _toolType == 'api';
    if (_alias.text.trim().isEmpty ||
        (isScript && _scriptPath.text.trim().isEmpty) ||
        (isEndpoint && _endpointUrl.text.trim().isEmpty)) {
      setState(
        () => _error = 'Alias and the selected tool location are required.',
      );
      return;
    }
    setState(() {
      _error = null;
      _isSubmitting = true;
    });
    final bool saved = await widget.controller.saveTool(
      existing: widget.existing,
      request: ToolRegistryRequest(
        alias: _alias.text.trim(),
        description: widget.existing?.description,
        toolType: _toolType,
        scriptPath: isScript ? _scriptPath.text.trim() : null,
        scriptLanguage: isScript ? _scriptLanguage : null,
        endpointUrl: isEndpoint ? _endpointUrl.text.trim() : null,
        authType: isEndpoint && _authType == 'api_key' ? 'api_key' : null,
        authConfigJson: isEndpoint && _authType == 'api_key'
            ? _nullIfEmpty(_authConfig.text)
            : null,
        clearAuthConfig: !isEndpoint || _authType != 'api_key',
        status: widget.existing?.status,
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

  @override
  Widget build(BuildContext context) {
    final bool isScript = _toolType == 'script';
    final bool isEndpoint = _toolType == 'mcp' || _toolType == 'api';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _FieldLabel('Alias'),
        TextField(
          controller: _alias,
          enabled: !_isSubmitting,
          decoration: const InputDecoration(hintText: 'Tool name'),
        ),
        _LabeledDropdown(
          label: 'Tool Type',
          value: _toolType,
          options: _toolTypes,
          enabled: !_isSubmitting,
          onChanged: (String value) => setState(() => _toolType = value),
        ),
        if (isScript) ...<Widget>[
          _LabeledDropdown(
            label: 'Language',
            value: _scriptLanguage,
            options: _scriptLanguages,
            enabled: !_isSubmitting,
            onChanged: (String value) =>
                setState(() => _scriptLanguage = value),
          ),
          const _FieldLabel('Script Path'),
          TextField(
            controller: _scriptPath,
            enabled: !_isSubmitting,
            decoration: const InputDecoration(hintText: 'Path to the script'),
          ),
        ],
        if (isEndpoint) ...<Widget>[
          const _FieldLabel('Endpoint URL'),
          TextField(
            controller: _endpointUrl,
            enabled: !_isSubmitting,
            decoration: const InputDecoration(hintText: 'https://'),
          ),
          _LabeledDropdown(
            label: 'Authentication',
            value: _authType == 'api_key' ? 'API key' : 'None',
            options: _authenticationTypes,
            enabled: !_isSubmitting,
            onChanged: (String value) => setState(
              () => _authType = value == 'API key' ? 'api_key' : 'None',
            ),
          ),
          if (_authType == 'api_key') ...<Widget>[
            const _FieldLabel('API key header (JSON)'),
            TextField(
              controller: _authConfig,
              enabled: !_isSubmitting,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: '{"x-api-key":"your-api-key"}',
                helperText: widget.existing?.hasAuthConfig ?? false
                    ? 'Leave blank to keep the saved credentials.'
                    : 'Stored encrypted by the engine.',
              ),
            ),
          ],
        ],
        if (_error != null) _SettingsError(error: _error!),
        const SizedBox(height: 18),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
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
}

final class _SkillsSettingsPage extends StatefulWidget {
  const _SkillsSettingsPage();

  @override
  State<_SkillsSettingsPage> createState() => _SkillsSettingsPageState();
}

final class _SkillsSettingsPageState extends State<_SkillsSettingsPage> {
  final List<_SkillDraft> _skills = <_SkillDraft>[];
  int? _expandedSkillIndex;
  bool _isCreating = false;

  void _startCreating() {
    setState(() {
      _isCreating = true;
      _expandedSkillIndex = null;
    });
  }

  void _toggleSkill(int index) {
    setState(() {
      _isCreating = false;
      _expandedSkillIndex = _expandedSkillIndex == index ? null : index;
    });
  }

  void _closeEditor() {
    setState(() {
      _isCreating = false;
      _expandedSkillIndex = null;
    });
  }

  void _saveSkill(_SkillDraft draft, [int? index]) {
    setState(() {
      if (index == null) {
        _skills.add(draft);
      } else {
        _skills[index] = draft;
      }
      _isCreating = false;
      _expandedSkillIndex = null;
    });
  }

  void _deleteSkill(int index) {
    setState(() {
      _skills.removeAt(index);
      _isCreating = false;
      _expandedSkillIndex = null;
    });
  }

  @override
  Widget build(BuildContext context) => _SettingsBody(
    children: <Widget>[
      _SettingsToolbar(
        title: 'Skills',
        addLabel: 'New skill',
        add: _startCreating,
      ),
      const Text(
        'Skills are editable for this app session. Engine-backed skill configuration and validation are not available yet.',
      ),
      if (_skills.isEmpty && !_isCreating)
        const _EmptySettingsMessage(
          'No skills have been added. Add one to configure it.',
        ),
      if (_isCreating)
        _SettingsExpansionCard(
          title: 'New skill',
          subtitle: 'Configure a folder, zip, or URL skill source',
          trailing: 'unsaved',
          expanded: true,
          onToggle: _closeEditor,
          editor: _SkillEditor(
            key: const ValueKey<String>('new-skill'),
            onSaved: _saveSkill,
            onCancel: _closeEditor,
          ),
        ),
      for (int index = 0; index < _skills.length; index++)
        _SettingsExpansionCard(
          title: _skills[index].alias.isEmpty
              ? _skills[index].name
              : _skills[index].alias,
          subtitle: '${_skills[index].sourceType} · ${_skills[index].source}',
          trailing: 'session only',
          expanded: _expandedSkillIndex == index,
          onToggle: () => _toggleSkill(index),
          editor: _expandedSkillIndex == index
              ? _SkillEditor(
                  key: ValueKey<String>('skill-$index'),
                  existing: _skills[index],
                  onSaved: (_SkillDraft draft) => _saveSkill(draft, index),
                  onDeleted: () => _deleteSkill(index),
                  onCancel: _closeEditor,
                )
              : null,
        ),
    ],
  );
}

final class _SkillDraft {
  const _SkillDraft({
    required this.name,
    required this.alias,
    required this.description,
    required this.sourceType,
    required this.source,
  });

  final String name;
  final String alias;
  final String description;
  final String sourceType;
  final String source;
}

final class _SkillEditor extends StatefulWidget {
  const _SkillEditor({
    required this.onSaved,
    required this.onCancel,
    this.existing,
    this.onDeleted,
    super.key,
  });

  final _SkillDraft? existing;
  final ValueChanged<_SkillDraft> onSaved;
  final VoidCallback? onDeleted;
  final VoidCallback onCancel;

  @override
  State<_SkillEditor> createState() => _SkillEditorState();
}

final class _SkillEditorState extends State<_SkillEditor> {
  static const List<String> _sourceTypes = <String>['folder', 'zip', 'url'];

  late final TextEditingController _name;
  late final TextEditingController _alias;
  late final TextEditingController _description;
  late final TextEditingController _source;
  late String _sourceType;
  String? _error;

  @override
  void initState() {
    super.initState();
    final _SkillDraft? existing = widget.existing;
    _name = TextEditingController(text: existing?.name);
    _alias = TextEditingController(text: existing?.alias);
    _description = TextEditingController(text: existing?.description);
    _source = TextEditingController(text: existing?.source);
    _sourceType = _sourceTypes.contains(existing?.sourceType)
        ? existing!.sourceType
        : 'folder';
  }

  @override
  void dispose() {
    _name.dispose();
    _alias.dispose();
    _description.dispose();
    _source.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty || _source.text.trim().isEmpty) {
      setState(() => _error = 'Name and source are required.');
      return;
    }
    widget.onSaved(
      _SkillDraft(
        name: _name.text.trim(),
        alias: _alias.text.trim(),
        description: _description.text.trim(),
        sourceType: _sourceType,
        source: _source.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      const _FieldLabel('Name'),
      TextField(
        controller: _name,
        decoration: const InputDecoration(hintText: 'Skill name'),
      ),
      const _FieldLabel('Alias'),
      TextField(
        controller: _alias,
        decoration: const InputDecoration(hintText: 'Optional display name'),
      ),
      const _FieldLabel('Description'),
      TextField(
        controller: _description,
        minLines: 2,
        maxLines: 4,
        decoration: const InputDecoration(hintText: 'Optional description'),
      ),
      _LabeledDropdown(
        label: 'Source Type',
        value: _sourceType,
        options: _sourceTypes,
        onChanged: (String value) => setState(() => _sourceType = value),
      ),
      const _FieldLabel('Source'),
      TextField(
        controller: _source,
        decoration: const InputDecoration(
          hintText: 'Folder path, zip path, or URL',
        ),
      ),
      if (_error != null) _SettingsError(error: _error!),
      const SizedBox(height: 18),
      Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          if (widget.existing != null)
            TextButton(
              onPressed: widget.onDeleted,
              child: const Text('Delete'),
            ),
          TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
          FilledButton(onPressed: _save, child: const Text('Save')),
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
        _SectionHeading(title: title),
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

final class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Text(
    title,
    style: Theme.of(context).textTheme.titleMedium
        ?.copyWith(fontSize: 18, fontWeight: FontWeight.bold),
  );
}

final class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6, top: 18),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(fontWeight: FontWeight.bold),
    ),
  );
}

final class _SettingsError extends StatelessWidget {
  const _SettingsError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Text(
      '$error',
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.error),
    ),
  );
}

final class _EmptySettingsMessage extends StatelessWidget {
  const _EmptySettingsMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: Text(
      message,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall,
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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$label link copied')));
      }
    },
    child: Text(label),
  );
}

String? _nullIfEmpty(String value) {
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

ThemeData settingsFormTheme(BuildContext context) =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows
    ? _windowsSettingsTheme(context)
    : Theme.of(context);

ThemeData _windowsSettingsTheme(BuildContext context) {
  final ThemeData base = Theme.of(context);
  final ColorScheme colors = base.colorScheme;
  const RoundedRectangleBorder buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(3)),
  );
  return base.copyWith(
    visualDensity: VisualDensity.compact,
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: colors.surfaceContainerLowest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      border: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(3)),
        borderSide: BorderSide(color: colors.outlineVariant),
      ),
      hintStyle: TextStyle(
        color: colors.onSurfaceVariant.withValues(alpha: 0.33),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: buttonShape),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: buttonShape,
        side: BorderSide(color: colors.outlineVariant),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: buttonShape),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(shape: buttonShape),
    ),
  );
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
          child: SizedBox(
            height: 32,
            child: TextFormField(
              key: ValueKey<String?>(path),
              initialValue: path ?? 'Unavailable on this platform',
              readOnly: true,
              textAlignVertical: TextAlignVertical.center,
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.symmetric(horizontal: 10),
                prefixIcon: Icon(FluentIcons.folder_20_regular, size: 17),
                prefixIconConstraints: BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
              ),
            ),
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
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Data folder path copied')),
                    );
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
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text('$error')));
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
        child: SizedBox(
          height: 32,
          child: TextFormField(
            key: ValueKey<String?>(token),
            initialValue:
                token ?? 'Unavailable while the engine is disconnected',
            readOnly: true,
            textAlignVertical: TextAlignVertical.center,
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.symmetric(horizontal: 10),
              prefixIcon: Icon(FluentIcons.key_20_regular, size: 17),
              prefixIconConstraints: BoxConstraints(
                minWidth: 32,
                minHeight: 32,
              ),
            ),
          ),
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
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Joining token copied')),
                  );
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
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 32,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
        style: IconButton.styleFrom(
          backgroundColor: colors.surfaceContainerLowest,
          side: BorderSide(color: colors.outlineVariant),
        ),
        icon: Icon(icon, size: 17),
      ),
    );
  }
}
