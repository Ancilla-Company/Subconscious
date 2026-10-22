import 'package:flutter/material.dart';

import '../tokens/app_radii.dart';

/// A compact horizontal toolbar surface (editor ribbons, find bars): a
/// `surfaceContainerLow` strip with 6px corners that wraps its [children] onto
/// more lines when narrow. Use `AppIconButton` for the buttons and
/// [AppToolbarDivider] between groups.
final class AppToolbar extends StatelessWidget {
  const AppToolbar({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(6)),
      child: ColoredBox(
        color: colors.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// A thin vertical rule between groups of buttons in an [AppToolbar].
final class AppToolbarDivider extends StatelessWidget {
  const AppToolbarDivider({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6),
    child: SizedBox(
      width: 1,
      height: 20,
      child: ColoredBox(color: Theme.of(context).colorScheme.outlineVariant),
    ),
  );
}

/// A small toggle that shows a short text label (the case, whole-word and
/// regex options of a find bar). 28dp square, 4px corners, filled with
/// `secondaryContainer` while [selected].
final class AppTextToggle extends StatelessWidget {
  const AppTextToggle({
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onPressed,
    this.underline = false,
    super.key,
  });

  final String label;
  final String tooltip;
  final bool selected;
  final bool underline;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        toggled: selected,
        label: tooltip,
        child: SizedBox.square(
          dimension: 28,
          child: Material(
            color: selected ? colors.secondaryContainer : Colors.transparent,
            borderRadius: AppRadii.sm,
            child: InkWell(
              borderRadius: AppRadii.sm,
              canRequestFocus: false,
              onTap: onPressed,
              child: Center(
                child: ExcludeSemantics(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      decoration: underline
                          ? TextDecoration.underline
                          : TextDecoration.none,
                      color: selected
                          ? colors.onSecondaryContainer
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
