import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

Future<(ThemeData, ThemeData)> _themes(
  WidgetTester tester,
  Brightness brightness,
) async {
  late ThemeData base;
  late ThemeData form;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Builder(
        builder: (BuildContext context) {
          base = Theme.of(context);
          form = appFormTheme(context);
          return const SizedBox();
        },
      ),
    ),
  );
  return (base, form);
}

void main() {
  const BorderRadius radius = BorderRadius.all(Radius.circular(3));

  for (final Brightness brightness in Brightness.values) {
    group('component themes (${brightness.name})', () {
      testWidgets('dialog is flat, 3px, bordered, no tint', (tester) async {
        final (ThemeData base, ThemeData form) = await _themes(
          tester,
          brightness,
        );
        final DialogThemeData d = form.dialogTheme;
        expect(d.elevation, 0);
        expect(d.surfaceTintColor, Colors.transparent);
        expect(d.backgroundColor, base.colorScheme.surface);
        final RoundedRectangleBorder shape = d.shape! as RoundedRectangleBorder;
        expect(shape.borderRadius, radius);
        expect(shape.side.color, base.colorScheme.outlineVariant);
      });

      testWidgets('card is flat, 3px, bordered', (tester) async {
        final (ThemeData base, ThemeData form) = await _themes(
          tester,
          brightness,
        );
        final CardThemeData c = form.cardTheme;
        expect(c.elevation, 0);
        expect(c.surfaceTintColor, Colors.transparent);
        expect(c.color, base.colorScheme.surfaceContainerLowest);
        final RoundedRectangleBorder shape = c.shape! as RoundedRectangleBorder;
        expect(shape.borderRadius, radius);
        expect(shape.side.color, base.colorScheme.outlineVariant);
      });

      testWidgets('list tile, expansion tile and divider', (tester) async {
        final (ThemeData base, ThemeData form) = await _themes(
          tester,
          brightness,
        );
        expect(form.listTileTheme.dense, isTrue);
        expect(
          (form.listTileTheme.shape! as RoundedRectangleBorder).borderRadius,
          radius,
        );
        expect(form.expansionTileTheme.shape, isA<Border>());
        expect(form.expansionTileTheme.collapsedShape, isA<Border>());
        expect(form.dividerTheme.color, base.colorScheme.outlineVariant);
        expect(form.dividerTheme.space, 1);
      });

      testWidgets('chip is flat, 3px, bordered', (tester) async {
        final (ThemeData base, ThemeData form) = await _themes(
          tester,
          brightness,
        );
        final ChipThemeData c = form.chipTheme;
        expect(c.elevation, 0);
        expect(c.backgroundColor, base.colorScheme.surfaceContainerLowest);
        final RoundedRectangleBorder shape = c.shape! as RoundedRectangleBorder;
        expect(shape.borderRadius, radius);
        expect(shape.side.color, base.colorScheme.outlineVariant);
      });

      testWidgets('popup menu and menu anchor', (tester) async {
        final (ThemeData base, ThemeData form) = await _themes(
          tester,
          brightness,
        );
        expect(form.popupMenuTheme.surfaceTintColor, Colors.transparent);
        expect(
          (form.popupMenuTheme.shape! as RoundedRectangleBorder).borderRadius,
          const BorderRadius.all(Radius.circular(3)),
        );
        expect(
          form.popupMenuTheme.color,
          base.colorScheme.surfaceContainerHigh,
        );
        final MenuStyle menu = form.menuTheme.style!;
        expect(
          menu.backgroundColor!.resolve(<WidgetState>{}),
          base.colorScheme.surfaceContainerLowest,
        );
        expect(
          (menu.shape!.resolve(<WidgetState>{})! as RoundedRectangleBorder)
              .borderRadius,
          radius,
        );
      });

      testWidgets('bottom sheet is flat with a top border', (tester) async {
        final (ThemeData base, ThemeData form) = await _themes(
          tester,
          brightness,
        );
        final BottomSheetThemeData s = form.bottomSheetTheme;
        expect(s.elevation, 0);
        expect(s.modalElevation, 0);
        expect(s.surfaceTintColor, Colors.transparent);
        expect(s.modalBackgroundColor, base.colorScheme.surface);
        expect(
          (s.shape! as RoundedRectangleBorder).side.color,
          base.colorScheme.outlineVariant,
        );
      });

      testWidgets('segmented button is 3px with an outlineVariant border', (
        tester,
      ) async {
        final (ThemeData base, ThemeData form) = await _themes(
          tester,
          brightness,
        );
        final ButtonStyle s = form.segmentedButtonTheme.style!;
        expect(
          (s.shape!.resolve(<WidgetState>{})! as RoundedRectangleBorder)
              .borderRadius,
          radius,
        );
        expect(
          s.side!.resolve(<WidgetState>{})!.color,
          base.colorScheme.outlineVariant,
        );
      });

      testWidgets('snack bar, switch, tooltip, app bar', (tester) async {
        final (ThemeData base, ThemeData form) = await _themes(
          tester,
          brightness,
        );
        expect(form.snackBarTheme.behavior, SnackBarBehavior.floating);
        expect(form.snackBarTheme.elevation, 0);
        expect(
          form.snackBarTheme.backgroundColor,
          base.colorScheme.inverseSurface,
        );
        expect(
          form.switchTheme.trackOutlineColor!.resolve(<WidgetState>{}),
          base.colorScheme.outlineVariant,
        );
        expect(
          (form.tooltipTheme.decoration! as BoxDecoration).borderRadius,
          radius,
        );
        expect(form.appBarTheme.elevation, 0);
        expect(form.appBarTheme.scrolledUnderElevation, 0);
        expect(form.appBarTheme.surfaceTintColor, Colors.transparent);
        expect(form.appBarTheme.backgroundColor, base.colorScheme.surface);
        expect(
          (form.appBarTheme.shape! as Border).bottom.color,
          base.colorScheme.outlineVariant,
        );
      });

      testWidgets('input decoration covers disabled and error borders', (
        tester,
      ) async {
        final (ThemeData base, ThemeData form) = await _themes(
          tester,
          brightness,
        );
        final i = form.inputDecorationTheme;
        for (final InputBorder? b in <InputBorder?>[
          i.disabledBorder,
          i.errorBorder,
          i.focusedErrorBorder,
        ]) {
          expect((b! as OutlineInputBorder).borderRadius, radius);
        }
        expect(
          i.disabledBorder!.borderSide.color,
          base.colorScheme.outlineVariant.withValues(alpha: 0.5),
        );
      });
    });
  }

  testWidgets('a Card inside AppFormTheme renders with the kit shape', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: AppFormTheme(child: Card(child: Text('x'))),
      ),
    );
    final Material material = tester.widget<Material>(
      find.descendant(of: find.byType(Card), matching: find.byType(Material)),
    );
    expect(material.elevation, 0);
    expect((material.shape! as RoundedRectangleBorder).borderRadius, radius);
  });
}
