import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

Future<void> _open(WidgetTester tester, {bool destructive = false}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showAppConfirmDialog(
              context: context,
              title: 'Delete notes.md?',
              message: 'This cannot be undone.',
              confirmLabel: 'Delete',
              destructive: destructive,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the title, message and both buttons', (
    WidgetTester tester,
  ) async {
    await _open(tester);
    expect(find.text('Delete notes.md?'), findsOneWidget);
    expect(find.text('This cannot be undone.'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Delete'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.byType(AppConfirmDialog), findsNothing);
  });

  testWidgets('cancel and a tap outside return false', (
    WidgetTester tester,
  ) async {
    bool? popped;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async => popped = await showAppConfirmDialog(
                context: context,
                title: 'Delete?',
                message: 'Gone for good.',
                confirmLabel: 'Delete',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(popped, isFalse);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(popped, isFalse);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(popped, isTrue);
  });

  testWidgets('destructive paints the confirm button in the error colours', (
    WidgetTester tester,
  ) async {
    await _open(tester, destructive: true);
    final FilledButton button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Delete'),
    );
    final ColorScheme colors = Theme.of(
      tester.element(find.byType(AppConfirmDialog)),
    ).colorScheme;
    expect(
      button.style?.backgroundColor?.resolve(<WidgetState>{}),
      colors.error,
    );
    expect(
      button.style?.foregroundColor?.resolve(<WidgetState>{}),
      colors.onError,
    );
  });
}
