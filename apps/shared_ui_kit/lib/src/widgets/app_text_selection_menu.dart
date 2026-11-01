import 'package:flutter/material.dart';

import '../forms/app_form_theme.dart';
import '../tokens/app_radii.dart';
import 'chiclet_menu.dart';

/// A text-field context menu (Cut/Copy/Paste/Select all) in the kit's own
/// popup style, instead of Flutter's default platform-styled toolbar.
///
/// Drop this in as a `contextMenuBuilder`:
/// ```dart
/// TextField(contextMenuBuilder: appTextSelectionContextMenuBuilder, ...)
/// ```
/// It keeps Flutter's own [EditableTextState.contextMenuButtonItems] (so
/// cut/copy/paste/select-all still do the right thing and disable themselves
/// correctly) and Flutter's own anchor positioning (clamped to the screen,
/// shifted clear of the status bar), but draws the menu itself as a rounded,
/// raised, chiclet-row list — the same surface, elevation and row look as
/// [showAppContextMenu] — rather than the default Material/Cupertino bar.
Widget appTextSelectionContextMenuBuilder(
  BuildContext context,
  EditableTextState editableTextState,
) {
  final List<ContextMenuButtonItem> items =
      editableTextState.contextMenuButtonItems;
  if (items.isEmpty) return const SizedBox.shrink();
  final TextSelectionToolbarAnchors anchors =
      editableTextState.contextMenuAnchors;
  const double screenPadding = 8;
  final double paddingAbove = MediaQuery.paddingOf(context).top + screenPadding;
  final Offset localAdjustment = Offset(screenPadding, paddingAbove);
  final PopupMenuThemeData menu = appFormTheme(context).popupMenuTheme;
  return Padding(
    padding: EdgeInsets.fromLTRB(
      screenPadding,
      paddingAbove,
      screenPadding,
      screenPadding,
    ),
    child: CustomSingleChildLayout(
      delegate: DesktopTextSelectionToolbarLayoutDelegate(
        anchor: anchors.primaryAnchor - localAdjustment,
      ),
      child: SizedBox(
        width: 190,
        child: Material(
          color: menu.color,
          surfaceTintColor: menu.surfaceTintColor,
          elevation: menu.elevation ?? 4,
          shape: menu.shape,
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final ContextMenuButtonItem item in items)
                  _AppTextSelectionMenuRow(item: item),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

final class _AppTextSelectionMenuRow extends StatelessWidget {
  const _AppTextSelectionMenuRow({required this.item});

  final ContextMenuButtonItem item;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool enabled = item.onPressed != null;
    final TextStyle? style =
        (theme.popupMenuTheme.textStyle ?? theme.textTheme.bodyMedium)
            ?.copyWith(
              color: enabled ? theme.colorScheme.onSurface : theme.disabledColor,
            );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: InkWell(
        borderRadius: AppRadii.standard,
        onTap: item.onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kChicletMenuRowHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                item.label ??
                    AdaptiveTextSelectionToolbar.getButtonLabel(context, item),
                style: style,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
