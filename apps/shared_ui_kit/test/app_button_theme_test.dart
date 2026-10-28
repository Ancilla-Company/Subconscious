import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

void main() {
  for (final Brightness brightness in Brightness.values) {
    testWidgets(
      'a button outside any form is still a kit button (${brightness.name})',
      (WidgetTester tester) async {
        final ThemeData theme = brightness == Brightness.light
            ? AppTheme.light()
            : AppTheme.dark();
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            // No AppFormTheme anywhere: the root theme alone must style them.
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  FilledButton(onPressed: () {}, child: const Text('Filled')),
                  OutlinedButton(onPressed: () {}, child: const Text('Outl')),
                  TextButton(onPressed: () {}, child: const Text('Text')),
                ],
              ),
            ),
          ),
        );
        for (final Finder finder in <Finder>[
          find.byType(FilledButton),
          find.byType(OutlinedButton),
          find.byType(TextButton),
        ]) {
          final ButtonStyleButton button = tester.widget(finder);
          final ButtonStyle style = button.themeStyleOf(
            tester.element(finder),
          )!;
          final OutlinedBorder? shape = style.shape?.resolve(<WidgetState>{});
          expect(
            (shape! as RoundedRectangleBorder).borderRadius,
            AppRadii.xs,
            reason: '${finder.description} must have the kit corner',
          );
        }
      },
    );
  }

  testWidgets('AppIconButton picks its glyph size from its kind', (
    WidgetTester tester,
  ) async {
    Future<double> glyphOf(bool outlined, {double? iconSize}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppIconButton(
              icon: Icons.copy,
              tooltip: 'Copy',
              outlined: outlined,
              iconSize: iconSize,
              onPressed: () {},
            ),
          ),
        ),
      );
      return tester.widget<Icon>(find.byIcon(Icons.copy)).size!;
    }

    expect(await glyphOf(true), 17);
    expect(await glyphOf(false), 20);
    expect(await glyphOf(true, iconSize: 14), 14);
  });
}
