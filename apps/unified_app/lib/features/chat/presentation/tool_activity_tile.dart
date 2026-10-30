import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart' as core;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

/// One tool call in the chat history: what was called, whether the user
/// approved it, how it ended, and for a sub-agent what it did. Collapsed until
/// opened. Built from the kit's [AppActivityCard].
final class ToolActivityTile extends StatelessWidget {
  const ToolActivityTile({required this.call, super.key});

  final core.ToolCallInfo call;

  static AppActivityState stateOf(core.ToolCallInfo call) {
    if (call.isWaitingForApproval) return AppActivityState.waiting;
    return switch (call.status) {
      'completed' => AppActivityState.success,
      'failed' => AppActivityState.failure,
      'interrupted' => AppActivityState.stopped,
      _ => AppActivityState.running,
    };
  }

  static String stateLabelOf(core.ToolCallInfo call) {
    if (call.isWaitingForApproval) return 'Waiting for your approval';
    if (call.approval == 'denied') return 'Denied';
    return switch (call.status) {
      'completed' => 'Completed',
      'failed' => 'Failed',
      'interrupted' => 'Stopped before it finished',
      _ => 'Running',
    };
  }

  /// `read_filesystem_file` becomes "read filesystem file" when the engine
  /// sent no title (older records).
  static String titleOf(core.ToolCallInfo call) {
    final String? title = call.title;
    if (title != null && title.trim().isNotEmpty) return title;
    final String base = call.toolName.split('__').last.replaceAll('_', ' ');
    return base.trim().isEmpty ? call.toolName : base;
  }

  static String durationOf(int milliseconds) => milliseconds < 1000
      ? '$milliseconds ms'
      : '${(milliseconds / 1000).toStringAsFixed(1)} s';

  static String pretty(Object? value) {
    if (value is String) return value;
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } on Object {
      return '$value';
    }
  }

  bool get _isSubAgent => call.steps.isNotEmpty || call.toolName.startsWith('ask_');

  Widget? _details() {
    final List<Widget> sections = <Widget>[
      if (call.arguments != null &&
          !(call.arguments is Map && (call.arguments! as Map).isEmpty))
        AppActivitySection(label: 'Input', text: pretty(call.arguments)),
      if (call.steps.isNotEmpty) _StepList(steps: call.steps),
      if (call.output != null)
        AppActivitySection(
          label: _isSubAgent ? 'Result returned to the assistant' : 'Output',
          text: pretty(call.output),
        ),
      if (call.error != null)
        AppActivitySection(label: 'Error', text: call.error!, isError: true),
    ];
    if (sections.isEmpty) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: sections,
    );
  }

  @override
  Widget build(BuildContext context) {
    final int? duration = call.durationMs;
    return AppActivityCard(
      title: titleOf(call),
      state: stateOf(call),
      stateLabel: stateLabelOf(call),
      subtitle: call.approval == 'denied' ? 'You denied this call' : null,
      badges: <Widget>[
        if (_isSubAgent)
          const AppBadge('Sub-agent', icon: FluentIcons.bot_16_regular),
        if (call.approval == 'approved')
          const AppBadge('Approved', tone: AppBadgeTone.accent),
        if (call.approval == 'denied')
          const AppBadge('Denied', tone: AppBadgeTone.error),
        if (call.isWaitingForApproval)
          const AppBadge('Needs approval', tone: AppBadgeTone.accent),
      ],
      meta: duration == null ? null : durationOf(duration),
      // A call that is still running stays open if it has steps to watch.
      initiallyExpanded: false,
      child: _details(),
    );
  }
}

/// What a sub-agent did, in order: its tool calls and the text it wrote.
final class _StepList extends StatelessWidget {
  const _StepList({required this.steps});

  final List<core.ToolStep> steps;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Sub-agent activity',
            style: textTheme.labelSmall?.copyWith(
              color: colors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          for (final core.ToolStep step in steps)
            if (step.isMessage)
              AppActivitySection(
                label: 'Agent wrote',
                text: step.text ?? '',
                maxHeight: 200,
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: <Widget>[
                    Icon(
                      switch (step.status) {
                        'completed' => Icons.check_circle_outline,
                        'failed' => Icons.error_outline,
                        _ => Icons.pending_outlined,
                      },
                      size: 14,
                      color: step.status == 'failed'
                          ? colors.error
                          : colors.onSurfaceVariant,
                    ),
                    AppSpacing.controlGap,
                    Expanded(
                      child: Text(
                        step.title ?? 'tool call',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall,
                      ),
                    ),
                    if (step.toolKind != null) AppBadge(step.toolKind!),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
