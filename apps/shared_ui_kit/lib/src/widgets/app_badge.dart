import 'package:flutter/material.dart';

/// Tone of an [AppBadge].
enum AppBadgeTone { neutral, accent, error }

/// A small pill label (a count, "default", "offline", an attached file),
/// flat with 3px corners.
///
/// With an [icon] it leads the label. With [onDeleted] it ends in a close
/// button (a removable tag, like an attachment), named by [deleteTooltip]. The
/// label shrinks with an ellipsis beyond [maxWidth].
final class AppBadge extends StatelessWidget {
  const AppBadge(
    this.label, {
    this.tone = AppBadgeTone.neutral,
    this.icon,
    this.onDeleted,
    this.deleteTooltip = 'Remove',
    this.maxWidth,
    super.key,
  });

  final String label;
  final AppBadgeTone tone;
  final IconData? icon;
  final VoidCallback? onDeleted;
  final String deleteTooltip;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final (Color background, Color foreground) = switch (tone) {
      AppBadgeTone.neutral => (
        colors.surfaceContainerHighest,
        colors.onSurfaceVariant,
      ),
      AppBadgeTone.accent => (
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      AppBadgeTone.error => (colors.errorContainer, colors.onErrorContainer),
    };
    Widget text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(color: foreground),
    );
    if (maxWidth != null) {
      text = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth!),
        child: text,
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: const BorderRadius.all(Radius.circular(3)),
      ),
      child: Padding(
        padding: EdgeInsets.only(
          left: 6,
          right: onDeleted == null ? 6 : 0,
          top: 2,
          bottom: 2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 13, color: foreground),
              const SizedBox(width: 4),
            ],
            Flexible(child: text),
            if (onDeleted != null)
              Tooltip(
                message: deleteTooltip,
                child: Semantics(
                  button: true,
                  label: deleteTooltip,
                  excludeSemantics: true,
                  onTap: onDeleted,
                  child: InkWell(
                    onTap: onDeleted,
                    borderRadius: const BorderRadius.all(Radius.circular(3)),
                    child: SizedBox.square(
                      dimension: 24,
                      child: Icon(Icons.close, size: 14, color: foreground),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
