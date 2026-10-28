import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Puts the test view on a display of [logical] size, the way a real phone
/// would report it: the window and the display it is shown on both change.
///
/// Control sizes are read from the display, not the window, so a test that
/// stands in for a handset must change the display too.
void useScreen(WidgetTester tester, Size logical, {double ratio = 3}) {
  tester.view.devicePixelRatio = ratio;
  tester.view.physicalSize = logical * ratio;
  tester.view.display.devicePixelRatio = ratio;
  tester.view.display.size = logical * ratio;
  addTearDown(tester.view.reset);
  addTearDown(tester.view.display.reset);
}
