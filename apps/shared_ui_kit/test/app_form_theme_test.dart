import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

void main() {
  for (final Brightness brightness in Brightness.values) {
    for (final TargetPlatform platform in TargetPlatform.values) {
      testWidgets('form theme on ${platform.name} (${brightness.name})', (
        WidgetTester tester,
      ) async {
        late ThemeData form;
        late ThemeData base;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness, platform: platform),
            home: Builder(
              builder: (BuildContext context) {
                base = Theme.of(context);
                form = appFormTheme(context);
                return const SizedBox();
              },
            ),
          ),
        );
        expect(form.visualDensity, VisualDensity.compact);
        expect(form.inputDecorationTheme.filled, isTrue);
        expect(
          form.inputDecorationTheme.fillColor,
          base.colorScheme.surfaceContainerLowest,
        );
        const BorderRadius radius = BorderRadius.all(Radius.circular(3));
        for (final InputBorder? border in <InputBorder?>[
          form.inputDecorationTheme.border,
          form.inputDecorationTheme.enabledBorder,
          form.inputDecorationTheme.focusedBorder,
        ]) {
          expect((border! as OutlineInputBorder).borderRadius, radius);
        }
        for (final ButtonStyle? style in <ButtonStyle?>[
          form.filledButtonTheme.style,
          form.outlinedButtonTheme.style,
          form.textButtonTheme.style,
          form.iconButtonTheme.style,
        ]) {
          final OutlinedBorder? shape = style?.shape?.resolve(<WidgetState>{});
          expect((shape! as RoundedRectangleBorder).borderRadius, radius);
        }
      }, variant: TargetPlatformVariant.only(platform));
    }
  }

  testWidgets('AppFormTheme applies appFormTheme to its child', (
    WidgetTester tester,
  ) async {
    late ThemeData inner;
    await tester.pumpWidget(
      MaterialApp(
        home: AppFormTheme(
          child: Builder(
            builder: (BuildContext context) {
              inner = Theme.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(inner.visualDensity, VisualDensity.compact);
    expect(inner.inputDecorationTheme.filled, isTrue);
  });
}
