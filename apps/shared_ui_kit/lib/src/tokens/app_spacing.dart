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

  /// The project's standard 4 dp inset on all four sides of compact surfaces
  /// and transient notices.
  static const EdgeInsets standard = EdgeInsets.all(4);

  /// A horizontal gap between neighbouring controls in a panel header or
  /// repeated compact rows.
  static const double header = 4;

  /// A horizontal [header] gap for header rows built by hand.
  static const Widget headerGap = SizedBox(width: header);

  /// The gap between two icon-only buttons placed side by side, such as a
  /// panel header's trailing actions or a form header's Cancel/Save pair.
  /// Kept as a compatibility alias for callers that use the more descriptive
  /// name; shared headers use [headerGap] directly.
  static const double iconRow = header;

  /// A horizontal [iconRow] gap, for icon-button rows built by hand.
  static const Widget iconRowGap = headerGap;
}
