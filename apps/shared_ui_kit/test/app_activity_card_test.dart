import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(
    body: AppFormTheme(child: Center(child: child)),
  ),
);

void main() {
  group('AppActivityCard', () {
    testWidgets('is collapsed by default and opens its details on tap', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const AppActivityCard(
            title: 'read note: todo.md',
            state: AppActivityState.success,
            meta: '120 ms',
            badges: <Widget>[AppBadge('Approved')],
            child: AppActivitySection(label: 'Output', text: 'buy milk'),
          ),
        ),
      );
      expect(find.text('read note: todo.md'), findsOneWidget);
      expect(find.text('Approved'), findsOneWidget);
      expect(find.text('120 ms'), findsOneWidget);
      expect(find.text('buy milk'), findsNothing);

      await tester.tap(find.text('read note: todo.md'));
      await tester.pumpAndSettle();
      expect(find.text('Output'), findsOneWidget);
      expect(find.text('buy milk'), findsOneWidget);

      await tester.tap(find.text('read note: todo.md'));
      await tester.pumpAndSettle();
      expect(find.text('buy milk'), findsNothing);
    });

    testWidgets('initiallyExpanded shows the details at once', (tester) async {
      await tester.pumpWidget(
        _app(
          const AppActivityCard(
            title: 'ask helper',
            state: AppActivityState.waiting,
            initiallyExpanded: true,
            child: Text('details'),
          ),
        ),
      );
      expect(find.text('details'), findsOneWidget);
    });

    testWidgets('without details it is a plain line with no chevron', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const AppActivityCard(
            title: 'list todos',
            state: AppActivityState.failure,
            subtitle: 'denied',
          ),
        ),
      );
      expect(find.text('denied'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsNothing);
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('each state has its own icon, and running shows a spinner', (
      tester,
    ) async {
      Future<void> show(AppActivityState state) => tester.pumpWidget(
        _app(AppActivityCard(title: 't', state: state)),
      );
      await show(AppActivityState.waiting);
      expect(find.byIcon(Icons.pending_outlined), findsOneWidget);
      await show(AppActivityState.running);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await show(AppActivityState.success);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      await show(AppActivityState.failure);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      await show(AppActivityState.stopped);
      expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
    });

    testWidgets('semantics name the title, state and open state', (
      tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          const AppActivityCard(
            title: 'delete note',
            state: AppActivityState.waiting,
            stateLabel: 'Waiting for approval',
            child: Text('details'),
          ),
        ),
      );
      expect(
        find.bySemanticsLabel('delete note, Waiting for approval'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });
}
