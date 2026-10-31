import 'package:flutter/material.dart';

import '../tokens/app_radii.dart';
import 'app_popup_menu.dart';

/// A picker button: an optional leading [icon], the current choice as its
/// [label], and a down chevron. It opens the [items] in the kit's popup menu
/// (icons, a tick-fill on the current choice) and reports the pick through
/// [onSelected].
///
/// This is the workspace switcher of the title bar and the threads panel. It
/// has no fill or outline at rest and a rounded hover fill, so it sits on any
/// surface, and it brings its own [height], ink and padding. Its width is the
/// parent's: put it in a `SizedBox` or an `Expanded`. For a form field that
/// picks from strings use `AppDropdown`; for a toolbar dropdown that shows
/// the choice list as wide as the button use `AppCompactDropdown`.
///
/// [foreground] colours the icon, label and chevron where the surface is not
/// themed (the window caption bar); null uses the theme's `onSurface`.
final class AppPickerButton<T> extends StatelessWidget {
  const AppPickerButton({
    required this.label,
    required this.items,
    required this.onSelected,
    this.icon,
    this.tooltip,
    this.enabled = true,
    this.foreground,
    this.height = 32,
    this.padding = const EdgeInsets.symmetric(horizontal: 8),
    super.key,
  });

  /// The current choice, shown on the button.
  final String label;
  final List<AppMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final IconData? icon;

  /// Hover text and screen reader name; defaults to [label].
  final String? tooltip;
  final bool enabled;
  final Color? foreground;

  /// Height of the button. Touch layouts pass their larger target (48).
  final double height;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color color =
        (foreground ?? theme.colorScheme.onSurface).withValues(
          alpha: enabled ? 1 : 0.38,
        );
    return Material(
      type: MaterialType.transparency,
      borderRadius: AppRadii.standard,
      clipBehavior: Clip.antiAlias,
      child: AppPopupMenu<T>(
        tooltip: tooltip ?? label,
        enabled: enabled,
        items: items,
        onSelected: onSelected,
        child: SizedBox(
          height: height,
          child: Padding(
            padding: padding,
            child: Row(
              children: <Widget>[
                if (icon != null) ...<Widget>[
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 7),
                ],
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(color: color),
                  ),
                ),
                Icon(Icons.expand_more, size: 16, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
