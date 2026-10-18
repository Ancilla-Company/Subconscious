import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/settings/presentation/settings_main_panel.dart';

void main() {
  for (final Brightness brightness in Brightness.values) {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.windows,
    ]) {
      testWidgets('form controls use the app template on ${platform.name} '
          '(${brightness.name})', (WidgetTester tester) async {
        late ThemeData form;
        late ThemeData base;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness, platform: platform),
            home: Builder(
              builder: (BuildContext context) {
                base = Theme.of(context);
                form = settingsFormTheme(context);
                return const SizedBox();
              },
            ),
          ),
        );
        // Flat 3px buttons and filled, outlined inputs, colored from the scheme.
        expect(form.visualDensity, VisualDensity.compact);
        expect(form.inputDecorationTheme.filled, isTrue);
        expect(
          form.inputDecorationTheme.fillColor,
          base.colorScheme.surfaceContainerLowest,
        );
        final OutlinedBorder? shape = form.filledButtonTheme.style?.shape
            ?.resolve(<WidgetState>{});
        expect(
          (shape! as RoundedRectangleBorder).borderRadius,
          const BorderRadius.all(Radius.circular(3)),
        );
      }, variant: TargetPlatformVariant.only(platform));
    }
  }

  testWidgets('web-like desktops keep the stock theme', (
    WidgetTester tester,
  ) async {
    late ThemeData form;
    late ThemeData base;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: Builder(
          builder: (BuildContext context) {
            base = Theme.of(context);
            form = settingsFormTheme(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(form.inputDecorationTheme, base.inputDecorationTheme);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
