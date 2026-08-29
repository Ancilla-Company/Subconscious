import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';

/// Shared Material theme assembled from raw design tokens.
abstract final class AppTheme {
  static ThemeData light() {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: AppColors.seed),
      scaffoldBackgroundColor: AppColors.surface,
      useMaterial3: true,
    );
  }
}
