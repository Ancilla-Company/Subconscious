import 'package:flutter/material.dart';

import '../forms/app_form_widgets.dart';
import '../tokens/app_colors.dart';

/// Severity of an [AppBanner].
enum AppBannerTone { info, warning, error }

/// An inline notice with a [message], an optional [title] and [actions]
/// (plain `TextButton` / `OutlinedButton` children). Flat, 3px corners.
/// Announced to screen readers as a live region.
final class AppBanner extends StatelessWidget {
  const AppBanner({
    required this.message,
    this.tone = AppBannerTone.info,
    this.title,
    this.actions = const <Widget>[],
    this.preface,
    this.content,
    this.messageMaxLines,
    super.key,
  });

  final String message;
  final String? title;
  final AppBannerTone tone;
  final List<Widget> actions;

  /// Shown above the title (for example who is asking).
  final Widget? preface;

  /// Extra body below the message and above the [actions] (a form field).
  final Widget? content;

  /// Truncates a long [message] with an ellipsis; null shows all of it.
  final int? messageMaxLines;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;
    final (Color background, Color foreground, IconData icon) = switch (tone) {
      AppBannerTone.info => (
        colors.secondaryContainer,
        colors.onSecondaryContainer,
        Icons.info_outline,
      ),
      AppBannerTone.warning => (
        dark ? AppColors.warningContainerDark : AppColors.warningContainerLight,
        dark
            ? AppColors.onWarningContainerDark
            : AppColors.onWarningContainerLight,
        Icons.warning_amber_outlined,
      ),
      AppBannerTone.error => (
        colors.errorContainer,
        colors.onErrorContainer,
        Icons.error_outline,
      ),
    };
    return Semantics(
      liveRegion: true,
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: const BorderRadius.all(Radius.circular(3)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(icon, size: 18, color: foreground),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        ?preface,
                        if (title != null)
                          Text(
                            title!,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: foreground,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        Text(
                          message,
                          maxLines: messageMaxLines,
                          overflow: messageMaxLines == null
                              ? null
                              : TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: foreground,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (content != null) ...<Widget>[
                const SizedBox(height: 8),
                content!,
              ],
              if (actions.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Theme(
                  data: theme.copyWith(
                    colorScheme: colors.copyWith(primary: foreground),
                  ),
                  child: AppButtonRow(children: actions),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
