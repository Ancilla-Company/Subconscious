import 'package:flutter/material.dart';

/// A compact icon button for application navigation sidebars.
final class SidebarButton extends StatelessWidget {
  const SidebarButton({
    required this.icon,
    required this.selectedIcon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.dimension = 32,
    this.outerPadding = EdgeInsets.zero,
    this.borderRadius = 4,
    this.badge = false,
    super.key,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final double dimension;
  final EdgeInsets outerPadding;
  final double borderRadius;

  /// Shows a small attention dot on the corner (unread, update available).
  final bool badge;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: outerPadding,
      child: SizedBox.square(
        dimension: dimension,
        child: Stack(
          children: <Widget>[
            Positioned.fill(child: _button(colors)),
            if (badge)
              Positioned(
                top: 5,
                right: 5,
                child: IgnorePointer(
                  child: Semantics(
                    label: 'Needs attention',
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.error,
                        shape: BoxShape.circle,
                      ),
                      child: const SizedBox.square(dimension: 8),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _button(ColorScheme colors) {
    return SizedBox.square(
      dimension: dimension,
      child: IconButton(
        constraints: BoxConstraints.tightFor(
          width: dimension,
          height: dimension,
        ),
        isSelected: selected,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        selectedIcon: Icon(selectedIcon, size: 20),
        style: IconButton.styleFrom(
          backgroundColor: selected ? colors.secondaryContainer : null,
          foregroundColor: selected ? colors.onSecondaryContainer : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(borderRadius),
          ),
        ),
        tooltip: tooltip,
        icon: Icon(icon, size: 20),
      ),
    );
  }
}
