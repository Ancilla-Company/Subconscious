import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/settings_controller.dart';

final class SettingsMainPanel extends StatelessWidget {
  const SettingsMainPanel({required this.controller, super.key});

  final DashboardSettingsController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (BuildContext context, Widget? child) => ColoredBox(
      color: Colors.white,
      child: switch (controller.activePage) {
        SettingsPage.general => _GeneralSettingsPage(controller: controller),
        SettingsPage.models => _ModelsSettingsPage(controller: controller),
        SettingsPage.tools => _ToolsSettingsPage(controller: controller),
        SettingsPage.skills => const _SkillsSettingsPage(),
        SettingsPage.about => const _AboutSettingsPage(),
      },
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
  const _GeneralSettingsPage({required this.controller});

  final DashboardSettingsController controller;

  static const List<String> _modes = <String>['Device', 'Light', 'Dark'];
  static const List<String> _colours = <String>[
    'Device',
    'Blue',
    'Purple',
    'Green',
    'Orange',
    'Red',
  ];
  static const List<String> _sidebarPositions = <String>['Left', 'Right'];
  static const List<String> _panelConfigurations = <String>[
    'Context · Chat · Main',
    'Chat · Context · Main',
    'Context · Main · Chat',
    'Chat · Main · Context',
    'Main · Context · Chat',
    'Main · Chat · Context',
  ];

  @override
  Widget build(BuildContext context) => _SettingsBody(
    children: <Widget>[
      const _SectionHeading(title: 'General Settings'),
      if (controller.isLoadingGeneral) const LinearProgressIndicator(),
      if (controller.generalError case final Object error)
        _SettingsError(error: error),
      _LabeledDropdown(
        label: 'Mode',
        value: controller.generalValue('mode', 'Device'),
        options: _modes,
        onChanged: (String value) =>
            controller.updateGeneralSetting('mode', value),
      ),
      _LabeledDropdown(
        label: 'Colour Theme',
        value: controller.generalValue('colour_theme', 'Device'),
        options: _colours,
        onChanged: (String value) =>
            controller.updateGeneralSetting('colour_theme', value),
      ),
      _LabeledDropdown(
        label: 'Sidebar position',
        value: controller.generalValue('sidebar_position', 'Left'),
        options: _sidebarPositions,
        onChanged: (String value) =>
            controller.updateGeneralSetting('sidebar_position', value),
      ),
      _LabeledDropdown(
        label: 'Panel configuration',
        value: controller.generalValue(
          'panel_configuration',
          'Chat · Main · Context',
        ),
        options: _panelConfigurations,
        onChanged: (String value) =>
            controller.updateGeneralSetting('panel_configuration', value),
      ),
      const _FieldLabel('Data Folder'),
      const TextField(
        enabled: false,
        decoration: InputDecoration(
          hintText: 'Managed by the connected .NET engine',
          prefixIcon: Icon(FluentIcons.folder_20_regular),
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
  });

  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _FieldLabel(label),
        DropdownButtonFormField<String>(
          initialValue: options.contains(value) ? value : options.first,
          items: <DropdownMenuItem<String>>[
            for (final String option in options)
              DropdownMenuItem<String>(value: option, child: Text(option)),
          ],
          onChanged: (String? next) {
            if (next != null) onChanged(next);
          },
        ),
      ],
    ),
  );
}

final class _ModelsSettingsPage extends StatelessWidget {
  const _ModelsSettingsPage({required this.controller});

  final DashboardSettingsController controller;

  @override
  Widget build(BuildContext context) => _SettingsBody(
    children: <Widget>[
      _SettingsToolbar(
        title: 'Models',
        reload: controller.loadModelConfigurations,
        addLabel: 'New configuration',
        add: () => _showModelDialog(context, controller),
      ),
      const Text(
        'Configurations are stored encrypted by the local engine. Saved API keys are never returned to this app.',
      ),
      if (controller.isLoadingModels) const LinearProgressIndicator(),
      if (controller.modelsError case final Object error)
        _SettingsError(error: error),
      if (!controller.isLoadingModels && controller.modelConfigurations.isEmpty)
        const _EmptySettingsMessage(
          'No model configurations yet. Add one to get started.',
        ),
      for (final ModelConfiguration configuration
          in controller.modelConfigurations)
        _SettingsCard(
          title: configuration.alias?.trim().isNotEmpty ?? false
              ? configuration.alias!
              : configuration.model,
          subtitle: '${configuration.provider} · ${configuration.model}',
          trailing: configuration.hasApiKey ? 'API key saved' : null,
          onTap: () =>
              _showModelDialog(context, controller, existing: configuration),
        ),
    ],
  );
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

Future<void> _showModelDialog(
  BuildContext context,
  DashboardSettingsController controller, {
  ModelConfiguration? existing,
}) async {
  final TextEditingController alias = TextEditingController(
    text: existing?.alias,
  );
  final TextEditingController model = TextEditingController(
    text: existing?.model,
  );
  final TextEditingController apiKey = TextEditingController();
  final TextEditingController baseUrl = TextEditingController(
    text: existing?.baseUrl,
  );
  final TextEditingController contextWindow = TextEditingController(
    text: existing?.contextWindow?.toString(),
  );
  String provider = existing?.provider ?? 'OpenAI';
  String? dialogError;
  await showDialog<void>(
    context: context,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter setState) => AlertDialog(
        title: Text(
          existing == null ? 'New model configuration' : 'Edit configuration',
        ),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: alias,
                  decoration: const InputDecoration(labelText: 'Alias'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: _modelProviders.contains(provider)
                      ? provider
                      : 'Custom',
                  decoration: const InputDecoration(labelText: 'Provider'),
                  items: <DropdownMenuItem<String>>[
                    for (final String item in _modelProviders)
                      DropdownMenuItem<String>(value: item, child: Text(item)),
                  ],
                  onChanged: (String? value) =>
                      setState(() => provider = value ?? provider),
                ),
                TextField(
                  controller: model,
                  decoration: const InputDecoration(labelText: 'Model'),
                ),
                TextField(
                  controller: apiKey,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    helperText: existing?.hasApiKey ?? false
                        ? 'Leave blank to keep the saved API key.'
                        : 'Stored encrypted by the engine.',
                  ),
                ),
                TextField(
                  controller: baseUrl,
                  decoration: const InputDecoration(labelText: 'Base URL'),
                ),
                TextField(
                  controller: contextWindow,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Context Window (tokens)',
                  ),
                ),
                if (dialogError != null) _SettingsError(error: dialogError!),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          if (existing != null)
            TextButton(
              onPressed: () async {
                final bool deleted = await controller.deleteModelConfiguration(
                  existing,
                );
                if (deleted && context.mounted) Navigator.pop(context);
                if (!deleted) {
                  setState(() => dialogError = '${controller.modelsError}');
                }
              },
              child: const Text('Delete'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final int? parsedContext = contextWindow.text.trim().isEmpty
                  ? null
                  : int.tryParse(contextWindow.text.trim());
              if (model.text.trim().isEmpty ||
                  (contextWindow.text.trim().isNotEmpty &&
                      (parsedContext == null || parsedContext <= 0))) {
                setState(
                  () => dialogError =
                      'Model is required and context window must be positive.',
                );
                return;
              }
              final bool saved = await controller.saveModelConfiguration(
                existing: existing,
                request: ModelConfigurationRequest(
                  provider: provider,
                  model: model.text.trim(),
                  alias: _nullIfEmpty(alias.text),
                  baseUrl: _nullIfEmpty(baseUrl.text),
                  contextWindow: parsedContext,
                  apiKey: _nullIfEmpty(apiKey.text),
                ),
              );
              if (saved && context.mounted) Navigator.pop(context);
              if (!saved) {
                setState(() => dialogError = '${controller.modelsError}');
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  alias.dispose();
  model.dispose();
  apiKey.dispose();
  baseUrl.dispose();
  contextWindow.dispose();
}

final class _ToolsSettingsPage extends StatelessWidget {
  const _ToolsSettingsPage({required this.controller});

  final DashboardSettingsController controller;

  @override
  Widget build(BuildContext context) => _SettingsBody(
    children: <Widget>[
      _SettingsToolbar(
        title: 'Tools',
        reload: controller.loadTools,
        addLabel: 'New tool',
        add: () => _showToolDialog(context, controller),
      ),
      const Text(
        'Configure scripts, MCP servers, and API tools. Credentials are stored encrypted and are never returned to this app.',
      ),
      if (controller.isLoadingTools) const LinearProgressIndicator(),
      if (controller.toolsError case final Object error)
        _SettingsError(error: error),
      if (!controller.isLoadingTools && controller.tools.isEmpty)
        const _EmptySettingsMessage(
          'No configured tools yet. Add one to make it available in policies.',
        ),
      for (final ToolRegistryEntry tool in controller.tools)
        _SettingsCard(
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
          onTap: () => _showToolDialog(context, controller, existing: tool),
        ),
    ],
  );
}

Future<void> _showToolDialog(
  BuildContext context,
  DashboardSettingsController controller, {
  ToolRegistryEntry? existing,
}) async {
  final TextEditingController alias = TextEditingController(
    text: existing?.alias ?? existing?.name,
  );
  final TextEditingController scriptPath = TextEditingController(
    text: existing?.scriptPath,
  );
  final TextEditingController endpointUrl = TextEditingController(
    text: existing?.endpointUrl,
  );
  final TextEditingController authConfig = TextEditingController();
  String toolType = existing?.toolType ?? 'script';
  String scriptLanguage = existing?.scriptLanguage ?? 'python';
  String authType =
      existing?.authType ??
      ((existing?.hasAuthConfig ?? false) ? 'api_key' : 'None');
  String? dialogError;
  await showDialog<void>(
    context: context,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter setState) {
        final bool isScript = toolType == 'script';
        final bool isEndpoint = toolType == 'mcp' || toolType == 'api';
        return AlertDialog(
          title: Text(existing == null ? 'New tool' : 'Edit tool'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextField(
                    controller: alias,
                    decoration: const InputDecoration(labelText: 'Alias'),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: toolType,
                    decoration: const InputDecoration(labelText: 'Tool Type'),
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem(value: 'script', child: Text('script')),
                      DropdownMenuItem(value: 'mcp', child: Text('mcp')),
                      DropdownMenuItem(value: 'api', child: Text('api')),
                    ],
                    onChanged: (String? value) =>
                        setState(() => toolType = value ?? toolType),
                  ),
                  if (isScript) ...<Widget>[
                    DropdownButtonFormField<String>(
                      initialValue: scriptLanguage,
                      decoration: const InputDecoration(labelText: 'Language'),
                      items: const <DropdownMenuItem<String>>[
                        DropdownMenuItem(
                          value: 'python',
                          child: Text('python'),
                        ),
                        DropdownMenuItem(
                          value: 'javascript',
                          child: Text('javascript'),
                        ),
                        DropdownMenuItem(
                          value: 'typescript',
                          child: Text('typescript'),
                        ),
                      ],
                      onChanged: (String? value) => setState(
                        () => scriptLanguage = value ?? scriptLanguage,
                      ),
                    ),
                    TextField(
                      controller: scriptPath,
                      decoration: const InputDecoration(
                        labelText: 'Script Path',
                      ),
                    ),
                  ],
                  if (isEndpoint) ...<Widget>[
                    TextField(
                      controller: endpointUrl,
                      decoration: const InputDecoration(
                        labelText: 'Endpoint URL',
                      ),
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: authType,
                      decoration: const InputDecoration(
                        labelText: 'Authentication',
                      ),
                      items: const <DropdownMenuItem<String>>[
                        DropdownMenuItem(value: 'None', child: Text('None')),
                        DropdownMenuItem(
                          value: 'api_key',
                          child: Text('API key'),
                        ),
                      ],
                      onChanged: (String? value) =>
                          setState(() => authType = value ?? authType),
                    ),
                    if (authType == 'api_key')
                      TextField(
                        controller: authConfig,
                        minLines: 2,
                        maxLines: 4,
                        decoration: InputDecoration(
                          labelText: 'API key header (JSON)',
                          helperText: existing?.hasAuthConfig ?? false
                              ? 'Leave blank to keep the saved credentials.'
                              : '{"x-api-key":"your-api-key"}',
                        ),
                      ),
                  ],
                  if (dialogError != null) _SettingsError(error: dialogError!),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            if (existing != null)
              TextButton(
                onPressed: () async {
                  final bool deleted = await controller.deleteTool(existing);
                  if (deleted && context.mounted) Navigator.pop(context);
                  if (!deleted) {
                    setState(() => dialogError = '${controller.toolsError}');
                  }
                },
                child: const Text('Delete'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                if (alias.text.trim().isEmpty ||
                    (isScript && scriptPath.text.trim().isEmpty) ||
                    (isEndpoint && endpointUrl.text.trim().isEmpty)) {
                  setState(
                    () => dialogError =
                        'Alias and the selected tool location are required.',
                  );
                  return;
                }
                final bool saved = await controller.saveTool(
                  existing: existing,
                  request: ToolRegistryRequest(
                    alias: alias.text.trim(),
                    description: existing?.description,
                    toolType: toolType,
                    scriptPath: isScript ? scriptPath.text.trim() : null,
                    scriptLanguage: isScript ? scriptLanguage : null,
                    endpointUrl: isEndpoint ? endpointUrl.text.trim() : null,
                    authType: isEndpoint && authType == 'api_key'
                        ? 'api_key'
                        : null,
                    authConfigJson: isEndpoint && authType == 'api_key'
                        ? _nullIfEmpty(authConfig.text)
                        : null,
                    clearAuthConfig: !isEndpoint || authType != 'api_key',
                    status: existing?.status,
                  ),
                );
                if (saved && context.mounted) Navigator.pop(context);
                if (!saved) {
                  setState(() => dialogError = '${controller.toolsError}');
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    ),
  );
  alias.dispose();
  scriptPath.dispose();
  endpointUrl.dispose();
  authConfig.dispose();
}

final class _SkillsSettingsPage extends StatefulWidget {
  const _SkillsSettingsPage();

  @override
  State<_SkillsSettingsPage> createState() => _SkillsSettingsPageState();
}

final class _SkillsSettingsPageState extends State<_SkillsSettingsPage> {
  final List<_SkillDraft> _skills = <_SkillDraft>[];

  Future<void> _edit([int? index]) async {
    final _SkillDraft? saved = await _showSkillDialog(
      context,
      existing: index == null ? null : _skills[index],
    );
    if (saved == null || !mounted) return;
    setState(() {
      if (index == null) {
        _skills.add(saved);
      } else {
        _skills[index] = saved;
      }
    });
  }

  @override
  Widget build(BuildContext context) => _SettingsBody(
    children: <Widget>[
      _SettingsToolbar(title: 'Skills', addLabel: 'New skill', add: _edit),
      const Text(
        'Skills are editable for this app session. Engine-backed skill configuration and validation are not available yet.',
      ),
      if (_skills.isEmpty)
        const _EmptySettingsMessage(
          'No skills have been added. Add one to configure it.',
        ),
      for (int index = 0; index < _skills.length; index++)
        _SettingsCard(
          title: _skills[index].alias.isEmpty
              ? _skills[index].name
              : _skills[index].alias,
          subtitle: '${_skills[index].sourceType} · ${_skills[index].source}',
          trailing: 'session only',
          onTap: () => _edit(index),
          onDelete: () => setState(() => _skills.removeAt(index)),
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

Future<_SkillDraft?> _showSkillDialog(
  BuildContext context, {
  _SkillDraft? existing,
}) async {
  final TextEditingController name = TextEditingController(
    text: existing?.name,
  );
  final TextEditingController alias = TextEditingController(
    text: existing?.alias,
  );
  final TextEditingController description = TextEditingController(
    text: existing?.description,
  );
  final TextEditingController source = TextEditingController(
    text: existing?.source,
  );
  String sourceType = existing?.sourceType ?? 'folder';
  final _SkillDraft? result = await showDialog<_SkillDraft>(
    context: context,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter setState) => AlertDialog(
        title: Text(existing == null ? 'New skill' : 'Edit skill'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                TextField(
                  controller: alias,
                  decoration: const InputDecoration(labelText: 'Alias'),
                ),
                TextField(
                  controller: description,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: sourceType,
                  decoration: const InputDecoration(labelText: 'Source Type'),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem(value: 'folder', child: Text('folder')),
                    DropdownMenuItem(value: 'zip', child: Text('zip')),
                    DropdownMenuItem(value: 'url', child: Text('url')),
                  ],
                  onChanged: (String? value) =>
                      setState(() => sourceType = value ?? sourceType),
                ),
                TextField(
                  controller: source,
                  decoration: const InputDecoration(labelText: 'Source'),
                ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isEmpty || source.text.trim().isEmpty) {
                return;
              }
              Navigator.pop(
                context,
                _SkillDraft(
                  name: name.text.trim(),
                  alias: alias.text.trim(),
                  description: description.text.trim(),
                  sourceType: sourceType,
                  source: source.text.trim(),
                ),
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  name.dispose();
  alias.dispose();
  description.dispose();
  source.dispose();
  return result;
}

final class _AboutSettingsPage extends StatelessWidget {
  const _AboutSettingsPage();

  @override
  Widget build(BuildContext context) => _SettingsBody(
    children: const <Widget>[
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(FluentIcons.info_20_regular),
          SizedBox(width: 6),
          Text(
            'About',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      SizedBox(height: 36),
      Icon(FluentIcons.brain_circuit_24_regular, size: 88),
      SizedBox(height: 12),
      Text(
        'Subconscious',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
      ),
      SizedBox(height: 40),
      Text(
        'Subconscious is a distributed agentic AI app that allows you to create AI agents that run everywhere on every device at the same time.',
        textAlign: TextAlign.center,
      ),
      SizedBox(height: 20),
      _CopyLink(
        label: 'Subconscious.chat',
        value: 'https://subconscious.chat/',
      ),
      _CopyLink(
        label: 'View License',
        value:
            'https://github.com/Ancilla-Company/Subconscious/blob/main/LICENSE',
      ),
      _CopyLink(
        label: 'Report an Issue',
        value: 'https://github.com/Ancilla-Company/Subconscious/issues',
      ),
      SizedBox(height: 16),
      Text('Version: v0.1.0', textAlign: TextAlign.center),
      SizedBox(height: 14),
      Text('© 2026 Subconscious', textAlign: TextAlign.center),
    ],
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
        ?.copyWith(fontWeight: FontWeight.bold),
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

final class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.onDelete,
  });

  final String title;
  final String subtitle;
  final String? trailing;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(top: 10),
    child: ListTile(
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (trailing != null)
            Text(trailing!, style: Theme.of(context).textTheme.labelSmall),
          if (onDelete != null)
            IconButton(
              tooltip: 'Remove',
              onPressed: onDelete,
              icon: const Icon(FluentIcons.delete_20_regular, size: 17),
            )
          else
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(FluentIcons.edit_20_regular, size: 17),
            ),
        ],
      ),
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
