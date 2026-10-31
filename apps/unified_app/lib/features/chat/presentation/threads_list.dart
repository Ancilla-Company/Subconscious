import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import '../../dashboard/controller/dashboard_controller.dart';

/// The threads of the chosen workspace (or of every workspace), newest first.
/// The header has the title, the workspace picker and, at the far right, a
/// close button; a search box under it filters the list by title (and, in the
/// all-workspaces list, by workspace name). The chat panel shows it in place of
/// the conversation while its threads button is on.
final class ThreadsList extends StatefulWidget {
  const ThreadsList({
    required this.controller,
    this.minTouchTarget,
    this.showWorkspacePicker = true,
    super.key,
  });

  final DashboardController controller;

  /// Minimum height of every row (the touch layouts pass 48); null keeps the
  /// compact desktop size.
  final double? minTouchTarget;

  /// Whether the header carries the workspace picker. The desktop shell turns it
  /// off while the title bar has one (the normal window); the chat-only window
  /// and the phone layout have none, so they keep it.
  final bool showWorkspacePicker;

  @override
  State<ThreadsList> createState() => _ThreadsListState();
}

final class _ThreadsListState extends State<ThreadsList> {
  final TextEditingController _search = TextEditingController();

  DashboardController get controller => widget.controller;
  double? get minTouchTarget => widget.minTouchTarget;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (BuildContext context, Widget? child) => Column(
      children: <Widget>[
        _header(context),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          // Outside the form theme the field would lose its border.
          child: AppFormTheme(
            child: AppSearchField(
              controller: _search,
              hintText: 'Search threads',
              onChanged: (_) => setState(() {}),
            ),
          ),
        ),
        Expanded(child: _body(context)),
      ],
    ),
  );

  Widget _header(BuildContext context) => SizedBox(
    height: 48,
    child: LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // A fixed width: a loose Flexible would leave its unused share of the
        // row to the right of the close button. The picker takes at most 142
        // and leaves the title room in a narrow panel.
        final double pickerWidth = (constraints.maxWidth * 0.42).clamp(
          80.0,
          142.0,
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Threads',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (widget.showWorkspacePicker) ...<Widget>[
                SizedBox(width: pickerWidth, child: _workspacePicker()),
                const SizedBox(width: 4),
              ],
              AppIconButton(
                tooltip: 'Close threads',
                icon: FluentIcons.dismiss_20_regular,
                minTouchTarget: minTouchTarget,
                onPressed: () => controller.setThreadsListVisible(false),
              ),
            ],
          ),
        );
      },
    ),
  );
  Widget _workspacePicker() {
    final String activeUuid = controller.threadsWorkspace?.uuid ?? '';
    return AppPickerButton<String>(
      icon: FluentIcons.folder_20_regular,
      label: controller.threadsWorkspace?.name ?? 'All workspaces',
      tooltip: 'Workspace of the threads',
      height: minTouchTarget == null || minTouchTarget! < 32
          ? 32
          : minTouchTarget!,
      items: <AppMenuItem<String>>[
        AppMenuItem<String>(
          value: '',
          label: 'All workspaces',
          icon: FluentIcons.apps_20_regular,
          selected: activeUuid.isEmpty,
        ),
        for (final Workspace workspace in controller.workspaces)
          AppMenuItem<String>(
            value: workspace.uuid,
            label: workspace.name,
            icon: FluentIcons.folder_20_regular,
            selected: activeUuid == workspace.uuid,
          ),
      ],
      onSelected: (String uuid) {
        Workspace? workspace;
        for (final Workspace candidate in controller.workspaces) {
          if (candidate.uuid == uuid) {
            workspace = candidate;
            break;
          }
        }
        // The list stays open: switching the workspace only changes which
        // threads it shows.
        controller.selectThreadWorkspace(workspace);
      },
    );
  }
  List<ThreadInfo> _matches() {
    final String query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return controller.threads;
    return <ThreadInfo>[
      for (final ThreadInfo thread in controller.threads)
        if ((thread.title ?? '').toLowerCase().contains(query) ||
            (controller.threadsWorkspace == null &&
                (controller.workspaceName(thread.workspaceUuid) ?? '')
                    .toLowerCase()
                    .contains(query)))
          thread,
    ];
  }

  Widget _body(BuildContext context) {
    if (!controller.isConnected && controller.threads.isEmpty) {
      return const _Message('Threads are available when the engine is connected.');
    }
    if (controller.isLoadingThreads) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (controller.threadsError != null) {
      return _Message(
        "Couldn't load threads.",
        action: OutlinedButton(
          onPressed: () => controller.selectThreadWorkspace(
            controller.threadsWorkspace,
            remember: false,
          ),
          child: const Text('Retry'),
        ),
      );
    }
    if (controller.threads.isEmpty) {
      return const _Message('No threads yet.');
    }
    final List<ThreadInfo> matches = _matches();
    if (matches.isEmpty) {
      return _Message('No threads match “${_search.text.trim()}”.');
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      itemCount: matches.length,
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: 4),
      itemBuilder: (BuildContext context, int index) {
        final ThreadInfo thread = matches[index];
        return AppListRow(
          selected: controller.selectedThread?.uuid == thread.uuid,
          title: thread.title?.trim().isNotEmpty ?? false
              ? thread.title!
              : 'Untitled thread',
          // In the all-workspaces list each thread says where it belongs.
          subtitle: controller.threadsWorkspace == null
              ? controller.workspaceName(thread.workspaceUuid)
              : null,
          // Pointer layouts use the height of a sidebar button; touch layouts
          // keep their larger tap target.
          dense: minTouchTarget == null,
          minHeight: minTouchTarget,
          onTap: () => controller.selectThread(thread),
        );
      },
    );
  }
}

final class _Message extends StatelessWidget {
  const _Message(this.message, {this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: AppEmptyMessage(message, action: action),
    ),
  );
}
