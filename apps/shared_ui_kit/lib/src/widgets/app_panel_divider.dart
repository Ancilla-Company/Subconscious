import 'package:flutter/material.dart';

/// The 5px draggable handle between two resizable desktop panels, with a 1px
/// `outlineVariant` rule in the middle. Reports horizontal drags through
/// [onDragUpdate]; with a null callback it is a plain, non-interactive rule.
final class AppPanelDivider extends StatelessWidget {
  const AppPanelDivider({
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    super.key,
  });

  /// Width of the handle in logical pixels.
  static const double width = 5;

  final GestureDragStartCallback? onDragStart;
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Widget handle = ColoredBox(
      color: colors.surface,
      child: SizedBox(
        width: width,
        height: double.infinity,
        child: Stack(
          children: <Widget>[
            Positioned(
              left: 2,
              top: 0,
              bottom: 0,
              width: 1,
              child: ColoredBox(color: colors.outlineVariant),
            ),
          ],
        ),
      ),
    );
    if (onDragUpdate == null) return handle;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: onDragStart,
        onHorizontalDragUpdate: onDragUpdate,
        onHorizontalDragEnd: onDragEnd,
        onHorizontalDragCancel: () => onDragEnd?.call(DragEndDetails()),
        child: handle,
      ),
    );
  }
}

/// A full-height 1px vertical rule (between a sidebar and the panels).
final class AppVerticalRule extends StatelessWidget {
  const AppVerticalRule({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 1,
    height: double.infinity,
    child: ColoredBox(color: Theme.of(context).colorScheme.outlineVariant),
  );
}

/// A short horizontal rule that separates groups of buttons in a sidebar.
final class AppSidebarDivider extends StatelessWidget {
  const AppSidebarDivider({super.key});

  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    thickness: 1,
    indent: 4,
    endIndent: 4,
    color: Theme.of(context).colorScheme.outlineVariant,
  );
}
