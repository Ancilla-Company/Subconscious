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

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: outerPadding,
      child: SizedBox.square(
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
      ),
    );
  }
}
