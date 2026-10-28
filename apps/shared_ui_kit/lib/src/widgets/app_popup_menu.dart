import 'package:flutter/material.dart';

import '../forms/app_form_theme.dart';
import 'app_bottom_sheet.dart';
import 'app_icon_button.dart';
import 'app_list_row.dart';

/// One entry in an [AppPopupMenu].
///
/// A non-null [checked] reserves a check column and shows a tick when true
/// (a single-choice list). [subtitle] adds a second, smaller line.
final class AppMenuItem<T> {
  const AppMenuItem({
    required this.value,
    required this.label,
    this.icon,
    this.subtitle,
    this.checked,
    this.enabled = true,
    this.key,
  });

  final T value;
  final String label;
  final IconData? icon;
  final String? subtitle;
  final bool? checked;
  final bool enabled;
  final Key? key;
}

/// A popup menu in the kit style (flat, 3px corners, bordered).
///
/// Provide a [child] to use any widget as the trigger, or leave it null for an
/// icon trigger drawn like an `AppIconButton` ([icon], default "more").
///
/// With [sheetBreakpoint] set, windows narrower than that many logical pixels
/// open the same items in an `AppBottomSheet` (touch sized rows) instead of a
/// floating menu, so phones get a thumb-reachable list.
final class AppPopupMenu<T> extends StatelessWidget {
  const AppPopupMenu({
    required this.items,
    required this.onSelected,
    this.child,
    this.tooltip = 'More',
    this.enabled = true,
    this.icon = Icons.more_vert,
    this.iconSize = 20,
    this.size = AppIconButtonSize.compact,
    this.minTouchTarget,
    this.sheetBreakpoint,
    this.sheetTitle,
    super.key,
  });

  final List<AppMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final Widget? child;
  final String tooltip;
  final bool enabled;

  /// Icon of the default trigger (ignored when [child] is set).
  final IconData icon;
  final double iconSize;
  final AppIconButtonSize size;
  final double? minTouchTarget;

  /// Window width below which the items open in a bottom sheet.
  final double? sheetBreakpoint;
  final String? sheetTitle;

  bool _useSheet(BuildContext context) =>
      sheetBreakpoint != null &&
      MediaQuery.sizeOf(context).width < sheetBreakpoint!;

  Future<void> _openSheet(BuildContext context) async {
    final T? chosen = await showAppBottomSheet<T>(
      context: context,
      title: sheetTitle ?? tooltip,
      builder: (BuildContext sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final AppMenuItem<T> item in items)
            AppListRow(
              key: item.key,
              title: item.label,
              subtitle: item.subtitle,
              minHeight: 48,
              selected: item.checked ?? false,
              leading: item.icon == null ? null : Icon(item.icon),
              trailing: item.checked ?? false ? const Icon(Icons.check) : null,
              onTap: item.enabled
                  ? () => Navigator.of(sheetContext).pop(item.value)
                  : null,
            ),
        ],
      ),
    );
    if (chosen is T) onSelected(chosen);
  }

  @override
  Widget build(BuildContext context) {
    if (_useSheet(context)) {
      if (child != null) {
        return Semantics(
          button: true,
          label: tooltip,
          child: InkWell(
            onTap: enabled ? () => _openSheet(context) : null,
            child: child,
          ),
        );
      }
      return AppIconButton(
        icon: icon,
        tooltip: tooltip,
        iconSize: iconSize,
        size: size,
        minTouchTarget: minTouchTarget,
        onPressed: enabled ? () => _openSheet(context) : null,
      );
    }
    final PopupMenuThemeData menu = appFormTheme(context).popupMenuTheme;
    return PopupMenuButton<T>(
      tooltip: tooltip,
      enabled: enabled,
      color: menu.color,
      surfaceTintColor: menu.surfaceTintColor,
      elevation: menu.elevation,
      shape: menu.shape,
      onSelected: onSelected,
      padding: EdgeInsets.zero,
      style: child == null
          ? appIconButtonStyle(
              context,
              size: size,
              minTouchTarget: minTouchTarget,
            )
          : null,
      icon: child == null ? Icon(icon, size: iconSize) : null,
      child: child,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<T>>[
        for (final AppMenuItem<T> item in items)
          PopupMenuItem<T>(
            key: item.key,
            value: item.value,
            enabled: item.enabled,
            height: item.subtitle == null ? 36 : 44,
            child: Row(
              children: <Widget>[
                if (item.checked != null) ...<Widget>[
                  SizedBox(
                    width: 18,
                    child: item.checked!
                        ? const Icon(Icons.check, size: 16)
                        : null,
                  ),
                  const SizedBox(width: 8),
                ],
                if (item.icon != null) ...<Widget>[
                  Icon(item.icon, size: 18),
                  const SizedBox(width: 10),
                ],
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(item.label, overflow: TextOverflow.ellipsis),
                      if (item.subtitle != null)
                        Text(
                          item.subtitle!,
                          style: Theme.of(context).textTheme.labelSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Opens [items] as a context menu at [position] (a right click: pass
/// `details.globalPosition`), in the same kit style as [AppPopupMenu]. Returns
/// the chosen value, or null when the menu is dismissed.
Future<T?> showAppContextMenu<T>({
  required BuildContext context,
  required Offset position,
  required List<AppMenuItem<T>> items,
}) {
  final PopupMenuThemeData menu = appFormTheme(context).popupMenuTheme;
  final Size screen = MediaQuery.sizeOf(context);
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      screen.width - position.dx,
      screen.height - position.dy,
    ),
    color: menu.color,
    surfaceTintColor: menu.surfaceTintColor,
    elevation: menu.elevation,
    shape: menu.shape,
    items: <PopupMenuEntry<T>>[
      for (final AppMenuItem<T> item in items)
        PopupMenuItem<T>(
          key: item.key,
          value: item.value,
          enabled: item.enabled,
          height: 36,
          child: Row(
            children: <Widget>[
              if (item.icon != null) ...<Widget>[
                Icon(item.icon, size: 18),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Text(item.label, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
    ],
  );
}
