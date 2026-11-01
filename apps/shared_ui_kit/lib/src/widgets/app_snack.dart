import 'package:flutter/material.dart';

import '../tokens/app_radii.dart';
import '../tokens/app_spacing.dart';
import 'app_icon_button.dart';

/// Shows a snack bar in the kit style: floating, flat, 3px corners, with
/// `secondaryContainer` colours (or `errorContainer` when [isError]). Replaces
/// any snack bar already showing.
///
/// The toast uses the standard 4 dp inset on all four sides. A small close
/// button sits in its top-right corner, 4 dp from the top and right edges. An
/// [action] goes under the message, at the right, so it never moves the close
/// button out of the corner.
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
        content: _AppSnackContent(
          message: message,
          foreground: foreground,
          onClose: () => messenger.hideCurrentSnackBar(
            reason: SnackBarClosedReason.dismiss,
          ),
          actionLabel: action?.label,
          actionColor: action?.textColor,
          onAction: action == null
              ? null
              : () {
                  action.onPressed();
                  messenger.hideCurrentSnackBar(
                    reason: SnackBarClosedReason.action,
                  );
                },
        ),
        behavior: SnackBarBehavior.floating,
        // Replaces the SnackBar's default 16 dp side and 14 dp vertical insets,
        // so the standard 4 dp inset is the only inset around the toast.
        padding: AppSpacing.standard,
        margin: margin ?? AppSpacing.standard,
        duration: duration,
        elevation: 0,
        backgroundColor: background,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadii.standard,
          side: BorderSide(color: colors.outlineVariant),
        ),
      ),
    );
}

final class _AppSnackContent extends StatelessWidget {
  const _AppSnackContent({
    required this.message,
    required this.foreground,
    required this.onClose,
    this.actionLabel,
    this.actionColor,
    this.onAction,
  });

  final String message;
  final Color foreground;
  final VoidCallback onClose;
  final String? actionLabel;
  final Color? actionColor;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            // As tall as the close button at least, with the text centred in
            // that height, so a one-line message sits level with the button
            // and has equal space above and below. A longer message grows past
            // the button and starts at the top.
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: AppIconButtonSize.small.dimension,
              ),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  message,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: foreground),
                ),
              ),
            ),
          ),
          AppSpacing.controlGap,
          AppIconButton(
            icon: Icons.close,
            tooltip: 'Close notification',
            size: AppIconButtonSize.small,
            iconSize: 18,
            foregroundColor: foreground,
            onPressed: onClose,
          ),
        ],
      ),
      if (actionLabel != null && onAction != null) ...<Widget>[
        const SizedBox(height: AppSpacing.control),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton(
            style: actionColor == null
                ? null
                : TextButton.styleFrom(foregroundColor: actionColor),
            onPressed: onAction,
            child: Text(actionLabel!),
          ),
        ),
      ],
    ],
  );
}
