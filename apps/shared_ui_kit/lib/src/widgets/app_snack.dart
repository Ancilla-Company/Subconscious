import 'package:flutter/material.dart';

/// Shows a snack bar in the kit style: floating, flat, 3px corners, with
/// `secondaryContainer` colours (or `errorContainer` when [isError]). Replaces
/// any snack bar already showing.
///
/// The styling is applied here, not through the theme, because a snack bar is
/// built under the Scaffold and does not see a local `AppFormTheme`.
/// [margin] positions it (for example over a single panel).
void showAppSnack(
  BuildContext context,
  String message, {
  bool isError = false,
  Duration duration = const Duration(seconds: 4),
  EdgeInsetsGeometry? margin,
  SnackBarAction? action,
}) {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final ColorScheme colors = Theme.of(context).colorScheme;
  final Color background = isError
      ? colors.errorContainer
      : colors.secondaryContainer;
  final Color foreground = isError
      ? colors.onErrorContainer
      : colors.onSecondaryContainer;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          message,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: foreground),
        ),
        behavior: SnackBarBehavior.floating,
        margin: margin,
        duration: duration,
        elevation: 0,
        showCloseIcon: true,
        backgroundColor: background,
        closeIconColor: foreground,
        action: action,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(3)),
          side: BorderSide(color: colors.outlineVariant),
        ),
      ),
    );
}
