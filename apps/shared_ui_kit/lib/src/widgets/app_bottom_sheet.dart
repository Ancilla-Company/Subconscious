import 'package:flutter/material.dart';

import '../forms/app_form_theme.dart';
import '../forms/app_form_widgets.dart';
import '../tokens/app_radii.dart';

/// The body of a bottom sheet: a drag handle, an optional [title], and the
/// [child], inside the safe area and lifted above the on-screen keyboard.
/// Open it with [showAppBottomSheet].
final class AppBottomSheet extends StatelessWidget {
  const AppBottomSheet({required this.child, this.title, super.key});

  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final double keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 100),
      padding: EdgeInsets.only(bottom: keyboard),
      // While the keyboard is up it already covers the home indicator, so the
      // bottom safe area would only add a gap above the keys.
      child: SafeArea(
        top: false,
        bottom: keyboard == 0,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Semantics(
                  label: 'Drag handle',
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.outlineVariant,
                      borderRadius: AppRadii.standard,
                    ),
                    child: const SizedBox(width: 32, height: 4),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (title != null) ...<Widget>[
                AppSectionHeading(title: title!),
                const SizedBox(height: 12),
              ],
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows a modal bottom sheet with [builder]'s content under [AppFormTheme],
/// wrapped in an [AppBottomSheet].
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String? title,
  bool isDismissible = true,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  isDismissible: isDismissible,
  useSafeArea: true,
  builder: (BuildContext context) => AppFormTheme(
    child: AppBottomSheet(
      title: title,
      child: Builder(builder: builder),
    ),
  ),
);
