import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';

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
      useMaterial3: true,
    );
  }
}
