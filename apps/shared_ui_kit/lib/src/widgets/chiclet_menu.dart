import 'package:flutter/material.dart';

import '../forms/app_form_theme.dart';
import '../tokens/app_radii.dart';

/// Row height of every menu chiclet: the height of a context panel button.
const double kChicletMenuRowHeight = 32;

/// A menu row drawn as a rounded chiclet: inset from the menu edge, with a
/// rounded hover/press fill like the context panel buttons. [selected] keeps
/// a light fill on the current choice (dropdowns).
///
/// Used by every popup menu and dropdown in the kit, so they all share one
/// size, spacing and look. Not exported: feature code uses `AppPopupMenu`,
/// `AppDropdown` and friends.
final class ChicletMenuItem<T> extends PopupMenuItem<T> {
  const ChicletMenuItem({
    required super.child,
    super.key,
    super.value,
    super.enabled,
    super.height = kChicletMenuRowHeight,
    this.selected = false,
  }) : super(padding: const EdgeInsets.symmetric(horizontal: 12));

  final bool selected;

  @override
  PopupMenuItemState<T, PopupMenuItem<T>> createState() =>
      _ChicletMenuItemState<T>();
}

final class _ChicletMenuItemState<T>
    extends PopupMenuItemState<T, ChicletMenuItem<T>> {
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle style =
        (theme.popupMenuTheme.textStyle ?? theme.textTheme.bodyMedium!)
            .copyWith(
              color: widget.enabled
                  ? theme.colorScheme.onSurface
                  : theme.disabledColor,
            );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Semantics(
        enabled: widget.enabled,
        button: true,
        selected: widget.selected,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: widget.selected
                ? theme.colorScheme.onSurface.withValues(alpha: 0.08)
                : null,
            borderRadius: AppRadii.md,
          ),
          child: InkWell(
            borderRadius: AppRadii.md,
            onTap: widget.enabled ? handleTap : null,
            canRequestFocus: widget.enabled,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: widget.height),
              child: Padding(
                padding: widget.padding!,
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: DefaultTextStyle(style: style, child: buildChild()!),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens [items] as a menu directly under [anchor], as wide as the anchor
/// (a dropdown). Returns the chosen value, or null when dismissed.
Future<T?> showChicletMenuBelow<T>({
  required BuildContext anchor,
  required List<PopupMenuEntry<T>> items,
}) {
  final RenderBox button = anchor.findRenderObject()! as RenderBox;
  final RenderBox overlay =
      Navigator.of(anchor).overlay!.context.findRenderObject()! as RenderBox;
  final Offset topLeft = button.localToGlobal(
    Offset(0, button.size.height + 4),
    ancestor: overlay,
  );
  final Offset bottomRight = button.localToGlobal(
    button.size.bottomRight(Offset.zero),
    ancestor: overlay,
  );
  final PopupMenuThemeData menu = appFormTheme(anchor).popupMenuTheme;
  return showMenu<T>(
    context: anchor,
    position: RelativeRect.fromRect(
      Rect.fromPoints(topLeft, bottomRight),
      Offset.zero & overlay.size,
    ),
    constraints: BoxConstraints(
      minWidth: button.size.width,
      maxWidth: button.size.width,
    ),
    color: menu.color,
    surfaceTintColor: menu.surfaceTintColor,
    elevation: menu.elevation,
    shape: menu.shape,
    menuPadding: menu.menuPadding,
    items: items,
  );
}
