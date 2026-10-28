import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import 'app_button_theme.dart';

/// Shared Material theme assembled from raw design tokens.
abstract final class AppTheme {
  static ThemeData light({
    Color seedColor = AppColors.seed,
    bool monochrome = false,
  }) => _build(
    seedColor: seedColor,
    brightness: Brightness.light,
    monochrome: monochrome,
  );

  static ThemeData dark({
    Color seedColor = AppColors.seed,
    bool monochrome = false,
  }) => _build(
    seedColor: seedColor,
    brightness: Brightness.dark,
    monochrome: monochrome,
  );

  static ThemeData _build({
    required Color seedColor,
    required Brightness brightness,
    required bool monochrome,
  }) {
    final ColorScheme colorScheme = monochrome
        ? ColorScheme.fromSeed(
            seedColor: seedColor,
            brightness: brightness,
            dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
          )
        : ColorScheme.fromSeed(seedColor: seedColor, brightness: brightness);
    return ThemeData(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      // Every button in the app is a kit button, wherever it is placed.
      filledButtonTheme: AppButtonStyles.filled(),
      outlinedButtonTheme: AppButtonStyles.outlined(colorScheme),
      textButtonTheme: AppButtonStyles.text(),
      iconButtonTheme: AppButtonStyles.icon(),
      segmentedButtonTheme: AppButtonStyles.segmented(colorScheme),
      useMaterial3: true,
    );
  }
}
