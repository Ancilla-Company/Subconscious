import 'dart:ui' show FlutterView;

import 'package:flutter/widgets.dart';

/// How large a control is, decided from the screen the app is actually on.
///
/// One size serves every platform: [control] (32 dp). A control only grows to
/// [touchControl] (48 dp) when the display itself is small enough that a
/// finger needs the room: a handset, whatever it runs. Neither the platform
/// name nor the width of the window takes part. A narrow window on a large
/// monitor is still a large screen, so its buttons stay 32 dp.
///
/// Width checks elsewhere decide *structure* (drawer or sidebar, one panel or
/// three); they never size a widget.
abstract final class AppDensity {
  /// Height and width of a control on every screen but a small one.
  static const double control = 32;

  /// Height and width of a control on a small screen.
  static const double touchControl = 48;

  /// A display whose shorter side is below this many logical pixels is a small
  /// screen (Material's compact class: every handset, no tablet or monitor).
  static const double smallScreenShortestSide = 600;

  /// The control size for a display of [displaySize] (logical pixels).
  static double controlSizeFor(Size displaySize) =>
      displaySize.shortestSide < smallScreenShortestSide
      ? touchControl
      : control;

  /// The logical size of the display [context]'s view is shown on, read from
  /// the display itself (its pixel size and pixel ratio). Falls back to the
  /// view's own size only when the platform reports no display.
  static Size displaySize(BuildContext context) {
    final FlutterView? view = View.maybeOf(context);
    if (view != null) {
      final double ratio = view.display.devicePixelRatio;
      final Size physical = view.display.size;
      if (ratio > 0 && physical.shortestSide > 0) return physical / ratio;
    }
    return MediaQuery.sizeOf(context);
  }

  /// Whether the app is on a small screen.
  static bool isSmallScreen(BuildContext context) =>
      displaySize(context).shortestSide < smallScreenShortestSide;

  /// The size of a control here: [control] or [touchControl].
  static double controlSize(BuildContext context) =>
      controlSizeFor(displaySize(context));

  /// The `minTouchTarget` to hand to kit widgets: [touchControl] on a small
  /// screen, null (their own 32 dp) otherwise.
  static double? minTouchTarget(BuildContext context) =>
      isSmallScreen(context) ? touchControl : null;
}
