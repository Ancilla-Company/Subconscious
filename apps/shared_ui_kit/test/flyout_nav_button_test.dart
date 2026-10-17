import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

void main() {
  for (final Brightness brightness in Brightness.values) {
    testWidgets('FlyoutNavButton selected state (${brightness.name})', (
      WidgetTester tester,
    ) async {
      int taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
            body: Column(
              children: <Widget>[
                FlyoutNavButton(
                  icon: Icons.chat_outlined,
                  selectedIcon: Icons.chat,
                  label: 'Threads',
                  selected: true,
                  onPressed: () => taps++,
                ),
                FlyoutNavButton(
                  icon: Icons.folder_outlined,
                  selectedIcon: Icons.folder,
                  label: 'Files',
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ),
      );
      final ColorScheme colors = Theme.of(tester.element(find.text('Threads')))
          .colorScheme;
      Color? fill(String label) => tester
          .widget<Material>(
            find
                .descendant(
                  of: find.ancestor(
                    of: find.text(label),
                    matching: find.byType(FlyoutNavButton),
                  ),
                  matching: find.byType(Material),
                )
                .first,
          )
          .color;
      expect(fill('Threads'), colors.secondaryContainer);
      expect(fill('Files'), Colors.transparent);
      await tester.tap(find.text('Threads'));
      expect(taps, 1);
    });
  }
}
