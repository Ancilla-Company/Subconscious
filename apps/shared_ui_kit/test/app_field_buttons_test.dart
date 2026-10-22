import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

Widget _app(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: AppFormTheme(child: Center(child: child)),
      ),
    );

void main() {
  for (final Brightness brightness in Brightness.values) {
    group('in ${brightness.name} mode', () {
      testWidgets(
        'an outlined AppIconButton matches the field fill and border',
        (tester) async {
          await tester.pumpWidget(
            _app(
              AppIconButton(
                outlined: true,
                icon: Icons.copy,
                tooltip: 'Copy',
                onPressed: () {},
              ),
              brightness: brightness,
            ),
          );
          final ColorScheme colors = Theme.of(
            tester.element(find.byType(AppIconButton)),
          ).colorScheme;
          final IconButton button = tester.widget(find.byType(IconButton));
          final ButtonStyle style = button.style!;
          expect(
            style.backgroundColor!.resolve(<WidgetState>{}),
            colors.surfaceContainerLowest,
          );
          expect(
            style.side!.resolve(<WidgetState>{}),
            BorderSide(color: colors.outlineVariant),
          );
        },
      );

      testWidgets('a plain AppIconButton stays flat', (tester) async {
        await tester.pumpWidget(
          _app(
            AppIconButton(icon: Icons.copy, tooltip: 'Copy', onPressed: () {}),
            brightness: brightness,
          ),
        );
        final IconButton button = tester.widget(find.byType(IconButton));
        expect(button.style!.side, isNull);
        expect(button.style!.backgroundColor?.resolve(<WidgetState>{}), isNull);
      });

      testWidgets('an expansion AppSectionCard has no border', (tester) async {
        await tester.pumpWidget(
          _app(
            AppSectionCard(
              title: 'Models',
              expandable: true,
              child: const Text('body'),
            ),
            brightness: brightness,
          ),
        );
        final Card card = tester.widget(find.byType(Card));
        expect(card.shape, isA<RoundedRectangleBorder>());
        expect((card.shape! as RoundedRectangleBorder).side, BorderSide.none);
      });

      testWidgets('a plain AppSectionCard keeps the kit border', (
        tester,
      ) async {
        await tester.pumpWidget(
          _app(
            AppSectionCard(title: 'Info', child: const Text('body')),
            brightness: brightness,
          ),
        );
        final Card card = tester.widget(find.byType(Card));
        expect(card.shape, isNull);
      });
    });
  }

  testWidgets('a dense AppListRow is as tall as a 32dp sidebar button', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 240,
          child: AppListRow(title: 'Thread', dense: true, onTap: () {}),
        ),
      ),
    );
    expect(tester.getSize(find.byType(AppListRow)).height, 32);
  });

  testWidgets('titleBold sets the title in bold', (tester) async {
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 240,
          child: AppListRow(
            title: 'Personal',
            subtitle: 'My notes',
            titleBold: true,
            onTap: () {},
          ),
        ),
      ),
    );
    expect(
      tester.widget<Text>(find.text('Personal')).style!.fontWeight,
      FontWeight.bold,
    );
    expect(
      tester.widget<Text>(find.text('My notes')).style!.fontWeight,
      isNot(FontWeight.bold),
    );
  });
}
