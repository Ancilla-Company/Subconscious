import 'package:flutter/painting.dart';

/// The one corner radius of the app: 3 px, on every component (buttons,
/// fields, cards, rows, menus, dialogs, sheets, switches, badges, bubbles).
/// Feature code uses this instead of `BorderRadius.circular(...)` literals.
abstract final class AppRadii {
  /// The radius in logical pixels.
  static const double value = 3;

  /// The standard corner: [value] on all four corners.
  static const BorderRadius standard = BorderRadius.all(Radius.circular(value));
}
