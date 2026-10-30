import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../dashboard/controller/dashboard_controller.dart';
import '../../editor/controller/file_gateway.dart' show PreviewKind;
import '../../settings/controller/settings_controller.dart';

final class ContextPanel extends StatefulWidget {
  const ContextPanel({
    required this.screen,
    required this.controller,
    this.onSelection,
    this.minTouchTarget,
    super.key,
  });

  final DashboardSection screen;
  final DashboardController controller;
  final VoidCallback? onSelection;

  /// Minimum height of every tappable row and button (the mobile flyout
  /// passes 48); null keeps the compact desktop sizes.
  final double? minTouchTarget;

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
  Widget build(BuildContext context) => _TouchTarget(
    minTouchTarget: widget.minTouchTarget,
    child: ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (BuildContext context, Widget? child) =>
            switch (widget.screen) {
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
    ),
  );
}

/// Carries [ContextPanel.minTouchTarget] to the rows and buttons below it.
final class _TouchTarget extends InheritedWidget {
  const _TouchTarget({required this.minTouchTarget, required super.child});

  final double? minTouchTarget;

  static double? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_TouchTarget>()
      ?.minTouchTarget;

  @override
  bool updateShouldNotify(_TouchTarget oldWidget) =>
      oldWidget.minTouchTarget != minTouchTarget;
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
  Widget build(BuildContext context) {
    final double? touch = _TouchTarget.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(2, touch == null ? 4 : 0, 2, 0),
      child: AppIconButton(
        icon: icon,
        tooltip: tooltip,
        minTouchTarget: touch,
        onPressed: onPressed == null
            ? null
            : () {
                onPressed!();
                onSelection?.call();
              },
      ),
    );
  }
}

final class _PanelMessage extends StatelessWidget {
  const _PanelMessage(this.message, {this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: AppEmptyMessage(message, action: action),
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
              child: AppCompactDropdown<String>(
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
                  // The sidebar stays open: switching the workspace only
                  // changes which threads the list shows.
                  controller.selectThreadWorkspace(workspace);
                },
              ),
            ),
          ],
        ],
      ),
      Expanded(child: _threadBody(context)),
    ],
  );

  Widget _threadBody(BuildContext context) {
    if (!controller.isConnected && controller.threads.isEmpty) {
      return const _PanelMessage(
        'Threads are available when the engine is connected.',
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
          // In the all-workspaces list each thread says where it belongs.
          subtitle: controller.threadsWorkspace == null
              ? controller.workspaceName(thread.workspaceUuid)
              : null,
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
    this.titleBold = false,
  });

  final bool selected;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback? onSelection;
  final bool titleBold;

  @override
  Widget build(BuildContext context) {
    final double? touch = _TouchTarget.of(context);
    return AppListRow(
      selected: selected,
      title: label,
      subtitle: subtitle,
      titleBold: titleBold,
      // Pointer layouts use the height of a sidebar button; touch layouts
      // keep their larger tap target.
      dense: touch == null,
      minHeight: touch,
      onTap: () {
        onTap();
        onSelection?.call();
      },
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
          titleBold: true,
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
                ? 'Select a workspace in Threads to browse its added folders.'
                : roots.isEmpty
                ? 'This workspace has no added folders.'
                : '${roots.length} added folder${roots.length == 1 ? '' : 's'}',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: controller.activeWorkspace == null
              ? const _PanelMessage('No workspace selected.')
              : roots.isEmpty
              ? const _PanelMessage('Add a folder in Workspace settings.')
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
                        subtitle: root.path,
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
    this.subtitle,
    this.isRoot = false,
    this.depth = 0,
    this.onSelection,
    super.key,
  });

  final DashboardController controller;
  final int rootIndex;
  final String path;
  final String label;

  /// The folder's full path, shown under the name of a top level folder.
  final String? subtitle;
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
          subtitle: widget.subtitle,
          tooltip: widget.subtitle,
          onSecondaryTapDown: (TapDownDetails details) => unawaited(
            _showFileTreeMenu(
              context,
              widget.controller,
              details.globalPosition,
              rootIndex: widget.rootIndex,
              path: widget.path,
              isDirectory: true,
              isRoot: widget.isRoot,
              name: widget.label,
            ),
          ),
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
                            onSecondaryTapDown: (TapDownDetails details) =>
                                unawaited(
                                  _showFileTreeMenu(
                                    context,
                                    widget.controller,
                                    details.globalPosition,
                                    rootIndex: widget.rootIndex,
                                    path: entry.relativePath,
                                    isDirectory: false,
                                    isRoot: false,
                                    name: entry.name,
                                  ),
                                ),
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
    this.subtitle,
    this.tooltip,
    this.onSecondaryTapDown,
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
  final String? subtitle;
  final String? tooltip;
  final GestureTapDownCallback? onSecondaryTapDown;
  final _WorkspaceFileTreeDragData? dragData;
  final bool Function(_WorkspaceFileTreeDragData source)? canAcceptDrop;
  final ValueChanged<_WorkspaceFileTreeDragData>? onAcceptDrop;

  @override
  Widget build(BuildContext context) {
    Widget buildRow(bool dropHighlighted) => AppTreeRow(
      depth: depth,
      selected: selected,
      highlighted: dropHighlighted,
      minHeight: _TouchTarget.of(context),
      onTap: onTap,
      leading: leading,
      label: label,
      subtitle: subtitle,
      tooltip: tooltip,
      onSecondaryTapDown: onSecondaryTapDown,
      trailing: trailing,
    );

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
      final Widget feedback = Material(
        elevation: 6,
        borderRadius: AppRadii.sm,
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
      );
      // A mouse or pen drags at once; a finger needs a long press so that it
      // can still scroll the list.
      final bool touch =
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS;
      result = touch
          ? LongPressDraggable<_WorkspaceFileTreeDragData>(
              data: source,
              feedback: feedback,
              childWhenDragging: Opacity(opacity: 0.45, child: result),
              child: result,
            )
          : Draggable<_WorkspaceFileTreeDragData>(
              data: source,
              feedback: feedback,
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
  final ({int rootIndex, String path})? request = await _showCreatePathDialog(
    context,
    roots,
    initialLocation: controller.selectedCreationDirectory,
    isFile: true,
  );
  if (request == null || !context.mounted) return;
  try {
    await controller.createFile(
      rootIndex: request.rootIndex,
      path: request.path,
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
  final ({int rootIndex, String path})? request = await _showCreatePathDialog(
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

/// Asks where to create a file or folder inside a workspace root. The same
/// in-app dialog serves both so it matches every other kit dialog, unlike a
/// native save dialog.
Future<({int rootIndex, String path})?> _showCreatePathDialog(
  BuildContext context,
  List<WorkspaceDirectoryRoot> roots, {
  ({int rootIndex, String path})? initialLocation,
  bool isFile = false,
}) {
  return showAppDialog<({int rootIndex, String path})>(
    context: context,
    builder: (BuildContext context) => CreatePathDialog(
      roots: roots,
      initialLocation: initialLocation,
      isFile: isFile,
    ),
  );
}

/// The body of the new file / folder dialog. It owns its text controller, so
/// the controller is disposed only when the dialog is removed from the tree.
/// Disposing it when the dialog's future completes is too early: the dialog
/// is still animating out and rebuilding its field.
@visibleForTesting
final class CreatePathDialog extends StatefulWidget {
  const CreatePathDialog({
    required this.roots,
    required this.initialLocation,
    required this.isFile,
  });

  final List<WorkspaceDirectoryRoot> roots;
  final ({int rootIndex, String path})? initialLocation;
  final bool isFile;

  @override
  State<CreatePathDialog> createState() => _CreatePathDialogState();
}

final class _CreatePathDialogState extends State<CreatePathDialog> {
  late final TextEditingController _path = TextEditingController(
    text: widget.initialLocation?.path.isNotEmpty == true
        ? '${widget.initialLocation!.path}/'
        : '',
  );
  late WorkspaceDirectoryRoot _root = widget.roots.firstWhere(
    (WorkspaceDirectoryRoot root) =>
        root.index == widget.initialLocation?.rootIndex,
    orElse: () => widget.roots.first,
  );
  String? _validationError;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  void _submit() {
    final String? path = _workspaceRelativeFolderPath(_path.text);
    if (path == null) {
      setState(
        () => _validationError = widget.isFile
            ? 'Enter a relative file name without . or .. segments.'
            : 'Enter a relative folder name without . or .. segments.',
      );
      return;
    }
    Navigator.of(context).pop((rootIndex: _root.index, path: path));
  }

  @override
  Widget build(BuildContext context) {
    final bool isFile = widget.isFile;
    return AppDialog(
      title: isFile ? 'New file' : 'New folder',
      width: 360,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AppDropdown(
            label: 'Location',
            value: _root.name,
            options: <String>[
              for (final WorkspaceDirectoryRoot root in widget.roots) root.name,
            ],
            onChanged: (String name) {
              setState(() {
                _root = widget.roots.firstWhere(
                  (WorkspaceDirectoryRoot root) => root.name == name,
                );
                _path.clear();
                _validationError = null;
              });
            },
          ),
          const SizedBox(height: 16),
          AppTextField(
            label: isFile ? 'File name' : 'Folder name',
            controller: _path,
            autofocus: true,
            textInputAction: TextInputAction.done,
            hintText: isFile
                ? 'e.g. notes.md or docs/readme.md'
                : 'e.g. notes or src/components',
            errorText: _validationError,
            onChanged: (_) {
              if (_validationError != null) {
                setState(() => _validationError = null);
              }
            },
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(isFile ? 'Create file' : 'Create'),
        ),
      ],
    );
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

enum _FileTreeAction { openInExplorer, rename, copyPath }

/// Whether a file manager can show the engine's folders: only on a desktop
/// app, where the engine runs on the same machine.
bool get _canOpenInFileExplorer =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

/// The right click menu of a file or folder in the file tree.
Future<void> _showFileTreeMenu(
  BuildContext context,
  DashboardController controller,
  Offset position, {
  required int rootIndex,
  required String path,
  required bool isDirectory,
  required bool isRoot,
  required String name,
}) async {
  final _FileTreeAction? action = await showAppContextMenu<_FileTreeAction>(
    context: context,
    position: position,
    items: <AppMenuItem<_FileTreeAction>>[
      if (_canOpenInFileExplorer)
        AppMenuItem<_FileTreeAction>(
          value: _FileTreeAction.openInExplorer,
          label: isDirectory
              ? 'Open in file explorer'
              : 'Show in file explorer',
          icon: FluentIcons.folder_open_20_regular,
        ),
      if (!isRoot)
        const AppMenuItem<_FileTreeAction>(
          value: _FileTreeAction.rename,
          label: 'Rename…',
          icon: FluentIcons.rename_20_regular,
        ),
      const AppMenuItem<_FileTreeAction>(
        value: _FileTreeAction.copyPath,
        label: 'Copy path',
        icon: FluentIcons.copy_20_regular,
      ),
    ],
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case _FileTreeAction.openInExplorer:
      await _openInFileExplorer(
        context,
        controller,
        rootIndex: rootIndex,
        path: path,
        isDirectory: isDirectory,
      );
    case _FileTreeAction.rename:
      await _renameWorkspaceNode(
        context,
        controller,
        rootIndex: rootIndex,
        path: path,
        isDirectory: isDirectory,
        name: name,
      );
    case _FileTreeAction.copyPath:
      final String? absolute = controller.absoluteWorkspacePath(
        rootIndex,
        path,
      );
      if (absolute == null) return;
      await Clipboard.setData(ClipboardData(text: absolute));
      if (context.mounted) _showFileActionMessage(context, 'Path copied');
  }
}

Future<void> _openInFileExplorer(
  BuildContext context,
  DashboardController controller, {
  required int rootIndex,
  required String path,
  required bool isDirectory,
}) async {
  final String? absolute = controller.absoluteWorkspacePath(rootIndex, path);
  if (absolute == null) return;
  // A file is shown by opening the folder that holds it.
  final String folder = isDirectory
      ? absolute
      : _parentOfAbsolutePath(absolute);
  try {
    if (!await launchUrl(Uri.directory(folder))) {
      throw StateError('The file explorer could not be opened.');
    }
  } on Object catch (error) {
    if (context.mounted) {
      _showFileActionMessage(
        context,
        "Couldn't open the file explorer: $error",
      );
    }
  }
}

String _parentOfAbsolutePath(String path) {
  final int cut = path.lastIndexOf(RegExp(r'[\\/]'));
  return cut <= 0 ? path : path.substring(0, cut);
}

Future<void> _renameWorkspaceNode(
  BuildContext context,
  DashboardController controller, {
  required int rootIndex,
  required String path,
  required bool isDirectory,
  required String name,
}) async {
  final String? newName = await _showRenameDialog(
    context,
    name: name,
    isDirectory: isDirectory,
  );
  if (newName == null || newName == name || !context.mounted) return;
  final Object? failure = await controller.renameWorkspaceNode(
    rootIndex: rootIndex,
    path: path,
    isDirectory: isDirectory,
    newName: newName,
  );
  if (failure != null && context.mounted) {
    _showFileActionMessage(context, "Couldn't rename: $failure");
  }
}

Future<String?> _showRenameDialog(
  BuildContext context, {
  required String name,
  required bool isDirectory,
}) {
  return showAppDialog<String>(
    context: context,
    builder: (BuildContext context) =>
        RenameDialog(name: name, isDirectory: isDirectory),
  );
}

/// The body of the rename dialog; owns its controller (see [CreatePathDialog]).
@visibleForTesting
final class RenameDialog extends StatefulWidget {
  const RenameDialog({required this.name, required this.isDirectory});

  final String name;
  final bool isDirectory;

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

final class _RenameDialogState extends State<RenameDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.name,
  );
  String? _validationError;

  @override
  void initState() {
    super.initState();
    // Select the name without its extension, as file managers do.
    final int dot = widget.name.lastIndexOf('.');
    _name.selection = TextSelection(
      baseOffset: 0,
      extentOffset: !widget.isDirectory && dot > 0 ? dot : widget.name.length,
    );
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  static String? _validate(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty ||
        trimmed == '.' ||
        trimmed == '..' ||
        RegExp(r'[\\/:*?"<>|]').hasMatch(trimmed)) {
      return 'Enter a name without slashes or any of : * ? " < > |';
    }
    return null;
  }

  void _submit() {
    final String? problem = _validate(_name.text);
    if (problem != null) {
      setState(() => _validationError = problem);
      return;
    }
    Navigator.of(context).pop(_name.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: widget.isDirectory ? 'Rename folder' : 'Rename file',
      width: 360,
      content: AppTextField(
        label: 'Name',
        controller: _name,
        autofocus: true,
        textInputAction: TextInputAction.done,
        errorText: _validationError,
        onChanged: (_) {
          if (_validationError != null) {
            setState(() => _validationError = null);
          }
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Rename')),
      ],
    );
  }
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
  showAppSnack(
    context,
    message,
    isError: isError,
    duration: duration,
    margin: _panelToastMargin(context),
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
