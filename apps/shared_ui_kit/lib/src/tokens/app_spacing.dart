import 'package:flutter/widgets.dart';

/// Spacing shared by every kit and app surface. Feature code uses these
/// instead of literal gaps between controls.
abstract final class AppSpacing {
  /// The gap between two neighbouring controls on one line: a field and its
  /// button, or one button and the next. The same on every platform, so a row
  /// of controls reads as one group.
  static const double control = 4;

  /// The vertical gap between stacked rows of controls (a field row, then the
  /// rows of items listed under it).
  static const double row = 8;

  /// A horizontal [control] gap, for rows built by hand.
  static const Widget controlGap = SizedBox(width: control);
}
