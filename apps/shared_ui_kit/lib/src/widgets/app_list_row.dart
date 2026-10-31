import 'package:flutter/material.dart';
import '../tokens/app_radii.dart';

/// A selectable navigation row: optional [leading], a [title] with an
/// optional [subtitle], and an optional [trailing]. It has the same visuals as
/// `FlyoutNavButton` (3px corners, `secondaryContainer` while [selected]).
///
/// [minHeight] raises the tappable height (mobile passes 48); null uses 32 for
/// [dense] rows (the height of a desktop `AppIconButton`) and 40 otherwise.
final class AppListRow extends StatelessWidget {
  const AppListRow({
    required this.title,
    required this.onTap,
    this.subtitle,
    this.leading,
    this.trailing,
    this.trailingInteractive = false,
    this.selected = false,
    this.dense = false,
    this.minHeight,
    this.onLongPress,
    this.semanticLabel,
    this.titleBold = false,
    this.flush = false,
    super.key,
  });

  /// Removes the row's padding all round, so its text starts at the left edge,
  /// its trailing controls end at the right edge, and its height is that of its
  /// content. Use it where the row sits in a form column whose own edges and
  /// row gap (AppSpacing.row) are the margin, not in a padded list.
  final bool flush;

  /// Sets the title in bold (a workspace name above its description).
  final bool titleBold;

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;

  /// Set when [trailing] holds its own controls (a switch, icon buttons): it
  /// is then laid out beside the tappable area, so it keeps its own
  /// semantics and taps instead of being folded into the row's.
  final bool trailingInteractive;
  final bool selected;
  final bool dense;
  final double? minHeight;

  /// Null disables the row.
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final Color foreground = selected
        ? colors.onSecondaryContainer
        : colors.onSurface;
    final BorderRadius radius = AppRadii.standard;
    final double vertical = flush ? 0 : (dense ? 4 : 8);
    final Widget content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight ?? (dense ? 32 : 40)),
      child: Padding(
        padding: EdgeInsets.only(
          left: flush ? 0 : 12,
          top: vertical,
          bottom: vertical,
          right: flush ? 0 : 12,
        ),
        child: Row(
          children: <Widget>[
            if (leading != null) ...<Widget>[
              IconTheme.merge(
                data: IconThemeData(size: 20, color: foreground),
                child: leading!,
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: foreground,
                      fontWeight: titleBold ? FontWeight.bold : null,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: selected
                            ? colors.onSecondaryContainer
                            : colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null && !trailingInteractive) ...<Widget>[
              const SizedBox(width: 8),
              trailing!,
            ],
          ],
        ),
      ),
    );
    final Color fill = selected
        ? colors.secondaryContainer
        : Colors.transparent;
    Widget semantic(Widget child) => Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      excludeSemantics: true,
      label: semanticLabel ?? (subtitle == null ? title : '$title, $subtitle'),
      onTap: onTap,
      onLongPress: onLongPress,
      child: child,
    );
    final Widget ink = InkWell(
      borderRadius: radius,
      onTap: onTap,
      onLongPress: onLongPress,
      child: content,
    );
    if (trailing != null && trailingInteractive) {
      return Material(
        color: fill,
        borderRadius: radius,
        child: Row(
          children: <Widget>[
            Expanded(child: semantic(ink)),
            Padding(
              padding: EdgeInsets.only(left: 4, right: flush ? 0 : 8),
              child: trailing,
            ),
          ],
        ),
      );
    }
    return semantic(Material(color: fill, borderRadius: radius, child: ink));
  }
}

/// A row in a file or folder tree: indented by [depth], [height] 30, with a
/// small [leading] icon, a [label] and an optional [trailing] (a chevron).
///
/// [highlighted] paints the selected fill without selecting, for a drop
/// target. Wrap the row in a `Draggable` / `DragTarget` for drag and drop.
/// [minHeight] raises the tappable height on touch layouts.
final class AppTreeRow extends StatelessWidget {
  const AppTreeRow({
    required this.label,
    required this.onTap,
    this.depth = 0,
    this.leading,
    this.trailing,
    this.selected = false,
    this.highlighted = false,
    this.height = 30,
    this.minHeight,
    this.subtitle,
    this.tooltip,
    this.onSecondaryTapDown,
    super.key,
  });

  final String label;

  /// A small second line under the [label] (the path of a top level folder).
  /// The row grows to fit it.
  final String? subtitle;

  /// Hover text; defaults to the [label].
  final String? tooltip;

  /// A right click or secondary tap, for a context menu.
  final GestureTapDownCallback? onSecondaryTapDown;
  final int depth;
  final Widget? leading;
  final Widget? trailing;
  final bool selected;
  final bool highlighted;
  final double height;
  final double? minHeight;

  /// Null makes the row inert (a placeholder such as "Loading…").
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final bool emphasized = selected || highlighted;
    const BorderRadius radius = AppRadii.standard;
    return Semantics(
      button: onTap != null,
      selected: selected,
      excludeSemantics: true,
      label: label,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: emphasized ? colors.secondaryContainer : Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            onSecondaryTapDown: onSecondaryTapDown,
            child: SizedBox(
              height: <double>[
                height,
                if (subtitle != null) 44,
                ?minHeight,
              ].reduce((double a, double b) => a > b ? a : b),
              child: Padding(
                padding: EdgeInsets.only(left: 6 + depth * 14, right: 6),
                child: Row(
                  children: <Widget>[
                    SizedBox(width: 18, child: Center(child: leading)),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Tooltip(
                        message: tooltip ?? label,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: emphasized
                                    ? colors.onSecondaryContainer
                                    : null,
                              ),
                            ),
                            if (subtitle != null)
                              Text(
                                subtitle!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: emphasized
                                      ? colors.onSecondaryContainer
                                      : colors.onSurfaceVariant,
                                ),
                              ),
                          ],
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
      ),
    );
  }
}
