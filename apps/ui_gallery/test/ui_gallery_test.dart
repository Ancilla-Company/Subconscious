import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import 'package:ui_gallery/main.dart';

void main() {
  testWidgets('the gallery builds every kit component in every theme', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const UiGalleryApp());
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      find.text('Notification toast preview. Use the buttons below to compare variants.'),
      findsOneWidget,
    );

    // Samples are labelled with the component's name.
    expect(find.text('AppTextField: label and hint'), findsOneWidget);
    expect(find.byType(AppTextField), findsWidgets);
    expect(find.byType(AppSearchField), findsWidgets);
    expect(find.byType(AppSwitchTile), findsWidgets);
    expect(find.byType(AppIconButton), findsWidgets);
    expect(find.byType(AppListRow), findsWidgets);
    expect(find.text('Dropdowns and pickers'), findsOneWidget);
    expect(find.byType(AppPickerButton<String>), findsNWidgets(2));

    for (final String variant in <String>[
      'Dark',
      'Neutral light',
      'Neutral dark',
    ]) {
      await tester.tap(
        find.descendant(of: find.byType(AppBar), matching: find.text(variant)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: variant);
    }
  });
}
