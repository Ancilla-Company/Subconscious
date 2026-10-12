import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../dashboard/controller/dashboard_controller.dart';
import '../../editor/controller/file_gateway.dart' show PreviewKind;
import '../../settings/controller/settings_controller.dart';
import '../../settings/presentation/settings_main_panel.dart';

final class ContextPanel extends StatefulWidget {
  const ContextPanel({
    required this.screen,
    required this.controller,
    this.onSelection,
    super.key,
  });

  final DashboardSection screen;
  final DashboardController controller;
  final VoidCallback? onSelection;

  @override
  State<ContextPanel> createState() => _ContextPanelState();
}

final class _ContextPanelState extends State<ContextPanel> {
  DashboardSection? _observedSection;
  Object? _observedError;
  int _toastVersion = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _observePanelError();
  }

  @override
  void didUpdateWidget(covariant ContextPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _observedSection = null;
      _observedError = null;
    }
    if (oldWidget.screen != widget.screen ||
        oldWidget.controller != widget.controller) {
      _observePanelError();
    }
  }

  void _onControllerChanged() => _observePanelError();

  void _observePanelError() {
    final DashboardSection section = widget.screen;
    if (_observedSection != section) {
      _observedSection = section;
      _observedError = null;
    }
    final (Object?, String) errorInfo = switch (section) {
      DashboardSection.threads => (
        widget.controller.threadsError,
        "Couldn't load threads",
      ),
      DashboardSection.files => (
        widget.controller.filesError,
        "Couldn't complete the file operation",
      ),
      DashboardSection.workspaces => (
        widget.controller.workspacesError,
        "Couldn't load workspaces",
      ),
      _ => (null, ''),
    };
    final Object? error = errorInfo.$1;
    if (error == null) {
      _observedError = null;
      _toastVersion++;
      return;
    }
    if (identical(error, _observedError)) return;
    _observedError = error;
    final bool isUnsupportedPreview =
        section == DashboardSection.files && _isUnsupportedPreviewError(error);
    final int version = ++_toastVersion;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || version != _toastVersion) return;
      _showPanelToast(
        context,
        isUnsupportedPreview
            ? 'Preview is not supported for this file type.'
            : '${errorInfo.$2}: $error',
        isError: !isUnsupportedPreview,
        duration: isUnsupportedPreview
            ? const Duration(seconds: 3)
            : const Duration(seconds: 5),
      );
    });
  }

  @override
  void dispose() {
    _toastVersion++;
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: AnimatedBuilder(
      animation: widget.controller,
      builder: (BuildContext context, Widget? child) => switch (widget.screen) {
        DashboardSection.threads => _ThreadsSection(
          controller: widget.controller,
          onSelection: widget.onSelection,
        ),
        DashboardSection.files => _FilesSection(
          controller: widget.controller,
          onSelection: widget.onSelection,
        ),
        DashboardSection.workspaces => _WorkspacesSection(
          controller: widget.controller,
          onSelection: widget.onSelection,
        ),
        DashboardSection.settings => _SettingsSection(
          controller: widget.controller,
          onSelection: widget.onSelection,
        ),
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

final class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.onSelection,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final VoidCallback? onSelection;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 4, 2, 0),
    child: IconButton(
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      onPressed: onPressed == null
          ? null
          : () {
              onPressed!();
              onSelection?.call();
            },
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      tooltip: tooltip,
      icon: Icon(icon, size: 20),
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
  const _ThreadsSection({required this.controller, this.onSelection});

  final DashboardController controller;
  final VoidCallback? onSelection;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      _SectionHeader(
        title: 'Threads',
        actions: <Widget>[
          if (kIsWeb ||
              defaultTargetPlatform != TargetPlatform.windows) ...<Widget>[
            const Icon(FluentIcons.folder_20_regular, size: 16),
            const SizedBox(width: 6),
            SizedBox(
              width: 142,
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: controller.threadsWorkspace?.uuid ?? '',
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
                    controller.selectThreadWorkspace(workspace);
                    onSelection?.call();
                  },
                ),
              ),
            ),
          ],
        ],
      ),
      Expanded(child: _threadBody(context)),
    ],
  );

  Widget _threadBody(BuildContext context) {
    if (!controller.isConnected) {
      return const _PanelMessage(
        'Threads are available when the engine is connected.',
      );
    }
    if (controller.threadsWorkspace == null) {
      return const _PanelMessage(
        'Choose a workspace in the title bar to see its threads.',
      );
    }
    if (controller.isLoadingThreads) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (controller.threadsError != null) {
      return _PanelMessage(
        "Couldn't load threads.",
        action: OutlinedButton(
          onPressed: () {
            controller.selectThreadWorkspace(
              controller.threadsWorkspace,
              remember: false,
            );
            onSelection?.call();
          },
          child: const Text('Retry'),
        ),
      );
    }
    if (controller.threads.isEmpty) {
      return const _PanelMessage('No threads yet.');
    }
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
          onSelection: onSelection,
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
    this.onSelection,
    this.subtitle,
  });

  final bool selected;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onSelection;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Material(
      color: selected ? colors.secondaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () {
          onTap();
          onSelection?.call();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: <Widget>[
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
  const _WorkspacesSection({required this.controller, this.onSelection});

  final DashboardController controller;
  final VoidCallback? onSelection;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      _SectionHeader(
        title: 'Workspaces',
        actions: <Widget>[
          _HeaderButton(
            tooltip: 'New workspace',
            icon: FluentIcons.add_20_regular,
            onPressed: controller.isConnected
                ? controller.beginWorkspaceCreation
                : null,
            onSelection: onSelection,
          ),
        ],
      ),
      Expanded(child: _workspaceBody(context)),
    ],
  );

  Widget _workspaceBody(BuildContext context) {
    if (controller.isLoadingWorkspaces) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (controller.workspacesError != null) {
      return _PanelMessage(
        "Couldn't load workspaces.",
        action: OutlinedButton(
          onPressed: () {
            controller.loadWorkspaces();
            onSelection?.call();
          },
          child: const Text('Retry'),
        ),
      );
    }
    if (!controller.isConnected && controller.workspaces.isEmpty) {
      return const _PanelMessage(
        'Workspaces are available when the engine is connected.',
      );
    }
    if (controller.workspaces.isEmpty) {
      return const _PanelMessage('No workspaces yet.');
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      itemCount: controller.workspaces.length,
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int index) {
        final Workspace workspace = controller.workspaces[index];
        return _NavigationRow(
          selected: controller.selectedWorkspace?.uuid == workspace.uuid,
          label: workspace.name,
          subtitle: workspace.description?.trim().isEmpty ?? true
              ? null
              : workspace.description,
          onTap: () async {
            await controller.selectWorkspace(workspace);
            if (controller.selectedSection == DashboardSection.workspaces) {
              controller.settings.showWorkspace();
            }
            onSelection?.call();
          },
        );
      },
    );
  }
}

final class _FilesSection extends StatelessWidget {
  const _FilesSection({required this.controller, this.onSelection});

  final DashboardController controller;
  final VoidCallback? onSelection;

  @override
  Widget build(BuildContext context) {
    final List<WorkspaceDirectoryRoot> roots = controller.fileRoots;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _SectionHeader(
          title: 'Files',
          actions: <Widget>[
            _HeaderButton(
              tooltip: 'Refresh files',
              icon: FluentIcons.arrow_clockwise_20_regular,
              onPressed: roots.isEmpty ? null : controller.refreshFiles,
              onSelection: onSelection,
            ),
            _HeaderButton(
              tooltip: 'Create a file',
              icon: FluentIcons.document_add_20_regular,
              onPressed: roots.isEmpty
                  ? null
                  : () => _createWorkspaceFile(context, controller),
              onSelection: onSelection,
            ),
            _HeaderButton(
              tooltip: 'Create a folder',
              icon: FluentIcons.folder_add_20_regular,
              onPressed: roots.isEmpty
                  ? null
                  : () => _createWorkspaceFolder(context, controller),
              onSelection: onSelection,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Text(
            controller.activeWorkspace == null
                ? 'Select a workspace in Threads to browse its allowed folders.'
                : roots.isEmpty
                ? 'This workspace has no allowed folders.'
                : '${roots.length} allowed folder${roots.length == 1 ? '' : 's'}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: controller.activeWorkspace == null
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
                        key: ValueKey<String>(
                          '${controller.activeWorkspace?.uuid}:${root.index}',
                        ),
                        controller: controller,
                        rootIndex: root.index,
                        path: '',
                        label: root.name,
                        isRoot: true,
                        onSelection: onSelection,
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

final class _WorkspaceFileTreeDragData {
  const _WorkspaceFileTreeDragData({
    required this.rootIndex,
    required this.path,
    required this.isDirectory,
    required this.label,
  });

  final int rootIndex;
  final String path;
  final bool isDirectory;
  final String label;
}

final class _DirectoryNode extends StatefulWidget {
  const _DirectoryNode({
    required this.controller,
    required this.rootIndex,
    required this.path,
    required this.label,
    this.isRoot = false,
    this.depth = 0,
    this.onSelection,
    super.key,
  });

  final DashboardController controller;
  final int rootIndex;
  final String path;
  final String label;
  final bool isRoot;
  final int depth;
  final VoidCallback? onSelection;

  @override
  State<_DirectoryNode> createState() => _DirectoryNodeState();
}

final class _DirectoryNodeState extends State<_DirectoryNode> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.controller.isDirectoryExpanded(
      widget.rootIndex,
      widget.path,
      defaultValue: widget.isRoot,
    );
    if (_expanded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _expanded) {
          widget.controller.loadDirectory(widget.rootIndex, widget.path);
        }
      });
    }
  }

  void _toggle(List<WorkspaceFileEntry>? entries) {
    widget.controller.selectFileTreeNode(
      widget.rootIndex,
      widget.path,
      isDirectory: true,
    );
    final bool expanded = !_expanded;
    setState(() => _expanded = expanded);
    widget.controller.setDirectoryExpanded(
      widget.rootIndex,
      widget.path,
      expanded,
    );
    if (expanded && entries == null) {
      widget.controller.loadDirectory(widget.rootIndex, widget.path);
    }
  }

  bool _canAcceptDrop(_WorkspaceFileTreeDragData source) =>
      widget.controller.canMoveWorkspaceNode(
        sourceRootIndex: source.rootIndex,
        sourcePath: source.path,
        sourceIsDirectory: source.isDirectory,
        destinationRootIndex: widget.rootIndex,
        destinationPath: widget.path,
      );

  void _acceptDrop(_WorkspaceFileTreeDragData source) {
    unawaited(
      widget.controller.moveWorkspaceNode(
        sourceRootIndex: source.rootIndex,
        sourcePath: source.path,
        sourceIsDirectory: source.isDirectory,
        destinationRootIndex: widget.rootIndex,
        destinationPath: widget.path,
      ),
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
    final bool selected =
        widget.controller.selectedFileTreeNodeKey ==
        widget.controller.fileTreeNodeKey(widget.rootIndex, widget.path);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _FileTreeRow(
          depth: widget.depth,
          selected: selected,
          onTap: () => _toggle(entries),
          leading: Icon(
            widget.isRoot
                ? FluentIcons.folder_20_filled
                : FluentIcons.folder_20_regular,
            size: 16,
          ),
          label: widget.label,
          dragData: widget.isRoot || widget.controller.isMovingWorkspaceNode
              ? null
              : _WorkspaceFileTreeDragData(
                  rootIndex: widget.rootIndex,
                  path: widget.path,
                  isDirectory: true,
                  label: widget.label,
                ),
          canAcceptDrop: _canAcceptDrop,
          onAcceptDrop: _acceptDrop,
          trailing: AnimatedRotation(
            turns: _expanded ? 0.25 : 0,
            duration: const Duration(milliseconds: 120),
            child: const Icon(FluentIcons.chevron_right_20_regular, size: 14),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 140),
          alignment: Alignment.topCenter,
          child: !_expanded
              ? const SizedBox.shrink()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (loading)
                      _FileTreeRow(
                        depth: widget.depth + 1,
                        selected: false,
                        onTap: null,
                        leading: const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                        label: 'Loading…',
                      )
                    else if (entries != null && entries.isEmpty)
                      _FileTreeRow(
                        depth: widget.depth + 1,
                        selected: false,
                        onTap: null,
                        leading: const SizedBox(width: 16),
                        label: 'Empty folder',
                      )
                    else if (entries != null)
                      for (final WorkspaceFileEntry entry in entries)
                        if (entry.isDirectory)
                          _DirectoryNode(
                            key: ValueKey<String>(
                              '${widget.rootIndex}:${entry.relativePath}',
                            ),
                            controller: widget.controller,
                            rootIndex: widget.rootIndex,
                            path: entry.relativePath,
                            label: entry.name,
                            depth: widget.depth + 1,
                            onSelection: widget.onSelection,
                          )
                        else
                          _FileTreeRow(
                            key: ValueKey<String>(
                              '${widget.rootIndex}:${entry.relativePath}',
                            ),
                            depth: widget.depth + 1,
                            selected:
                                widget.controller.selectedFileTreeNodeKey ==
                                widget.controller.fileTreeNodeKey(
                                  widget.rootIndex,
                                  entry.relativePath,
                                ),
                            onTap: () {
                              widget.controller.openWorkspaceFile(
                                widget.rootIndex,
                                entry.relativePath,
                              );
                              widget.onSelection?.call();
                            },
                            leading: Icon(
                              PreviewKind.forPath(entry.relativePath) != null
                                  ? FluentIcons.image_20_regular
                                  : FluentIcons.document_20_regular,
                              size: 16,
                            ),
                            label: entry.name,
                            dragData: widget.controller.isMovingWorkspaceNode
                                ? null
                                : _WorkspaceFileTreeDragData(
                                    rootIndex: widget.rootIndex,
                                    path: entry.relativePath,
                                    isDirectory: false,
                                    label: entry.name,
                                  ),
                          ),
                  ],
                ),
        ),
      ],
    );
  }
}

final class _FileTreeRow extends StatelessWidget {
  const _FileTreeRow({
    required this.depth,
    required this.selected,
    required this.onTap,
    required this.leading,
    required this.label,
    this.trailing,
    this.dragData,
    this.canAcceptDrop,
    this.onAcceptDrop,
    super.key,
  });

  final int depth;
  final bool selected;
  final VoidCallback? onTap;
  final Widget leading;
  final String label;
  final Widget? trailing;
  final _WorkspaceFileTreeDragData? dragData;
  final bool Function(_WorkspaceFileTreeDragData source)? canAcceptDrop;
  final ValueChanged<_WorkspaceFileTreeDragData>? onAcceptDrop;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    Widget buildRow(bool dropHighlighted) {
      final bool emphasized = selected || dropHighlighted;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: emphasized ? colors.secondaryContainer : Colors.transparent,
          borderRadius: const BorderRadius.all(Radius.circular(4)),
          child: InkWell(
            borderRadius: const BorderRadius.all(Radius.circular(4)),
            onTap: onTap,
            child: SizedBox(
              height: 30,
              child: Padding(
                padding: EdgeInsets.only(left: 6 + depth * 14, right: 6),
                child: Row(
                  children: <Widget>[
                    SizedBox(width: 18, child: Center(child: leading)),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Tooltip(
                        message: label,
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: emphasized
                                    ? colors.onSecondaryContainer
                                    : null,
                              ),
                        ),
                      ),
                    ),
                    if (trailing != null) ...<Widget>[
                      const SizedBox(width: 4),
                      trailing!,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final ValueChanged<_WorkspaceFileTreeDragData>? acceptDrop = onAcceptDrop;
    Widget result = acceptDrop == null
        ? buildRow(false)
        : DragTarget<_WorkspaceFileTreeDragData>(
            onWillAcceptWithDetails: (
              DragTargetDetails<_WorkspaceFileTreeDragData> details,
            ) => canAcceptDrop?.call(details.data) ?? false,
            onAcceptWithDetails: (
              DragTargetDetails<_WorkspaceFileTreeDragData> details,
            ) => acceptDrop(details.data),
            builder: (
              BuildContext context,
              List<_WorkspaceFileTreeDragData?> candidateData,
              List<dynamic> rejectedData,
            ) => buildRow(candidateData.isNotEmpty),
          );
    final _WorkspaceFileTreeDragData? source = dragData;
    if (source != null) {
      result = LongPressDraggable<_WorkspaceFileTreeDragData>(
        data: source,
        feedback: Material(
          elevation: 6,
          borderRadius: const BorderRadius.all(Radius.circular(4)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                source.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.45, child: result),
        child: result,
      );
    }
    return result;
  }
}

Future<void> _createWorkspaceFile(
  BuildContext context,
  DashboardController controller,
) async {
  final List<WorkspaceDirectoryRoot> roots = controller.fileRoots;
  if (roots.isEmpty) return;
  final ({int rootIndex, String path})? selectedLocation =
      controller.selectedCreationDirectory;
  final WorkspaceDirectoryRoot root = roots.firstWhere(
    (WorkspaceDirectoryRoot candidate) =>
        candidate.index == selectedLocation?.rootIndex,
    orElse: () => roots.first,
  );
  final String parentPath = root.index == selectedLocation?.rootIndex
      ? selectedLocation!.path
      : '';
  try {
    final file_selector.FileSaveLocation? location = await file_selector
        .getSaveLocation(
          suggestedName: 'new-file.md',
          initialDirectory: _workspaceAbsolutePath(root.path, parentPath),
        );
    if (location == null || !context.mounted) return;
    final ({int rootIndex, String relativePath})? mapped = _mapWorkspacePath(
      location.path,
      roots,
      requireRelativePath: true,
    );
    if (mapped == null) {
      _showFileActionMessage(
        context,
        'Choose a file inside one of this workspace’s allowed folders.',
      );
      return;
    }
    await controller.createFile(
      rootIndex: mapped.rootIndex,
      path: mapped.relativePath,
    );
  } on Object catch (error) {
    if (context.mounted) {
      _showFileActionMessage(context, "Couldn't create file: $error");
    }
  }
}

Future<void> _createWorkspaceFolder(
  BuildContext context,
  DashboardController controller,
) async {
  final List<WorkspaceDirectoryRoot> roots = controller.fileRoots;
  if (roots.isEmpty) return;
  final ({int rootIndex, String path})? selectedLocation =
      controller.selectedCreationDirectory;
  final ({int rootIndex, String path})? request = await _showCreateFolderDialog(
    context,
    roots,
    initialLocation: selectedLocation,
  );
  if (request == null || !context.mounted) return;
  try {
    await controller.createDirectory(
      rootIndex: request.rootIndex,
      path: request.path,
    );
  } on Object catch (error) {
    if (context.mounted) {
      _showFileActionMessage(context, "Couldn't create folder: $error");
    }
  }
}

Future<({int rootIndex, String path})?> _showCreateFolderDialog(
  BuildContext context,
  List<WorkspaceDirectoryRoot> roots, {
  ({int rootIndex, String path})? initialLocation,
}) async {
  final TextEditingController pathController = TextEditingController(
    text: initialLocation?.path.isNotEmpty == true
        ? '${initialLocation!.path}/'
        : '',
  );
  WorkspaceDirectoryRoot selectedRoot = roots.first;
  for (final WorkspaceDirectoryRoot root in roots) {
    if (root.index == initialLocation?.rootIndex) {
      selectedRoot = root;
      break;
    }
  }
  String? validationError;
  try {
    return await showDialog<({int rootIndex, String path})>(
      context: context,
      builder: (BuildContext context) => Theme(
        data: settingsFormTheme(context),
        child: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) => AlertDialog(
            backgroundColor: Theme.of(context).colorScheme.surface,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(6)),
            ),
            title: const Text('New folder'),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  DropdownButtonFormField<int>(
                    initialValue: selectedRoot.index,
                    decoration: const InputDecoration(labelText: 'Location'),
                    items: <DropdownMenuItem<int>>[
                      for (final WorkspaceDirectoryRoot root in roots)
                        DropdownMenuItem<int>(
                          value: root.index,
                          child: Text(
                            root.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (int? rootIndex) {
                      if (rootIndex == null) return;
                      setState(() {
                        selectedRoot = roots.firstWhere(
                          (WorkspaceDirectoryRoot root) =>
                              root.index == rootIndex,
                        );
                        pathController.clear();
                        validationError = null;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: pathController,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: 'Folder name',
                      hintText: 'e.g. notes or src/components',
                      errorText: validationError,
                    ),
                    onChanged: (_) {
                      if (validationError != null) {
                        setState(() => validationError = null);
                      }
                    },
                    onSubmitted: (_) {
                      final String? path = _workspaceRelativeFolderPath(
                        pathController.text,
                      );
                      if (path == null) {
                        setState(
                          () => validationError = 'Enter a relative folder name without . or .. segments.',
                        );
                        return;
                      }
                      Navigator.of(context)
                          .pop((rootIndex: selectedRoot.index, path: path));
                    },
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final String? path = _workspaceRelativeFolderPath(
                    pathController.text,
                  );
                  if (path == null) {
                    setState(
                      () => validationError = 'Enter a relative folder name without . or .. segments.',
                    );
                    return;
                  }
                  Navigator.of(context)
                      .pop((rootIndex: selectedRoot.index, path: path));
                },
                child: const Text('Create'),
              ),
            ],
          ),
        ),
      ),
    );
  } finally {
    pathController.dispose();
  }
}

String? _workspaceRelativeFolderPath(String value) {
  final String normalized = value.trim().replaceAll('\\', '/');
  if (normalized.isEmpty ||
      normalized.startsWith('/') ||
      normalized.contains(':')) {
    return null;
  }
  final List<String> parts = normalized.split('/');
  if (parts.any((String part) => part.isEmpty || part == '.' || part == '..')) {
    return null;
  }
  return normalized;
}

/// Returns the absolute directory path to hand to a native file dialog.
///
/// Relative paths from the engine always use `/`, while a root path is kept
/// exactly as the user entered it. Windows' shell rejects any path containing
/// `/`, and the file dialog plugin then silently ignores the initial directory,
/// so on Windows the whole path is rewritten with `\`. Other platforms keep the
/// root untouched because `\` is a valid file name character there.
String _workspaceAbsolutePath(String rootPath, String relativePath) {
  final bool windows = defaultTargetPlatform == TargetPlatform.windows;
  final String separator = windows ? r'\' : '/';
  final String root = windows ? rootPath.replaceAll('/', r'\') : rootPath;
  if (relativePath.isEmpty) return root;
  final String relative = windows
      ? relativePath.replaceAll('/', r'\')
      : relativePath;
  return root.endsWith(separator)
      ? '$root$relative'
      : '$root$separator$relative';
}

({int rootIndex, String relativePath})? _mapWorkspacePath(
  String selectedPath,
  List<WorkspaceDirectoryRoot> roots, {
  required bool requireRelativePath,
}) {
  final String? selected = _normalizeAbsolutePath(selectedPath);
  if (selected == null) return null;
  final bool ignoreCase = defaultTargetPlatform == TargetPlatform.windows;
  final String comparableSelected = ignoreCase
      ? selected.toLowerCase()
      : selected;
  ({int rootIndex, String relativePath, int rootLength})? bestMatch;
  for (final WorkspaceDirectoryRoot root in roots) {
    final String? normalizedRoot = _normalizeAbsolutePath(root.path);
    if (normalizedRoot == null) continue;
    final String comparableRoot = ignoreCase
        ? normalizedRoot.toLowerCase()
        : normalizedRoot;
    final String prefix = comparableRoot.endsWith('/')
        ? comparableRoot
        : '$comparableRoot/';
    final String? relativePath;
    if (comparableSelected == comparableRoot) {
      relativePath = '';
    } else if (comparableSelected.startsWith(prefix)) {
      relativePath = selected.substring(prefix.length);
    } else {
      relativePath = null;
    }
    if (relativePath == null ||
        (requireRelativePath && relativePath.isEmpty) ||
        (bestMatch != null && bestMatch.rootLength >= normalizedRoot.length)) {
      continue;
    }
    bestMatch = (
      rootIndex: root.index,
      relativePath: relativePath,
      rootLength: normalizedRoot.length,
    );
  }
  if (bestMatch == null) return null;
  return (rootIndex: bestMatch.rootIndex, relativePath: bestMatch.relativePath);
}

String? _normalizeAbsolutePath(String rawPath) {
  final String value = rawPath.trim().replaceAll('\\', '/');
  final RegExp drivePattern = RegExp(r'^[A-Za-z]:/');
  final bool isDrive = drivePattern.hasMatch(value);
  final bool isUnc = value.startsWith('//');
  final bool isPosix = value.startsWith('/');
  if (value.isEmpty || (!isDrive && !isUnc && !isPosix)) return null;

  final String prefix;
  final String remainder;
  final int protectedSegments;
  if (isDrive) {
    prefix = '${value.substring(0, 2)}/';
    remainder = value.substring(3);
    protectedSegments = 0;
  } else if (isUnc) {
    prefix = '//';
    remainder = value.substring(2);
    protectedSegments = 2;
  } else {
    prefix = '/';
    remainder = value.substring(1);
    protectedSegments = 0;
  }

  final List<String> segments = <String>[];
  for (final String segment in remainder.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.length <= protectedSegments) return null;
      segments.removeLast();
    } else {
      segments.add(segment);
    }
  }
  if (isUnc && segments.length < protectedSegments) return null;
  return segments.isEmpty ? prefix : '$prefix${segments.join('/')}';
}

EdgeInsets _panelToastMargin(BuildContext context) {
  const double inset = 12;
  final Size viewport = MediaQuery.sizeOf(context);
  final RenderObject? renderObject = context.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) {
    return const EdgeInsets.all(inset);
  }
  final Offset origin = renderObject.localToGlobal(Offset.zero);
  final double left = (origin.dx + inset)
      .clamp(inset, viewport.width - inset)
      .toDouble();
  final double right =
      (viewport.width - origin.dx - renderObject.size.width + inset)
          .clamp(inset, viewport.width - inset)
          .toDouble();
  if (left + right >= viewport.width) {
    return const EdgeInsets.all(inset);
  }
  return EdgeInsets.fromLTRB(left, inset, right, inset);
}

bool _isUnsupportedPreviewError(Object error) {
  final String message = error.toString().toLowerCase();
  return message.contains('not valid utf-8 text') ||
      message.contains('not a supported text or source file') ||
      message.contains('not a supported image, pdf, or docx file');
}

void _showFileActionMessage(BuildContext context, String message) {
  _showPanelToast(context, message, isError: true);
}

void _showPanelToast(
  BuildContext context,
  String message, {
  bool isError = false,
  Duration duration = const Duration(seconds: 5),
}) {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final ColorScheme colors = Theme.of(context).colorScheme;
  final Color backgroundColor = isError
      ? colors.errorContainer
      : colors.secondaryContainer;
  final Color foregroundColor = isError
      ? colors.onErrorContainer
      : colors.onSecondaryContainer;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          message,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: foregroundColor),
        ),
        behavior: SnackBarBehavior.floating,
        margin: _panelToastMargin(context),
        duration: duration,
        showCloseIcon: true,
        backgroundColor: backgroundColor,
        closeIconColor: foregroundColor,
      ),
    );
}

final class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.controller, this.onSelection});

  final DashboardController controller;
  final VoidCallback? onSelection;

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
        ('Account', FluentIcons.person_20_regular, SettingsPage.account),
        ('About', FluentIcons.info_20_regular, SettingsPage.about),
      ];

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller.settings,
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
                    controller.settings.destination ==
                        MainPanelDestination.settings &&
                    controller.settings.activePage == page.$3,
                label: page.$1,
                onTap: () => controller.openSettingsPage(page.$3),
                onSelection: onSelection,
              );
            },
          ),
        ),
      ],
    ),
  );
}
