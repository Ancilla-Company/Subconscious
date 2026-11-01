import 'package:core_business_logic/core_business_logic.dart' as core;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

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
    this.size = AppIconButtonSize.compact,
    this.minTouchTarget,
    super.key,
  });

  /// Size of the trigger, matching the other composer controls.`n  final AppIconButtonSize size;`n  final double? minTouchTarget;

  /// Size of the trigger, matching the other composer controls.
  final AppIconButtonSize size;
  final double? minTouchTarget;

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
        // The picker carries its own trailing gap, so the composer row has no
        // extra gap when the picker is hidden (SizedBox.shrink above).
        return Padding(
          padding: const EdgeInsets.only(right: AppSpacing.control),
          child: AppPopupMenu<String>(
            key: const ValueKey<String>('executor-picker'),
            tooltip: 'Run on: $name',
            sheetTitle: 'Run on',
            sheetBreakpoint: 600,
            enabled: enabled && (options.length > 1 || selected != null),
            size: size,
            minTouchTarget: minTouchTarget,
            iconSize: 19,
            icon: selected == null
                ? FluentIcons.laptop_20_regular
                : FluentIcons.phone_laptop_20_regular,
            onSelected: (String value) =>
                onSelected(value == _homeValue ? null : value),
            items: <AppMenuItem<String>>[
              for (final ExecutorOption option in options)
                _item(option, option.nodeId == selected),
              if (!known)
                _item(
                  ExecutorOption(
                    nodeId: selected,
                    name: '${directory.nameOf(selected) ?? selected} (offline)',
                  ),
                  true,
                ),
            ],
          ),
        );
      },
    );
  }

  AppMenuItem<String> _item(ExecutorOption option, bool selected) =>
      AppMenuItem<String>(
        key: ValueKey<String>('executor-${option.nodeId ?? 'home'}'),
        value: option.nodeId ?? _homeValue,
        label: option.name,
        subtitle: option.subtitle.isEmpty ? null : option.subtitle,
        checked: selected,
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
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.only(left: 6), child: AppBadge(name));
}
