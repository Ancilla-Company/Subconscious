import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

Widget _host({required double homeIndicator, required double keyboard}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(390, 844),
          padding: EdgeInsets.only(top: 47, bottom: homeIndicator),
          viewPadding: EdgeInsets.only(top: 47, bottom: homeIndicator),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: const Material(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: AppBottomSheet(title: 'Run on', child: Text('content')),
          ),
        ),
      ),
    );

void main() {
  testWidgets('AppBottomSheet clears the iOS home indicator', (tester) async {
    await tester.pumpWidget(_host(homeIndicator: 34, keyboard: 0));
    final double bottom = tester.getBottomLeft(find.byType(AppBottomSheet)).dy;
    final double content = tester.getBottomLeft(find.text('content')).dy;
    // 16 own padding + 34 home indicator below the last line.
    expect(bottom - content, greaterThanOrEqualTo(34 + 16));
  });

  testWidgets('AppBottomSheet sits on the keyboard without a double gap', (
    tester,
  ) async {
    await tester.pumpWidget(_host(homeIndicator: 34, keyboard: 300));
    await tester.pumpAndSettle();
    final double content = tester.getBottomLeft(find.text('content')).dy;
    // Lifted by the keyboard: only the sheet's own 16 below the content,
    // not another 34 of home-indicator padding above the keys.
    expect(
      tester.getBottomLeft(find.byType(AppBottomSheet)).dy - 300 - content,
      lessThan(34 + 16),
    );
    expect(
      tester.getBottomLeft(find.byType(AppBottomSheet)).dy - 300 - content,
      greaterThanOrEqualTo(16),
    );
  });
}
