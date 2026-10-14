import 'package:core_business_logic/core_business_logic.dart' as core;
import 'package:flutter/material.dart';

import '../../hive/executor_selection.dart';
import '../engine_llm_provider.dart';

const String _homeValue = '';

/// Human readable task state for the status line.
String taskStatusLabel(core.TaskStatus status) => switch (status) {
  core.TaskStatus.queued => 'Queued',
  core.TaskStatus.running => 'Running',
  core.TaskStatus.waitingApproval => 'Waiting for approval',
  core.TaskStatus.done => 'Done',
  core.TaskStatus.failed => 'Failed',
  core.TaskStatus.cancelled => 'Cancelled',
  core.TaskStatus.interrupted => 'Interrupted',
  core.TaskStatus.unknown => 'Unknown',
};

/// Composer control: choose which node runs the next message of this thread.
///
/// Lists this node's engine (default) plus other active, verified, online
/// full nodes with their platform and connection tier. The choice is stored
/// per thread on this device only.
final class ExecutorPicker extends StatelessWidget {
  const ExecutorPicker({
    required this.provider,
    required this.directory,
    required this.onSelected,
    this.enabled = true,
    super.key,
  });

  final EngineLlmProvider provider;
  final ExecutorDirectory directory;
  final ValueChanged<String?> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[provider, directory]),
      builder: (BuildContext context, Widget? _) {
        final List<ExecutorOption> options = directory.options;
        final String? selected = provider.executorNodeId;
        // Nothing to choose from: keep the composer uncluttered.
        if (options.length <= 1 && selected == null) {
          return const SizedBox.shrink();
        }
        final bool known =
            selected == null ||
            options.any((ExecutorOption o) => o.nodeId == selected);
        final String name = selected == null
            ? options.first.name
            : (directory.nameOf(selected) ?? selected);
        return PopupMenuButton<String>(
          key: const ValueKey<String>('executor-picker'),
          tooltip: 'Run on: $name',
          enabled: enabled && (options.length > 1 || selected != null),
          icon: Icon(
            selected == null ? Icons.computer_outlined : Icons.devices,
            size: 18,
          ),
          padding: EdgeInsets.zero,
          onSelected: (String value) =>
              onSelected(value == _homeValue ? null : value),
          itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
            for (final ExecutorOption option in options)
              _item(context, option, option.nodeId == selected),
            if (!known)
              _item(
                context,
                ExecutorOption(
                  nodeId: selected,
                  name: '${directory.nameOf(selected) ?? selected} (offline)',
                ),
                true,
              ),
          ],
        );
      },
    );
  }

  PopupMenuEntry<String> _item(
    BuildContext context,
    ExecutorOption option,
    bool selected,
  ) => CheckedPopupMenuItem<String>(
    key: ValueKey<String>('executor-${option.nodeId ?? 'home'}'),
    value: option.nodeId ?? _homeValue,
    checked: selected,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(option.name, overflow: TextOverflow.ellipsis),
        if (option.subtitle.isNotEmpty)
          Text(
            option.subtitle,
            style: Theme.of(context).textTheme.labelSmall,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    ),
  );
}

/// Task line above the composer: state, node name and a cancel button.
final class TaskStatusBar extends StatelessWidget {
  const TaskStatusBar({required this.provider, super.key});

  final EngineLlmProvider provider;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: provider,
      builder: (BuildContext context, Widget? _) {
        final core.TaskStatus? status = provider.taskStatus;
        final String? node = provider.ranOnLabel;
        if (status == null && node == null) return const SizedBox.shrink();
        final ColorScheme colors = Theme.of(context).colorScheme;
        final bool failed =
            status == core.TaskStatus.failed ||
            status == core.TaskStatus.interrupted;
        final String text = status == null
            ? 'Last task ran on $node'
            : '${taskStatusLabel(status)}${node == null ? '' : ' on $node'}'
                  '${failed && provider.taskError != null ? ': ${provider.taskError}' : ''}';
        return Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 6, 2),
          child: Row(
            children: <Widget>[
              if (provider.hasActiveTask)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox.square(
                    dimension: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              Expanded(
                child: Text(
                  text,
                  key: const ValueKey<String>('task-status'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: failed ? colors.error : colors.onSurfaceVariant,
                  ),
                ),
              ),
              if (provider.hasActiveTask)
                TextButton(
                  key: const ValueKey<String>('task-cancel'),
                  onPressed: provider.cancelActiveTask,
                  child: const Text('Cancel'),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Small "ran on" tag with the node name for assistant messages.
final class NodeBadge extends StatelessWidget {
  const NodeBadge({required this.name, super.key});
  final String name;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      margin: const EdgeInsets.only(left: 6),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        name,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}
