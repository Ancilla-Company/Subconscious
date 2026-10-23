import 'package:flutter/material.dart';

/// A full-width flyout menu button with an icon followed by its label.
///
/// Matches the context panel row styling: rounded, with a
/// `secondaryContainer` background while [selected].
final class FlyoutNavButton extends StatelessWidget {
  const FlyoutNavButton({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.height,
    super.key,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color foreground = selected
        ? colors.onSecondaryContainer
        : colors.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      excludeSemantics: true,
      label: label,
      onTap: onPressed,
      child: Material(
        color: selected ? colors.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onPressed,
          child: SizedBox(
            height: height,
            child: Padding(
              // A compact row (32 dp, as in the extension) has no room for the
              // default 8 dp of vertical padding around a 20 dp icon.
              padding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: height != null && height! < 36 ? 6 : 8,
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    selected ? selectedIcon : icon,
                    size: 20,
                    color: foreground,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: foreground),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
