import 'package:flutter/material.dart';

/// Raw color tokens shared by all Flutter presentation platforms.
abstract final class AppColors {
  static const Color seed = Color(0xFF7C6FE0);
  static const Color surface = Color(0xFFF8F7FC);
  static const Color onSurface = Color(0xFF211F2B);

  /// Status indicator colours (engine / device connection). Used by
  /// `AppStatusDot`; never hard-code `Colors.green` / `red` / `amber`.
  static const Color statusConnected = Color(0xFF2E9E5B);
  static const Color statusConnecting = Color(0xFFE0A100);
  static const Color statusDisconnected = Color(0xFFD64545);

  /// Background of a text-search match in the editor and the markdown preview.
  /// Translucent so it works over light and dark surfaces.
  static const Color highlightFind = Color(0x59FFC107);

  /// Background of the current (selected) search match.
  static const Color highlightFindCurrent = Color(0x99FF9800);

  /// Warning banner colours. Amber whatever the accent, so a conflict never
  /// blends into a neutral (monochrome) theme.
  static const Color warningContainerLight = Color(0xFFFFF1C2);
  static const Color onWarningContainerLight = Color(0xFF4A3B00);
  static const Color warningContainerDark = Color(0xFF4A3B12);
  static const Color onWarningContainerDark = Color(0xFFFFE9A8);
}
