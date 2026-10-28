import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

void main() {
  test('only a small display grows a control, whatever the platform', () {
    // Handsets.
    expect(AppDensity.controlSizeFor(const Size(360, 800)), 48);
    expect(AppDensity.controlSizeFor(const Size(800, 360)), 48);
    expect(AppDensity.controlSizeFor(const Size(599, 1200)), 48);
    // Tablets, laptops and monitors.
    expect(AppDensity.controlSizeFor(const Size(600, 960)), 32);
    expect(AppDensity.controlSizeFor(const Size(1366, 768)), 32);
    expect(AppDensity.controlSizeFor(const Size(3840, 2160)), 32);
  });

  testWidgets('the size is read from the display, not the window', (
    WidgetTester tester,
  ) async {
    late BuildContext captured;
    Future<void> pump() => tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            captured = context;
            return const SizedBox();
          },
        ),
      ),
    );

    // A narrow window (400 dp) on a 1920x1080 display.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 700);
    tester.view.display.size = const Size(1920, 1080);
    addTearDown(tester.view.reset);
    addTearDown(tester.view.display.reset);
    await pump();
    expect(AppDensity.displaySize(captured), const Size(1920, 1080));
    expect(AppDensity.controlSize(captured), AppDensity.control);
    expect(AppDensity.minTouchTarget(captured), isNull);

    // The same window on a phone-sized display.
    tester.view.display.size = const Size(400, 700);
    await pump();
    expect(AppDensity.controlSize(captured), AppDensity.touchControl);
    expect(AppDensity.minTouchTarget(captured), AppDensity.touchControl);
  });
}
