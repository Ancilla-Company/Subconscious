import 'package:flutter/material.dart';

import '../tokens/app_radii.dart';

/// The one definition of how a button looks in the app.
///
/// `FilledButton`, `OutlinedButton`, `TextButton` and `IconButton` are the
/// kit's buttons; this class is what makes them the kit's. It is applied twice
/// so that no screen depends on being wrapped to get the look:
///
/// * [AppTheme] puts it on the app's root theme, so a button anywhere (a
///   banner, a toolbar, a popup opened outside a page) is flat with 3px
///   corners.
/// * `appFormTheme` puts the same themes on forms, settings pages and dialogs.
///
/// Change a button's look here, once. Do not restyle a button locally.
abstract final class AppButtonStyles {
  /// Flat, 3px corners, on every button.
  static const RoundedRectangleBorder shape = RoundedRectangleBorder(
    borderRadius: AppRadii.xs,
  );

  static FilledButtonThemeData filled() =>
      FilledButtonThemeData(style: FilledButton.styleFrom(shape: shape));

  static OutlinedButtonThemeData outlined(ColorScheme colors) =>
      OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: shape,
          side: BorderSide(color: colors.outlineVariant),
        ),
      );

  static TextButtonThemeData text() =>
      TextButtonThemeData(style: TextButton.styleFrom(shape: shape));

  static IconButtonThemeData icon() =>
      IconButtonThemeData(style: IconButton.styleFrom(shape: shape));

  static SegmentedButtonThemeData segmented(ColorScheme colors) =>
      SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: const WidgetStatePropertyAll<OutlinedBorder>(shape),
          side: WidgetStatePropertyAll<BorderSide>(
            BorderSide(color: colors.outlineVariant),
          ),
          visualDensity: VisualDensity.compact,
        ),
      );
}
