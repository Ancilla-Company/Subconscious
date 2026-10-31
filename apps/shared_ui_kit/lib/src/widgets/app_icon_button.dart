import 'package:flutter/material.dart';

import '../tokens/app_radii.dart';

/// Visual size of an [AppIconButton].
enum AppIconButtonSize {
  /// 24 dp, for a control inside another control, such as the close button of
  /// a tab. Leaves room above and below it in a 34 dp tab.
  small(24),

  /// 32 dp, for dense desktop toolbars and panel headers.
  compact(32),

  /// 40 dp, the default for touch layouts.
  regular(40);

  const AppIconButtonSize(this.dimension);
  final double dimension;
}

/// The [ButtonStyle] of an [AppIconButton], for controls that must be built on
/// another Material widget (a popup menu trigger) yet look identical.
ButtonStyle appIconButtonStyle(
  BuildContext context, {
  AppIconButtonSize size = AppIconButtonSize.compact,
  double? minTouchTarget,
  bool selected = false,
  bool outlined = false,
}) {
  final ColorScheme colors = Theme.of(context).colorScheme;
  final double dimension = <double>[
    size.dimension,
    minTouchTarget ?? 0,
  ].reduce((double a, double b) => a > b ? a : b);
  return IconButton.styleFrom(
    // Outlined buttons sit beside form fields, so they take the field look:
    // the `surfaceContainerLowest` fill and an `outlineVariant` border.
    backgroundColor: selected
        ? colors.secondaryContainer
        : outlined
        ? colors.surfaceContainerLowest
        : null,
    foregroundColor: selected ? colors.onSecondaryContainer : null,
    side: outlined ? BorderSide(color: colors.outlineVariant) : null,
    minimumSize: Size.square(dimension),
    fixedSize: Size.square(dimension),
    padding: EdgeInsets.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    shape: const RoundedRectangleBorder(borderRadius: AppRadii.standard),
  );
}

/// The app's one icon button: flat, 3px corners, a tooltip, and a
/// `secondaryContainer` fill while [selected].
///
/// [minTouchTarget] raises the tappable box above the visual size (mobile
/// layouts pass 44 to 48); the button fills the whole box.
final class AppIconButton extends StatelessWidget {
  const AppIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selectedIcon,
    this.selected = false,
    this.size = AppIconButtonSize.compact,
    this.minTouchTarget,
    this.iconSize,
    this.busy = false,
    this.destructive = false,
    this.outlined = false,
    super.key,
  });

  /// Draws the button like a form field (field fill and border). Use it for
  /// the actions that sit next to or act on fields: copy a value, add or
  /// remove an item, save or cancel a form. Toolbar buttons stay flat.
  final bool outlined;

  final IconData icon;

  /// Icon shown while [selected]; defaults to [icon].
  final IconData? selectedIcon;
  final String tooltip;

  /// Null disables the button.
  final VoidCallback? onPressed;
  final bool selected;
  final AppIconButtonSize size;

  /// Minimum width and height of the tappable area; null uses the [size].
  final double? minTouchTarget;

  /// Glyph size. Null picks the kit default: 17 for an [outlined] button (it
  /// sits beside a field) and 20 for a flat toolbar button.
  final double? iconSize;

  /// Replaces the icon with a small spinner while work is in progress.
  final bool busy;

  /// Tints the icon with the error colour (delete, remove).
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final double dimension = <double>[
      size.dimension,
      minTouchTarget ?? 0,
    ].reduce((double a, double b) => a > b ? a : b);
    final double glyph = iconSize ?? (outlined ? 17 : 20);
    return SizedBox.square(
      dimension: dimension,
      child: IconButton(
        constraints: BoxConstraints.tightFor(
          width: dimension,
          height: dimension,
        ),
        padding: EdgeInsets.zero,
        isSelected: selected,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: busy ? _spinner(glyph) : Icon(icon, size: glyph),
        selectedIcon: busy
            ? _spinner(glyph)
            : Icon(selectedIcon ?? icon, size: glyph),
        style: IconButton.styleFrom(
          backgroundColor: selected
              ? colors.secondaryContainer
              : outlined
              ? colors.surfaceContainerLowest
              : null,
          foregroundColor: destructive
              ? colors.error
              : selected
              ? colors.onSecondaryContainer
              : null,
          side: outlined ? BorderSide(color: colors.outlineVariant) : null,
          minimumSize: Size.square(dimension),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.standard),
        ),
      ),
    );
  }

  Widget _spinner(double glyph) => SizedBox.square(
    dimension: glyph - 6,
    child: const CircularProgressIndicator(strokeWidth: 2),
  );
}
