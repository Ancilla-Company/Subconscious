import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';
import 'package:unified_app/features/editor/presentation/file_tab_button.dart';

void main() {
  testWidgets(
    'the close button sits inside the tab with room above and below',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: FileTabButton(
                label: 'features.md',
                selected: true,
                dirty: false,
                onTap: () {},
                onClose: () {},
              ),
            ),
          ),
        ),
      );

      final Rect tab = tester.getRect(find.byType(FileTabButton));
      final Rect close = tester.getRect(find.byType(AppIconButton));

      expect(close.height, lessThan(tab.height));
      // Equal, visible gaps above and below, and the same gap on the right.
      expect(close.top - tab.top, greaterThanOrEqualTo(4));
      expect(tab.bottom - close.bottom, closeTo(close.top - tab.top, 0.5));
      expect(tab.right - close.right, closeTo(close.top - tab.top, 1));
    },
  );
}
