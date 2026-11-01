import 'package:flutter/material.dart';

import '../forms/app_form_theme.dart';
import '../forms/app_form_widgets.dart';

/// A dialog in the app's style: an [AppSectionHeading] [title], the [content],
/// and the [actions] in an [AppButtonRow]. Put plain `FilledButton`,
/// `OutlinedButton` and `TextButton` children in [actions].
///
/// Open it with [showAppDialog], which wraps it in [AppFormTheme].
final class AppDialog extends StatelessWidget {
  const AppDialog({
    this.title,
    this.content,
    this.actions = const <Widget>[],
    this.width,
    super.key,
  });

  final String? title;
  final Widget? content;
  final List<Widget> actions;

  /// Fixed content width (for example 360 for a short form); null sizes to
  /// the content.
  final double? width;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: title == null ? null : AppSectionHeading(title: title!),
    content: content == null ? null : SizedBox(width: width, child: content),
    scrollable: true,
    actions: actions.isEmpty ? null : <Widget>[AppButtonRow(children: actions)],
  );
}

/// Shows a dialog built by [builder] (normally returning an [AppDialog]) under
/// [AppFormTheme], so it matches every other form. Returns what the dialog
/// pops.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
}) => showDialog<T>(
  context: context,
  barrierDismissible: barrierDismissible,
  useRootNavigator: useRootNavigator,
  builder: (BuildContext context) =>
      AppFormTheme(child: Builder(builder: builder)),
);

/// A yes/no question in the app's style: a [title], a [message], a Cancel
/// button and a [confirmLabel] button that pops `true`. With [destructive]
/// the confirm button takes the error colours, for deletes and other actions
/// that cannot be undone.
///
/// Open it with [showAppConfirmDialog].
final class AppConfirmDialog extends StatelessWidget {
  const AppConfirmDialog({
    required this.title,
    required this.message,
    this.confirmLabel = 'OK',
    this.cancelLabel = 'Cancel',
    this.destructive = false,
    this.width = 380,
    super.key,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return AppDialog(
      title: title,
      width: width,
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: colors.error,
                  foregroundColor: colors.onError,
                )
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}

/// Asks [title] / [message] in an [AppConfirmDialog]. Returns true only when
/// the user confirms; Cancel, Escape and a tap outside return false.
Future<bool> showAppConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  String confirmLabel = 'OK',
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async =>
    await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => AppConfirmDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        destructive: destructive,
      ),
    ) ??
    false;
