import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';
import 'package:unified_app/features/editor/presentation/find_bar.dart';
import 'package:unified_app/features/editor/presentation/find_model.dart';

void main() {
  testWidgets('the find box is a kit field as tall as the buttons beside it', (
    WidgetTester tester,
  ) async {
    final FindModel model = FindModel();
    addTearDown(model.dispose);
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: EditorFindBar(
              model: model,
              queryFocus: focus,
              textProvider: () => 'a model of a model',
              anchorProvider: () => 0,
              onJump: (_) {},
              onReplace: () {},
              onReplaceAll: () {},
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    final Finder field = find.byType(AppTextField).first;
    expect(field, findsOneWidget);
    // Same height as the 32 dp icon buttons, not the content height of a bare
    // TextField.
    expect(tester.getSize(field).height, 32);
    expect(
      tester.getSize(find.byType(AppIconButton).first).height,
      tester.getSize(field).height,
    );
    final InputDecorator decorator = tester.widget<InputDecorator>(
      find.descendant(of: field, matching: find.byType(InputDecorator)),
    );
    expect(decorator.decoration.enabledBorder, isA<OutlineInputBorder>());

    // Typing searches, and the field keeps focus.
    await tester.enterText(find.descendant(of: field, matching: find.byType(EditableText)), 'model');
    await tester.pump();
    expect(model.query, 'model');
    expect(find.text('1 of 2'), findsOneWidget);
  });
}
