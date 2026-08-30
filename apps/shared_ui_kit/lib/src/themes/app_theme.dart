import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';

/// Shared Material theme assembled from raw design tokens.
abstract final class AppTheme {
  static ThemeData light({Color seedColor = AppColors.seed}) =>
      _build(seedColor: seedColor, brightness: Brightness.light);

  static ThemeData dark({Color seedColor = AppColors.seed}) =>
      _build(seedColor: seedColor, brightness: Brightness.dark);

  static ThemeData _build({
    required Color seedColor,
    required Brightness brightness,
  }) {
    final ColorScheme colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      useMaterial3: true,
    );
  }
}
