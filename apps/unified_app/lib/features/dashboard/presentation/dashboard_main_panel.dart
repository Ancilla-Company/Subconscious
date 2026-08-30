import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

import '../../context/presentation/context_panel.dart';
import '../../settings/controller/settings_controller.dart';
import '../../settings/presentation/settings_main_panel.dart';
import '../controller/dashboard_controller.dart';

final class DashboardMainPanel extends StatelessWidget {
  const DashboardMainPanel({required this.controller, super.key});

  final DashboardController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge(<Listenable>[controller, controller.settings]),
    builder: (BuildContext context, Widget? child) {
      final Workspace? workspace = controller.selectedWorkspace;
      return switch (controller.settings.destination) {
        MainPanelDestination.workspace => workspace == null
            ? const _WorkspaceUnavailablePanel()
            : _WorkspaceDetailsPanel(
                key: ValueKey<String>(workspace.uuid),
                controller: controller,
                workspace: workspace,
              ),
        MainPanelDestination.files => WorkspaceFileEditor(
          controller: controller,
        ),
        MainPanelDestination.settings => SettingsMainPanel(
          controller: controller.settings,
        ),
        MainPanelDestination.utility => const _UtilityPanel(),
      };
    },
  );
}

final class _WorkspaceDetailsPanel extends StatefulWidget {
  const _WorkspaceDetailsPanel({
    required this.controller,
    required this.workspace,
    super.key,
  });

  final DashboardController controller;
  final Workspace workspace;

  @override
  State<_WorkspaceDetailsPanel> createState() =>
      _WorkspaceDetailsPanelState();
}

final class _WorkspaceDetailsPanelState
    extends State<_WorkspaceDetailsPanel> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late String _savedName;
  late String _savedDescription;
  bool _isSynchronizing = false;
  bool _isSaving = false;
  bool _isDeleting = false;
  Object? _error;

  bool get _isBusy => _isSaving || _isDeleting;
  String get _name => _nameController.text.trim();
  String get _description => _descriptionController.text.trim();
  bool get _isDirty =>
      _name != _savedName || _description != _savedDescription;
  bool get _canSave =>
      widget.controller.isConnected && !_isBusy && _name.isNotEmpty && _isDirty;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _descriptionController = TextEditingController();
    _synchronizeWorkspace(widget.workspace);
    _nameController.addListener(_onFieldChanged);
    _descriptionController.addListener(_onFieldChanged);
  }

  @override
  void didUpdateWidget(covariant _WorkspaceDetailsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspace != widget.workspace) {
      _synchronizeWorkspace(widget.workspace);
    }
  }

  void _synchronizeWorkspace(Workspace workspace) {
    _isSynchronizing = true;
    _savedName = workspace.name.trim();
    _savedDescription = workspace.description?.trim() ?? '';
    _nameController.text = workspace.name;
    _descriptionController.text = workspace.description ?? '';
    _isSynchronizing = false;
  }

  void _onFieldChanged() {
    if (!_isSynchronizing && mounted) setState(() => _error = null);
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      await widget.controller.updateWorkspace(
        widget.workspace,
        name: _name,
        description: _description.isEmpty ? null : _description,
      );
      if (!mounted) return;
      _synchronizeWorkspace(
        widget.controller.selectedWorkspace ?? widget.workspace,
      );
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _confirmDelete() async {
    if (_isBusy || !widget.controller.isConnected) return;
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Delete workspace?'),
            content: Text(
              'Delete “${widget.workspace.name}”? This also deletes its threads and cannot be undone.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    setState(() {
      _isDeleting = true;
      _error = null;
    });
    try {
      await widget.controller.deleteWorkspace(widget.workspace);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _isDeleting = false;
          _error = error;
        });
      }
    }
  }

  @override
  void dispose() {
    _nameController
      ..removeListener(_onFieldChanged)
      ..dispose();
    _descriptionController
      ..removeListener(_onFieldChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.outlineVariant)),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Workspace',
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _isBusy || !widget.controller.isConnected
                      ? null
                      : _confirmDelete,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colors.error,
                  ),
                  icon: _isDeleting
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(FluentIcons.delete_20_regular, size: 16),
                  label: const Text('Delete'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _canSave ? _save : null,
                  icon: _isSaving
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(FluentIcons.save_20_regular, size: 16),
                  label: const Text('Save'),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 750),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        'Workspace details',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Update the name and description for this workspace.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _nameController,
                        enabled: !_isBusy,
                        autofocus: true,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _descriptionController,
                        enabled: !_isBusy,
                        minLines: 4,
                        maxLines: 8,
                        decoration: const InputDecoration(
                          labelText: 'Description',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: ValueKey<String>(widget.workspace.uuid),
                        initialValue: widget.workspace.uuid,
                        readOnly: true,
                        decoration: const InputDecoration(
                          labelText: 'Workspace ID',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      if (_error case final Object error) ...<Widget>[
                        const SizedBox(height: 16),
                        Text(
                          'Workspace operation failed: $error',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colors.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _WorkspaceUnavailablePanel extends StatelessWidget {
  const _WorkspaceUnavailablePanel();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: const Center(child: Text('Select a workspace to view its details.')),
  );
}

final class _UtilityPanel extends StatelessWidget {
  const _UtilityPanel();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('Utility panel', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Preview · Terminal — coming soon',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}
