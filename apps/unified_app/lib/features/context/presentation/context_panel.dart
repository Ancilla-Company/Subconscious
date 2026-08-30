import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

import '../../dashboard/controller/dashboard_controller.dart';
import '../../settings/controller/settings_controller.dart';

enum ContextPanelScreen { threads, files, workspaces, settings, account }

final class ContextPanel extends StatelessWidget {
  const ContextPanel({
    required this.screen,
    required this.controller,
    super.key,
  });

  final ContextPanelScreen screen;
  final DashboardController controller;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.white,
    child: AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) => switch (screen) {
        ContextPanelScreen.threads => _ThreadsSection(controller: controller),
        ContextPanelScreen.files => _FilesSection(controller: controller),
        ContextPanelScreen.workspaces => _WorkspacesSection(
          controller: controller,
        ),
        ContextPanelScreen.settings => _SettingsSection(
          controller: controller.settings,
        ),
        ContextPanelScreen.account => const _AccountSection(),
      },
    ),
  );
}

final class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.actions = const <Widget>[]});

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          ...actions,
        ],
      ),
    ),
  );
}

final class _PanelMessage extends StatelessWidget {
  const _PanelMessage(this.message, {this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (action case final Widget action) ...<Widget>[
            const SizedBox(height: 12),
            action,
          ],
        ],
      ),
    ),
  );
}

final class _ThreadsSection extends StatelessWidget {
  const _ThreadsSection({required this.controller});

  final DashboardController controller;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      _SectionHeader(
        title: 'Threads',
        actions: <Widget>[
          const Icon(FluentIcons.folder_20_regular, size: 16),
          const SizedBox(width: 6),
          SizedBox(
            width: 142,
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: controller.selectedWorkspace?.uuid ?? '',
                items: <DropdownMenuItem<String>>[
                  const DropdownMenuItem<String>(
                    value: '',
                    child: Text(
                      'All workspaces',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  for (final Workspace workspace in controller.workspaces)
                    DropdownMenuItem<String>(
                      value: workspace.uuid,
                      child: Text(
                        workspace.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (String? uuid) {
                  Workspace? workspace;
                  for (final Workspace candidate in controller.workspaces) {
                    if (candidate.uuid == uuid) {
                      workspace = candidate;
                      break;
                    }
                  }
                  controller.selectWorkspace(workspace);
                },
              ),
            ),
          ),
        ],
      ),
      Expanded(child: _threadBody(context)),
    ],
  );

  Widget _threadBody(BuildContext context) {
    if (!controller.isConnected)
      return const _PanelMessage(
        'Threads are available when the engine is connected.',
      );
    if (controller.selectedWorkspace == null)
      return const _PanelMessage('Choose a workspace to see its threads.');
    if (controller.isLoadingThreads)
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    if (controller.threadsError case final Object error) {
      return _PanelMessage(
        "Couldn't load threads\n$error",
        action: OutlinedButton(
          onPressed: () =>
              controller.selectWorkspace(controller.selectedWorkspace),
          child: const Text('Retry'),
        ),
      );
    }
    if (controller.threads.isEmpty)
      return const _PanelMessage('No threads yet.');
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      itemCount: controller.threads.length,
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: 4),
      itemBuilder: (BuildContext context, int index) {
        final ThreadInfo thread = controller.threads[index];
        final bool selected = controller.selectedThread?.uuid == thread.uuid;
        return _NavigationRow(
          selected: selected,
          label: thread.title?.trim().isNotEmpty ?? false
              ? thread.title!
              : 'Untitled thread',
          onTap: () => controller.selectThread(thread),
        );
      },
    );
  }
}

final class _NavigationRow extends StatelessWidget {
  const _NavigationRow({
    required this.selected,
    required this.label,
    required this.onTap,
    this.subtitle,
  });

  final bool selected;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Material(
      color: selected ? colors.secondaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 16,
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: 4,
                    height: subtitle == null ? 24 : 30,
                    decoration: BoxDecoration(
                      color: selected ? colors.primary : Colors.transparent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (subtitle case final String subtitle)
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

final class _WorkspacesSection extends StatelessWidget {
  const _WorkspacesSection({required this.controller});

  final DashboardController controller;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      _SectionHeader(
        title: 'Workspaces',
        actions: <Widget>[
          IconButton(
            tooltip: 'New workspace',
            icon: const Icon(FluentIcons.add_20_regular, size: 18),
            onPressed: controller.isConnected
                ? () => _showWorkspaceDialog(context, controller)
                : null,
          ),
        ],
      ),
      Expanded(child: _workspaceBody(context)),
    ],
  );

  Widget _workspaceBody(BuildContext context) {
    if (controller.isLoadingWorkspaces)
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    if (controller.workspacesError case final Object error) {
      return _PanelMessage(
        "Couldn't load workspaces\n$error",
        action: OutlinedButton(
          onPressed: controller.loadWorkspaces,
          child: const Text('Retry'),
        ),
      );
    }
    if (!controller.isConnected && controller.workspaces.isEmpty)
      return const _PanelMessage(
        'Workspaces are available when the engine is connected.',
      );
    if (controller.workspaces.isEmpty)
      return const _PanelMessage('No workspaces yet.');
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      itemCount: controller.workspaces.length,
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int index) {
        final Workspace workspace = controller.workspaces[index];
        return Stack(
          children: <Widget>[
            _NavigationRow(
              selected: controller.selectedWorkspace?.uuid == workspace.uuid,
              label: workspace.name,
              subtitle: workspace.description?.trim().isEmpty ?? true
                  ? null
                  : workspace.description,
              onTap: () => controller.selectWorkspace(workspace),
            ),
            Positioned(
              right: 2,
              top: 2,
              child: IconButton(
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
                padding: EdgeInsets.zero,
                tooltip: 'Edit workspace',
                icon: const Icon(FluentIcons.edit_20_regular, size: 15),
                onPressed: () => _showWorkspaceDialog(
                  context,
                  controller,
                  workspace: workspace,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

Future<void> _showWorkspaceDialog(
  BuildContext context,
  DashboardController controller, {
  Workspace? workspace,
}) async {
  final TextEditingController nameController = TextEditingController(
    text: workspace?.name,
  );
  final TextEditingController descriptionController = TextEditingController(
    text: workspace?.description,
  );
  final _WorkspaceDraft? draft = await showDialog<_WorkspaceDraft>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(workspace == null ? 'New workspace' : 'Edit workspace'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: descriptionController,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Description'),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final String name = nameController.text.trim();
            if (name.isNotEmpty)
              Navigator.pop(
                context,
                _WorkspaceDraft(name, descriptionController.text.trim()),
              );
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
  nameController.dispose();
  descriptionController.dispose();
  if (draft == null || !context.mounted) return;
  try {
    if (workspace == null) {
      await controller.createWorkspace(
        name: draft.name,
        description: draft.description.isEmpty ? null : draft.description,
      );
    } else {
      await controller.updateWorkspace(
        workspace,
        name: draft.name,
        description: draft.description.isEmpty ? null : draft.description,
      );
    }
  } on Object catch (error) {
    if (context.mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't save workspace: $error")),
      );
  }
}

final class _WorkspaceDraft {
  const _WorkspaceDraft(this.name, this.description);

  final String name;
  final String description;
}

final class _FilesSection extends StatelessWidget {
  const _FilesSection({required this.controller});

  final DashboardController controller;

  @override
  Widget build(BuildContext context) {
    final List<WorkspaceDirectoryRoot> roots = controller.fileRoots;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionHeader(
          title: 'Files',
          actions: <Widget>[
            IconButton(
              tooltip: 'Refresh files',
              icon: const Icon(
                FluentIcons.arrow_clockwise_20_regular,
                size: 18,
              ),
              onPressed: roots.isEmpty ? null : controller.refreshFiles,
            ),
            IconButton(
              tooltip: 'Create a file',
              icon: const Icon(FluentIcons.document_add_20_regular, size: 18),
              onPressed: roots.isEmpty
                  ? null
                  : () => _showCreateEntryDialog(
                      context,
                      controller,
                      isDirectory: false,
                    ),
            ),
            IconButton(
              tooltip: 'Create a folder',
              icon: const Icon(FluentIcons.folder_add_20_regular, size: 18),
              onPressed: roots.isEmpty
                  ? null
                  : () => _showCreateEntryDialog(
                      context,
                      controller,
                      isDirectory: true,
                    ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Text(
            controller.selectedWorkspace == null
                ? 'Select a workspace in Threads to browse its allowed folders.'
                : roots.isEmpty
                ? 'This workspace has no allowed folders.'
                : '${roots.length} allowed folder${roots.length == 1 ? '' : 's'}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (controller.filesError case final Object error)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Text(
              '$error',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        Expanded(
          child: controller.selectedWorkspace == null
              ? const _PanelMessage('No workspace selected.')
              : roots.isEmpty
              ? const _PanelMessage(
                  'Add an allowed folder in Workspace settings.',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                  children: <Widget>[
                    for (final WorkspaceDirectoryRoot root in roots)
                      _DirectoryNode(
                        controller: controller,
                        rootIndex: root.index,
                        path: '',
                        label: root.name,
                        isRoot: true,
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

final class _DirectoryNode extends StatefulWidget {
  const _DirectoryNode({
    required this.controller,
    required this.rootIndex,
    required this.path,
    required this.label,
    this.isRoot = false,
  });

  final DashboardController controller;
  final int rootIndex;
  final String path;
  final String label;
  final bool isRoot;

  @override
  State<_DirectoryNode> createState() => _DirectoryNodeState();
}

final class _DirectoryNodeState extends State<_DirectoryNode> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.isRoot;
    if (_expanded)
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.controller.loadDirectory(widget.rootIndex, widget.path),
      );
  }

  @override
  Widget build(BuildContext context) {
    final List<WorkspaceFileEntry>? entries = widget.controller
        .directoryEntries(widget.rootIndex, widget.path);
    final bool loading = widget.controller.isDirectoryLoading(
      widget.rootIndex,
      widget.path,
    );
    return ExpansionTile(
      initiallyExpanded: widget.isRoot,
      tilePadding: EdgeInsets.only(left: widget.isRoot ? 8 : 16, right: 8),
      childrenPadding: const EdgeInsets.only(left: 12),
      leading: Icon(
        widget.isRoot
            ? FluentIcons.folder_20_filled
            : FluentIcons.folder_20_regular,
        size: 17,
      ),
      title: Text(
        widget.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onExpansionChanged: (bool expanded) {
        _expanded = expanded;
        if (expanded && entries == null)
          widget.controller.loadDirectory(widget.rootIndex, widget.path);
      },
      children: <Widget>[
        if (_expanded && loading)
          const Padding(
            padding: EdgeInsets.all(12),
            child: SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (_expanded && entries != null && entries.isEmpty)
          const ListTile(dense: true, title: Text('Empty folder'))
        else if (_expanded && entries != null)
          for (final WorkspaceFileEntry entry in entries)
            if (entry.isDirectory)
              _DirectoryNode(
                controller: widget.controller,
                rootIndex: widget.rootIndex,
                path: entry.relativePath,
                label: entry.name,
              )
            else
              ListTile(
                dense: true,
                leading: const Icon(FluentIcons.document_20_regular, size: 16),
                title: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                selected:
                    widget.controller.openFile?.rootIndex == widget.rootIndex &&
                    widget.controller.openFile?.path == entry.relativePath,
                onTap: () => widget.controller.openWorkspaceFile(
                  widget.rootIndex,
                  entry.relativePath,
                ),
              ),
      ],
    );
  }
}

Future<void> _showCreateEntryDialog(
  BuildContext context,
  DashboardController controller, {
  required bool isDirectory,
}) async {
  final List<WorkspaceDirectoryRoot> roots = controller.fileRoots;
  if (roots.isEmpty) return;
  int rootIndex = roots.first.index;
  final TextEditingController pathController = TextEditingController(
    text: isDirectory ? 'notes/new-folder' : 'notes/new-note.md',
  );
  final _FileEntryDraft? draft = await showDialog<_FileEntryDraft>(
    context: context,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter setState) => AlertDialog(
        title: Text(isDirectory ? 'New folder' : 'New file'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              DropdownButtonFormField<int>(
                initialValue: rootIndex,
                decoration: const InputDecoration(labelText: 'Allowed folder'),
                items: <DropdownMenuItem<int>>[
                  for (final WorkspaceDirectoryRoot root in roots)
                    DropdownMenuItem<int>(
                      value: root.index,
                      child: Text(root.path, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (int? value) =>
                    setState(() => rootIndex = value ?? rootIndex),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pathController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Relative path'),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final String path = pathController.text.trim();
              if (path.isNotEmpty)
                Navigator.pop(context, _FileEntryDraft(rootIndex, path));
            },
            child: const Text('Create'),
          ),
        ],
      ),
    ),
  );
  pathController.dispose();
  if (draft == null || !context.mounted) return;
  try {
    if (isDirectory) {
      await controller.createDirectory(
        rootIndex: draft.rootIndex,
        path: draft.path,
      );
    } else {
      await controller.createFile(rootIndex: draft.rootIndex, path: draft.path);
    }
  } on Object catch (error) {
    if (context.mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Couldn't create ${isDirectory ? 'folder' : 'file'}: $error",
          ),
        ),
      );
  }
}

final class _FileEntryDraft {
  const _FileEntryDraft(this.rootIndex, this.path);

  final int rootIndex;
  final String path;
}

final class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.controller});

  final DashboardSettingsController controller;

  static const List<(String, IconData, SettingsPage)> _pages =
      <(String, IconData, SettingsPage)>[
        (
          'General Settings',
          FluentIcons.settings_20_regular,
          SettingsPage.general,
        ),
        ('Models', FluentIcons.bot_20_regular, SettingsPage.models),
        ('Tools', FluentIcons.toolbox_20_regular, SettingsPage.tools),
        ('Skills', FluentIcons.book_toolbox_20_regular, SettingsPage.skills),
        ('About', FluentIcons.info_20_regular, SettingsPage.about),
      ];

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (BuildContext context, Widget? child) => Column(
      children: <Widget>[
        const _SectionHeader(title: 'Settings'),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            itemCount: _pages.length,
            separatorBuilder: (BuildContext context, int index) =>
                const SizedBox(height: 8),
            itemBuilder: (BuildContext context, int index) {
              final (String, IconData, SettingsPage) page = _pages[index];
              return _NavigationRow(
                selected:
                    controller.destination == MainPanelDestination.settings &&
                    controller.activePage == page.$3,
                label: page.$1,
                onTap: () => controller.openSettingsPage(page.$3),
              );
            },
          ),
        ),
      ],
    ),
  );
}

final class _AccountSection extends StatelessWidget {
  const _AccountSection();

  @override
  Widget build(BuildContext context) => const Column(
    children: <Widget>[
      _SectionHeader(title: 'Account'),
      Expanded(child: _PanelMessage('Account details — coming soon')),
    ],
  );
}

final class WorkspaceFileEditor extends StatefulWidget {
  const WorkspaceFileEditor({required this.controller, super.key});

  final DashboardController controller;

  @override
  State<WorkspaceFileEditor> createState() => _WorkspaceFileEditorState();
}

final class _WorkspaceFileEditorState extends State<WorkspaceFileEditor> {
  final TextEditingController _textController = TextEditingController();
  String? _loadedFileKey;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _syncFile();
  }

  @override
  void didUpdateWidget(covariant WorkspaceFileEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _syncFile();
    }
  }

  void _onControllerChanged() {
    _syncFile();
    if (mounted) setState(() {});
  }

  void _syncFile() {
    final OpenWorkspaceFile? file = widget.controller.openFile;
    final String? key = file == null ? null : '${file.rootIndex}:${file.path}';
    if (key != _loadedFileKey) {
      _loadedFileKey = key;
      _textController.value = TextEditingValue(
        text: file?.content ?? '',
        selection: TextSelection.collapsed(offset: file?.content.length ?? 0),
      );
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final OpenWorkspaceFile? file = widget.controller.openFile;
    if (widget.controller.isLoadingFile)
      return const ColoredBox(
        color: Colors.white,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    if (file == null) {
      return ColoredBox(
        color: Colors.white,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'Main panel',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Select a file from the context panel to open it here.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }
    return ColoredBox(
      color: Colors.white,
      child: Column(
        children: <Widget>[
          SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: <Widget>[
                  const Icon(FluentIcons.document_20_regular, size: 17),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      file.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: widget.controller.isSavingFile
                        ? null
                        : () => widget.controller.saveOpenFile(
                            _textController.text,
                          ),
                    icon: widget.controller.isSavingFile
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
          ),
          const Divider(height: 1),
          Expanded(
            child: TextField(
              controller: _textController,
              expands: true,
              maxLines: null,
              minLines: null,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.45,
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.all(16),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
