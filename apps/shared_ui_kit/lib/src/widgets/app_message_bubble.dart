import 'package:flutter/material.dart';
import '../tokens/app_radii.dart';

/// Who a chat bubble belongs to.
enum AppMessageRole { user, assistant, system }

/// A chat message bubble. User bubbles are right-aligned on
/// `secondaryContainer`; assistant bubbles are left-aligned on the lowest
/// surface with an `outlineVariant` border; system bubbles are centred, muted
/// and borderless. 3px corners throughout.
final class AppMessageBubble extends StatelessWidget {
  const AppMessageBubble({
    required this.role,
    required this.child,
    this.maxWidthFraction = 0.9,
    this.boxed = true,
    super.key,
  });

  final AppMessageRole role;
  final Widget child;

  /// Widest the bubble may grow, as a fraction of the available width.
  final double maxWidthFraction;

  /// Assistant only: false drops the fill, border and padding and lets the
  /// content use the full width (long markdown answers read better unboxed).
  final bool boxed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final (
      Color background,
      Color foreground,
      Alignment alignment,
    ) = switch (role) {
      AppMessageRole.user => (
        colors.secondaryContainer,
        colors.onSecondaryContainer,
        Alignment.centerRight,
      ),
      AppMessageRole.assistant => (
        colors.surfaceContainerLowest,
        colors.onSurface,
        Alignment.centerLeft,
      ),
      AppMessageRole.system => (
        Colors.transparent,
        colors.onSurfaceVariant,
        Alignment.center,
      ),
    };
    if (role == AppMessageRole.assistant && !boxed) {
      return SizedBox(
        width: double.infinity,
        child: DefaultTextStyle.merge(
          style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
          child: child,
        ),
      );
    }
    return Align(
      alignment: alignment,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: constraints.maxWidth.isFinite
                  ? constraints.maxWidth * maxWidthFraction
                  : double.infinity,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: background,
                borderRadius: AppRadii.standard,
                border: role == AppMessageRole.assistant
                    ? Border.all(color: colors.outlineVariant)
                    : null,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: DefaultTextStyle.merge(
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: foreground,
                  ),
                  textAlign: role == AppMessageRole.system
                      ? TextAlign.center
                      : null,
                  child: child,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
