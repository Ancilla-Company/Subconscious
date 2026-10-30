import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_radii.dart';
import '../tokens/app_spacing.dart';

/// How far an action in the chat has got.
enum AppActivityState {
  /// Needs a decision from the user before it can run.
  waiting,

  /// Running now.
  running,

  /// Finished without error.
  success,

  /// Failed, or was denied.
  failure,

  /// Ended before it finished (the turn was cancelled or failed).
  stopped,
}

/// A collapsed-by-default record of something the assistant did in a chat:
/// a tool call, an approval, or a sub-agent working. It is not a model reply,
/// so it is quieter than a message bubble: a soft fill, one header line (state
/// icon, title, [badges], [meta]) and a chevron that opens the [child] details.
///
/// Without a [child] the header is a plain, non-interactive line.
final class AppActivityCard extends StatefulWidget {
  const AppActivityCard({
    required this.title,
    required this.state,
    this.stateLabel,
    this.subtitle,
    this.badges = const <Widget>[],
    this.meta,
    this.child,
    this.initiallyExpanded = false,
    super.key,
  });

  /// What happened, for example "read filesystem file: notes.txt".
  final String title;
  final AppActivityState state;

  /// The state in words, for screen readers and the icon tooltip. Defaults to
  /// the state's name.
  final String? stateLabel;

  /// A second line under the title (one line, ellipsised).
  final String? subtitle;

  /// Small labels after the title, such as an `AppBadge` saying "Approved".
  final List<Widget> badges;

  /// Trailing text such as how long it took.
  final String? meta;

  /// The details shown when the card is open.
  final Widget? child;
  final bool initiallyExpanded;

  @override
  State<AppActivityCard> createState() => _AppActivityCardState();
}

final class _AppActivityCardState extends State<AppActivityCard> {
  late bool _open = widget.initiallyExpanded;

  String get _stateLabel => widget.stateLabel ?? widget.state.name;

  Widget _stateIcon(ColorScheme colors) {
    const double size = 16;
    return switch (widget.state) {
      AppActivityState.waiting => Icon(
        Icons.pending_outlined,
        size: size,
        color: AppColors.statusConnecting,
      ),
      AppActivityState.running => const SizedBox.square(
        dimension: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      AppActivityState.success => Icon(
        Icons.check_circle_outline,
        size: size,
        color: AppColors.statusConnected,
      ),
      AppActivityState.failure => Icon(
        Icons.error_outline,
        size: size,
        color: colors.error,
      ),
      AppActivityState.stopped => Icon(
        Icons.stop_circle_outlined,
        size: size,
        color: colors.onSurfaceVariant,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final bool expandable = widget.child != null;
    final Widget header = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 36),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: <Widget>[
            Tooltip(message: _stateLabel, child: _stateIcon(colors)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (widget.subtitle != null)
                    Text(
                      widget.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            for (final Widget badge in widget.badges) ...<Widget>[
              AppSpacing.controlGap,
              badge,
            ],
            if (widget.meta != null) ...<Widget>[
              const SizedBox(width: 8),
              Text(
                widget.meta!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
            if (expandable) ...<Widget>[
              AppSpacing.controlGap,
              Icon(
                _open ? Icons.expand_less : Icons.expand_more,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
            ],
          ],
        ),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: AppRadii.md,
      ),
      child: ClipRRect(
        borderRadius: AppRadii.md,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (expandable)
              Semantics(
                button: true,
                expanded: _open,
                label: '${widget.title}, $_stateLabel',
                excludeSemantics: true,
                child: InkWell(
                  onTap: () => setState(() => _open = !_open),
                  child: header,
                ),
              )
            else
              Semantics(
                label: '${widget.title}, $_stateLabel',
                excludeSemantics: true,
                child: header,
              ),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              alignment: Alignment.topCenter,
              child: expandable && _open
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      child: widget.child,
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

/// A labelled block of text inside an [AppActivityCard]: a tool's input, its
/// output, an error. Monospace, selectable with the surrounding
/// `SelectionArea`, and scrolls past [maxHeight] instead of growing.
final class AppActivitySection extends StatelessWidget {
  const AppActivitySection({
    required this.label,
    required this.text,
    this.isError = false,
    this.maxHeight = 160,
    super.key,
  });

  final String label;
  final String text;
  final bool isError;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: isError ? colors.error : colors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface.withValues(alpha: 0.6),
                borderRadius: AppRadii.xs,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(8),
                child: Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: isError ? colors.error : colors.onSurface,
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
