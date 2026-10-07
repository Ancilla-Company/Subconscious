import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_highlight/themes/monokai-sublime.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:highlight/highlight.dart' show Mode;
import 'package:highlight/languages/bash.dart' as highlight_bash;
import 'package:highlight/languages/cpp.dart' as highlight_cpp;
import 'package:highlight/languages/cs.dart' as highlight_csharp;
import 'package:highlight/languages/css.dart' as highlight_css;
import 'package:highlight/languages/dart.dart' as highlight_dart;
import 'package:highlight/languages/go.dart' as highlight_go;
import 'package:highlight/languages/java.dart' as highlight_java;
import 'package:highlight/languages/javascript.dart' as highlight_javascript;
import 'package:highlight/languages/json.dart' as highlight_json;
import 'package:highlight/languages/kotlin.dart' as highlight_kotlin;
import 'package:highlight/languages/php.dart' as highlight_php;
import 'package:highlight/languages/plaintext.dart' as highlight_plaintext;
import 'package:highlight/languages/python.dart' as highlight_python;
import 'package:highlight/languages/ruby.dart' as highlight_ruby;
import 'package:highlight/languages/rust.dart' as highlight_rust;
import 'package:highlight/languages/sql.dart' as highlight_sql;
import 'package:highlight/languages/swift.dart' as highlight_swift;
import 'package:highlight/languages/typescript.dart' as highlight_typescript;
import 'package:highlight/languages/xml.dart' as highlight_xml;
import 'package:highlight/languages/yaml.dart' as highlight_yaml;
import 'package:markdown/markdown.dart' as md;
import 'package:markdown_quill/markdown_quill.dart';

import '../../dashboard/controller/dashboard_controller.dart';
import '../../settings/controller/settings_controller.dart';
import 'workspace_document_preview.dart';
import 'workspace_image_preview.dart';

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
                  : () => _chooseWorkspaceFolder(context, controller),
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
    widget.controller.selectFileTreeNode(widget.rootIndex, widget.path);
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
                              OpenWorkspaceFile.supportsPreview(
                                    entry.relativePath,
                                  )
                                  ? FluentIcons.image_20_regular
                                  : FluentIcons.document_20_regular,
                              size: 16,
                            ),
                            label: entry.name,
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
    super.key,
  });

  final int depth;
  final bool selected;
  final VoidCallback? onTap;
  final Widget leading;
  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: selected ? colors.secondaryContainer : Colors.transparent,
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
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: selected ? colors.onSecondaryContainer : null,
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
}

Future<void> _createWorkspaceFile(
  BuildContext context,
  DashboardController controller,
) async {
  final List<WorkspaceDirectoryRoot> roots = controller.fileRoots;
  if (roots.isEmpty) return;
  try {
    final file_selector.FileSaveLocation? location = await file_selector
        .getSaveLocation(
          suggestedName: 'new-file.md',
          initialDirectory: roots.first.path,
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

Future<void> _chooseWorkspaceFolder(
  BuildContext context,
  DashboardController controller,
) async {
  final List<WorkspaceDirectoryRoot> roots = controller.fileRoots;
  if (roots.isEmpty) return;
  try {
    final String? path = await file_selector.getDirectoryPath(
      initialDirectory: roots.first.path,
    );
    if (path == null || !context.mounted) return;
    if (_mapWorkspacePath(path, roots, requireRelativePath: false) == null) {
      _showFileActionMessage(
        context,
        'Choose a folder inside one of this workspace’s allowed folders.',
      );
      return;
    }
    await controller.refreshFiles();
  } on Object catch (error) {
    if (context.mounted) {
      _showFileActionMessage(context, "Couldn't refresh files: $error");
    }
  }
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

final class WorkspaceFileEditor extends StatefulWidget {
  const WorkspaceFileEditor({required this.controller, super.key});

  final DashboardController controller;

  @override
  State<WorkspaceFileEditor> createState() => _WorkspaceFileEditorState();
}

final class _WorkspaceFileTab {
  _WorkspaceFileTab(this.file)
    : savedContent = file.content,
      draftContent = file.content,
      cleanContent = file.content,
      lineEnding = file.content.contains('\r\n') ? '\r\n' : '\n',
      hadTrailingLineEnding = file.content.endsWith('\n');

  OpenWorkspaceFile file;
  String savedContent;
  String draftContent;
  String cleanContent;
  String lineEnding;
  bool hadTrailingLineEnding;
  bool quillBaselineInitialized = false;
  TextSelection selection = const TextSelection.collapsed(offset: 0);

  String get key => '${file.rootIndex}:${file.path}';
  bool get isDirty => !file.isReadOnlyPreview && draftContent != cleanContent;

  void resetFromRemote(OpenWorkspaceFile nextFile) {
    file = nextFile;
    savedContent = nextFile.content;
    draftContent = nextFile.content;
    cleanContent = nextFile.content;
    lineEnding = nextFile.content.contains('\r\n') ? '\r\n' : '\n';
    hadTrailingLineEnding = nextFile.content.endsWith('\n');
    quillBaselineInitialized = false;
    selection = const TextSelection.collapsed(offset: 0);
  }
}

final class _WorkspaceFileEditorState extends State<WorkspaceFileEditor> {
  final List<_WorkspaceFileTab> _tabs = <_WorkspaceFileTab>[];
  final FocusNode _quillFocusNode = FocusNode();
  final ScrollController _quillScrollController = ScrollController();
  CodeController? _codeController;
  quill.QuillController? _quillController;
  StreamSubscription<dynamic>? _quillChangesSubscription;
  late final MarkdownToDelta _markdownToDelta;
  final DeltaToMarkdown _deltaToMarkdown = DeltaToMarkdown();
  String? _activeKey;
  String? _workspaceUuid;
  String? _restorationWorkspaceUuid;
  bool _syncingEditor = false;
  bool _restoringTabs = false;
  int _restorationGeneration = 0;

  _WorkspaceFileTab? get _activeTab {
    for (final _WorkspaceFileTab tab in _tabs) {
      if (tab.key == _activeKey) return tab;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _markdownToDelta = MarkdownToDelta(
      markdownDocument: md.Document(
        encodeHtml: false,
        extensionSet: md.ExtensionSet.gitHubFlavored,
      ),
    );
    _workspaceUuid = widget.controller.activeWorkspace?.uuid;
    widget.controller.addListener(_onControllerChanged);
    _startTabRestoration(_workspaceUuid);
  }

  @override
  void didUpdateWidget(covariant WorkspaceFileEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _restorationGeneration++;
      _restoringTabs = false;
      _restorationWorkspaceUuid = null;
      _clearTabs();
      _workspaceUuid = widget.controller.activeWorkspace?.uuid;
      _startTabRestoration(_workspaceUuid);
    }
  }

  void _onControllerChanged() {
    final String? workspaceUuid = widget.controller.activeWorkspace?.uuid;
    if (workspaceUuid != _workspaceUuid) {
      _restorationGeneration++;
      _restoringTabs = false;
      _restorationWorkspaceUuid = null;
      _clearTabs();
      _workspaceUuid = workspaceUuid;
      _startTabRestoration(workspaceUuid);
    } else if (!_restoringTabs) {
      _syncFile();
    }
    if (mounted) setState(() {});
  }

  void _startTabRestoration(String? workspaceUuid) {
    final DashboardController controller = widget.controller;
    final int generation = ++_restorationGeneration;
    _restoringTabs = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isCurrentRestoration(controller, workspaceUuid, generation)) {
        return;
      }
      if (workspaceUuid == null) {
        _restoringTabs = false;
        _syncFile();
        if (mounted) setState(() {});
        return;
      }
      if (_restorationWorkspaceUuid == workspaceUuid) {
        _restoringTabs = false;
        _syncFile();
        if (mounted) setState(() {});
        return;
      }
      _restorationWorkspaceUuid = workspaceUuid;
      unawaited(_restoreTabs(controller, workspaceUuid, generation));
    });
  }

  bool _isCurrentRestoration(
    DashboardController controller,
    String? workspaceUuid,
    int generation,
  ) =>
      mounted &&
      generation == _restorationGeneration &&
      identical(widget.controller, controller) &&
      controller.activeWorkspace?.uuid == workspaceUuid;

  Future<void> _restoreTabs(
    DashboardController controller,
    String workspaceUuid,
    int generation,
  ) async {
    final List<WorkspaceFileReference> references =
        controller.rememberedOpenFiles;
    final String? rememberedActiveKey = controller.rememberedActiveFileKey;
    final List<_WorkspaceFileTab> restoredTabs = <_WorkspaceFileTab>[];
    for (final WorkspaceFileReference reference in references) {
      try {
        final OpenWorkspaceFile? file = await controller.readWorkspaceFile(
          reference.rootIndex,
          reference.path,
        );
        if (!_isCurrentRestoration(controller, workspaceUuid, generation)) {
          return;
        }
        if (file != null) restoredTabs.add(_WorkspaceFileTab(file));
      } on Object {
        if (!_isCurrentRestoration(controller, workspaceUuid, generation)) {
          return;
        }
      }
    }
    if (!_isCurrentRestoration(controller, workspaceUuid, generation)) return;

    _tabs.addAll(restoredTabs);

    // A file opened while restoration was reading tabs must win over the
    // remembered active tab rather than being replaced when restoration ends.
    final OpenWorkspaceFile? currentFile = controller.openFile;
    _WorkspaceFileTab? selectedTab;
    if (currentFile != null) {
      final String currentKey = _fileKey(
        currentFile.rootIndex,
        currentFile.path,
      );
      for (final _WorkspaceFileTab tab in _tabs) {
        if (tab.key == currentKey) {
          selectedTab = tab;
          break;
        }
      }
      if (selectedTab == null) {
        selectedTab = _WorkspaceFileTab(currentFile);
        _tabs.add(selectedTab);
      }
    }
    if (selectedTab == null) {
      for (final _WorkspaceFileTab tab in _tabs) {
        if (tab.key == rememberedActiveKey) {
          selectedTab = tab;
          break;
        }
      }
    }
    selectedTab ??= _tabs.isEmpty ? null : _tabs.last;
    if (selectedTab == null) {
      _restoringTabs = false;
      _persistTabs();
      if (mounted) setState(() {});
      return;
    }

    _activateEditor(selectedTab);
    controller.activateOpenFile(selectedTab.file);
    if (!_isCurrentRestoration(controller, workspaceUuid, generation)) return;
    _restoringTabs = false;
    // Persist the successfully restored set so stale or unreadable references
    // do not reappear on the next launch.
    _persistTabs();
    if (mounted) setState(() {});
  }

  void _syncFile() {
    if (_restoringTabs || widget.controller.isLoadingFile) return;
    final OpenWorkspaceFile? file = widget.controller.openFile;
    if (file == null) return;
    final String key = _fileKey(file.rootIndex, file.path);
    _WorkspaceFileTab? tab;
    for (final _WorkspaceFileTab candidate in _tabs) {
      if (candidate.key == key) {
        tab = candidate;
        break;
      }
    }
    if (tab != null && _activeKey == key) {
      if (_refreshCleanTab(tab, file)) _activateEditor(tab);
      return;
    }

    _captureActiveContent();
    if (tab == null) {
      tab = _WorkspaceFileTab(file);
      _tabs.add(tab);
    } else {
      _refreshCleanTab(tab, file);
    }
    _activateEditor(tab);
    _persistTabs();
  }

  bool _refreshCleanTab(_WorkspaceFileTab tab, OpenWorkspaceFile file) {
    final bool contentChanged = file.content != tab.savedContent;
    tab.file = file;
    if (file.isReadOnlyPreview || tab.isDirty || !contentChanged) return false;
    tab.resetFromRemote(file);
    return true;
  }

  void _persistTabs() {
    if (_restoringTabs ||
        widget.controller.activeWorkspace?.uuid != _workspaceUuid) {
      return;
    }
    widget.controller.rememberOpenFiles(<WorkspaceFileReference>[
      for (final _WorkspaceFileTab tab in _tabs)
        WorkspaceFileReference(
          rootIndex: tab.file.rootIndex,
          path: tab.file.path,
        ),
    ], activeKey: _activeKey);
  }

  void _activateEditor(_WorkspaceFileTab tab) {
    _disposeEditorControllers();
    _activeKey = tab.key;
    if (tab.file.isReadOnlyPreview) return;
    _syncingEditor = true;
    if (_usesQuill(tab.file.path)) {
      _createQuillController(tab);
      _quillChangesSubscription = _quillController!.document.changes.listen(
        (_) => _onEditorChanged(),
      );
    } else {
      _codeController = CodeController(
        text: tab.draftContent,
        language: _languageForPath(tab.file.path),
      )..addListener(_onEditorChanged);
    }
    _syncingEditor = false;
    if (_usesQuill(tab.file.path)) _requestQuillFocus();
  }

  void _createQuillController(_WorkspaceFileTab tab) {
    final String normalized = _normalizeLineEndings(tab.draftContent);
    final quill.Document document;
    if (_isMarkdown(tab.file.path)) {
      document = quill.Document.fromDelta(_markdownToDelta.convert(normalized));
    } else {
      String text = normalized;
      if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
      document = quill.Document()..insert(0, text);
    }
    final TextSelection selection = _clampSelection(
      tab.selection,
      document.length,
    );
    _quillController = quill.QuillController(
      document: document,
      selection: selection,
    );
    tab.selection = selection;
    if (!tab.quillBaselineInitialized) {
      final String canonical = _serializeQuillContent(tab, _quillController!);
      tab
        ..draftContent = canonical
        ..cleanContent = canonical
        ..quillBaselineInitialized = true;
    }
  }

  void _requestQuillFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final _WorkspaceFileTab? tab = _activeTab;
      if (mounted &&
          tab != null &&
          _usesQuill(tab.file.path) &&
          _quillController != null) {
        _quillFocusNode.requestFocus();
      }
    });
  }

  void _onEditorChanged() {
    if (_syncingEditor) return;
    final _WorkspaceFileTab? tab = _activeTab;
    if (tab == null || tab.file.isReadOnlyPreview) return;
    final quill.QuillController? quillController = _quillController;
    if (quillController != null) tab.selection = quillController.selection;
    final String content = _currentContent(tab);
    if (content == tab.draftContent) return;
    tab.draftContent = content;
    if (mounted) setState(() {});
  }

  void _captureActiveContent() {
    final _WorkspaceFileTab? tab = _activeTab;
    if (tab == null || tab.file.isReadOnlyPreview) return;
    final quill.QuillController? quillController = _quillController;
    if (quillController != null) tab.selection = quillController.selection;
    tab.draftContent = _currentContent(tab);
  }

  String _currentContent(_WorkspaceFileTab tab) {
    final CodeController? codeController = _codeController;
    if (codeController != null) return codeController.fullText;
    final quill.QuillController? quillController = _quillController;
    if (quillController == null) return tab.draftContent;
    return _serializeQuillContent(tab, quillController);
  }

  String _serializeQuillContent(
    _WorkspaceFileTab tab,
    quill.QuillController controller,
  ) {
    final String value = _isMarkdown(tab.file.path)
        ? _deltaToMarkdown.convert(controller.document.toDelta())
        : controller.document.toPlainText();
    return _restoreLineEndings(tab, value);
  }

  TextSelection _clampSelection(TextSelection selection, int documentLength) {
    final int maxOffset = documentLength < 0 ? 0 : documentLength;
    return TextSelection(
      baseOffset: selection.baseOffset.clamp(0, maxOffset),
      extentOffset: selection.extentOffset.clamp(0, maxOffset),
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    );
  }

  String _restoreLineEndings(_WorkspaceFileTab tab, String value) {
    String normalized = _normalizeLineEndings(value);
    while (normalized.endsWith('\n')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (tab.hadTrailingLineEnding) normalized = '$normalized\n';
    return tab.lineEnding == '\r\n'
        ? normalized.replaceAll('\n', '\r\n')
        : normalized;
  }

  Future<void> _saveActive() async {
    final _WorkspaceFileTab? tab = _activeTab;
    if (tab == null || tab.file.isReadOnlyPreview || !tab.isDirty) return;
    _captureActiveContent();
    await widget.controller.saveOpenFile(tab.draftContent);
    if (!mounted || widget.controller.filesError != null) return;
    tab
      ..savedContent = tab.draftContent
      ..cleanContent = tab.draftContent
      ..file = OpenWorkspaceFile(
        rootIndex: tab.file.rootIndex,
        path: tab.file.path,
        content: tab.draftContent,
      );
    setState(() {});
  }

  void _selectTab(_WorkspaceFileTab tab) {
    if (tab.key == _activeKey) return;
    _captureActiveContent();
    widget.controller.activateOpenFile(tab.file);
  }

  Future<void> _closeTab(_WorkspaceFileTab tab) async {
    if (tab.isDirty) {
      final bool discard =
          await showDialog<bool>(
            context: context,
            builder: (BuildContext context) => AlertDialog(
              title: const Text('Discard unsaved changes?'),
              content: Text('Close “${tab.file.name}” without saving?'),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Discard'),
                ),
              ],
            ),
          ) ??
          false;
      if (!discard || !mounted) return;
    }
    final int index = _tabs.indexOf(tab);
    final bool wasActive = tab.key == _activeKey;
    setState(() => _tabs.remove(tab));
    if (!wasActive) {
      _persistTabs();
      return;
    }
    _disposeEditorControllers();
    _activeKey = null;
    if (_tabs.isEmpty) {
      widget.controller.closeOpenFile();
      _persistTabs();
      return;
    }
    final _WorkspaceFileTab next = _tabs[index.clamp(0, _tabs.length - 1)];
    widget.controller.activateOpenFile(next.file);
    _persistTabs();
  }

  void _disposeEditorControllers() {
    _codeController?.removeListener(_onEditorChanged);
    _codeController?.dispose();
    _codeController = null;
    final StreamSubscription<dynamic>? quillChangesSubscription =
        _quillChangesSubscription;
    _quillChangesSubscription = null;
    if (quillChangesSubscription != null) {
      unawaited(quillChangesSubscription.cancel());
    }
    _quillController?.dispose();
    _quillController = null;
  }

  void _clearTabs() {
    _disposeEditorControllers();
    _tabs.clear();
    _activeKey = null;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _clearTabs();
    _quillFocusNode.dispose();
    _quillScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final _WorkspaceFileTab? activeTab = _activeTab;
    if (widget.controller.isLoadingFile && _tabs.isEmpty) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surface,
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (activeTab == null) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surface,
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
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: <Widget>[
          _buildTabBar(context, activeTab),
          Expanded(child: _buildEditor(context, activeTab)),
        ],
      ),
    );
  }

  Widget _buildTabBar(BuildContext context, _WorkspaceFileTab activeTab) =>
      SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: <Widget>[
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: <Widget>[
                      for (final _WorkspaceFileTab tab in _tabs)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: _FileTabButton(
                            label: tab.file.name,
                            selected: tab.key == _activeKey,
                            dirty: tab.isDirty,
                            onTap: () => _selectTab(tab),
                            onClose: () => _closeTab(tab),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (!activeTab.file.isReadOnlyPreview)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(3)),
                    ),
                  ),
                  onPressed:
                      widget.controller.isSavingFile ||
                          widget.controller.isLoadingFile ||
                          !activeTab.isDirty
                      ? null
                      : _saveActive,
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
      );

  Widget _buildEditor(BuildContext context, _WorkspaceFileTab tab) {
    if (tab.file.isReadOnlyPreview) {
      if (tab.file.isDocumentPreview) {
        return WorkspaceDocumentPreview(
          key: ValueKey<String>(tab.key),
          bytes: tab.file.previewBytes!,
          kind: tab.file.previewKind!.name,
        );
      }
      return Padding(
        padding: const EdgeInsets.all(12),
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(6)),
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerLowest,
            child: WorkspaceImagePreview(
              bytes: tab.file.previewBytes!,
              isSvg: tab.file.isSvg,
            ),
          ),
        ),
      );
    }
    final quill.QuillController? quillController = _quillController;
    if (_usesQuill(tab.file.path) && quillController != null) {
      return Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: SizedBox(
              width: double.infinity,
              child: ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(6)),
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  child: quill.QuillSimpleToolbar(
                    controller: quillController,
                    config: const quill.QuillSimpleToolbarConfig(
                      iconTheme: quill.QuillIconTheme(
                        iconButtonSelectedData: quill.IconButtonData(
                          constraints: BoxConstraints.tightFor(
                            width: 32,
                            height: 32,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                        iconButtonUnselectedData: quill.IconButtonData(
                          constraints: BoxConstraints.tightFor(
                            width: 32,
                            height: 32,
                          ),
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: quill.QuillEditor.basic(
              controller: quillController,
              focusNode: _quillFocusNode,
              scrollController: _quillScrollController,
              config: const quill.QuillEditorConfig(
                padding: EdgeInsets.all(16),
              ),
            ),
          ),
        ],
      );
    }
    final CodeController? codeController = _codeController;
    if (codeController == null) return const SizedBox.shrink();
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return CodeTheme(
      data: CodeThemeData(styles: dark ? monokaiSublimeTheme : githubTheme),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Theme(
          data: Theme.of(context).copyWith(
            inputDecorationTheme: const InputDecorationTheme(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              focusedErrorBorder: InputBorder.none,
              filled: false,
            ),
          ),
          child: CodeField(
            controller: codeController,
            decoration: const BoxDecoration(color: Colors.transparent),
            textStyle: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.45,
            ),
          ),
        ),
      ),
    );
  }

  static bool _usesQuill(String path) =>
      _isMarkdown(path) || path.toLowerCase().endsWith('.txt');

  static bool _isMarkdown(String path) {
    final String lower = path.toLowerCase();
    return lower.endsWith('.md') || lower.endsWith('.markdown');
  }

  static String _normalizeLineEndings(String value) =>
      value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  static String _fileKey(int rootIndex, String path) =>
      '$rootIndex:${path.replaceAll('\\', '/')}';

  static Mode _languageForPath(String path) {
    final String lower = path.toLowerCase();
    final int dot = lower.lastIndexOf('.');
    final String extension = dot < 0 ? '' : lower.substring(dot + 1);
    return switch (extension) {
      'dart' => highlight_dart.dart,
      'js' || 'jsx' || 'mjs' || 'cjs' => highlight_javascript.javascript,
      'ts' || 'tsx' => highlight_typescript.typescript,
      'py' => highlight_python.python,
      'java' => highlight_java.java,
      'kt' || 'kts' => highlight_kotlin.kotlin,
      'swift' => highlight_swift.swift,
      'go' => highlight_go.go,
      'rs' => highlight_rust.rust,
      'rb' => highlight_ruby.ruby,
      'php' => highlight_php.php,
      'c' || 'h' || 'cc' || 'cpp' || 'cxx' || 'hpp' => highlight_cpp.cpp,
      'cs' => highlight_csharp.cs,
      'sh' || 'bash' || 'zsh' || 'ps1' || 'bat' || 'cmd' => highlight_bash.bash,
      'json' || 'jsonc' => highlight_json.json,
      'yaml' || 'yml' => highlight_yaml.yaml,
      'xml' || 'html' || 'htm' || 'svg' => highlight_xml.xml,
      'css' || 'scss' || 'sass' || 'less' => highlight_css.css,
      'sql' => highlight_sql.sql,
      _ => highlight_plaintext.plaintext,
    };
  }
}

final class _FileTabButton extends StatelessWidget {
  const _FileTabButton({
    required this.label,
    required this.selected,
    required this.dirty,
    required this.onTap,
    required this.onClose,
  });

  final String label;
  final bool selected;
  final bool dirty;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: Material(
        color: selected
            ? colors.secondaryContainer
            : colors.surfaceContainerLow,
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 34,
            child: Padding(
              padding: const EdgeInsets.only(left: 10, right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: selected ? colors.onSecondaryContainer : null,
                      ),
                    ),
                  ),
                  if (dirty) ...<Widget>[
                    const SizedBox(width: 7),
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: colors.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                  const SizedBox(width: 3),
                  IconButton(
                    tooltip: 'Close $label',
                    onPressed: onClose,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 26,
                      height: 26,
                    ),
                    icon: const Icon(FluentIcons.dismiss_20_regular, size: 14),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
