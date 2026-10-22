import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Corner radii shared by every kit and app surface. Feature code uses these
/// instead of `BorderRadius.circular(...)` literals.
abstract final class AppRadii {
  /// Buttons, fields, cards, banners, bubbles: the default 3px corner.
  static const BorderRadius xs = BorderRadius.all(Radius.circular(3));

  /// Compact toolbar and sidebar buttons.
  static const BorderRadius sm = BorderRadius.all(Radius.circular(4));

  /// Rows, tabs, toolbars, grouped surfaces.
  static const BorderRadius md = BorderRadius.all(Radius.circular(6));

  /// Floating panels such as the find bar.
  static const BorderRadius lg = BorderRadius.all(Radius.circular(8));

  /// Corner radius for larger surfaces (avatar, dialogs), following each
  /// platform's design language: Fluent uses 8 for cards and overlays,
  /// Material 3 and Apple platforms use a larger radius.
  static BorderRadius surfaceFor(TargetPlatform platform) =>
      BorderRadius.circular(switch (platform) {
        TargetPlatform.windows => 8,
        TargetPlatform.linux => 6,
        TargetPlatform.macOS || TargetPlatform.iOS => 12,
        TargetPlatform.android || TargetPlatform.fuchsia => 12,
      });
}
