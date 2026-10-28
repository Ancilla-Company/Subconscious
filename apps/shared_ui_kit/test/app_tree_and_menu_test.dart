import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('AppTreeRow shows a subtitle and reports a right click', (
    WidgetTester tester,
  ) async {
    Offset? clicked;
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 240,
          child: AppTreeRow(
            label: 'docs',
            subtitle: r'C:\work\docs',
            onTap: () {},
            onSecondaryTapDown: (TapDownDetails d) =>
                clicked = d.globalPosition,
          ),
        ),
      ),
    );
    expect(find.text('docs'), findsOneWidget);
    expect(find.text(r'C:\work\docs'), findsOneWidget);
    expect(tester.getSize(find.byType(SizedBox).at(1)).height, greaterThan(30));

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.text('docs')),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    expect(clicked, isNotNull);
  });

  testWidgets('showAppContextMenu returns the chosen value', (
    WidgetTester tester,
  ) async {
    String? chosen;
    late BuildContext context;
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (BuildContext c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    final Future<String?> result = showAppContextMenu<String>(
      context: context,
      position: const Offset(40, 40),
      items: const <AppMenuItem<String>>[
        AppMenuItem<String>(value: 'open', label: 'Open'),
        AppMenuItem<String>(value: 'rename', label: 'Rename'),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    chosen = await result;
    expect(chosen, 'rename');
  });

  testWidgets('AppPanelDivider reports drag start, update and end', (
    WidgetTester tester,
  ) async {
    final List<String> events = <String>[];
    await tester.pumpWidget(
      _host(
        SizedBox(
          height: 100,
          child: AppPanelDivider(
            onDragStart: (_) => events.add('start'),
            onDragUpdate: (_) => events.add('update'),
            onDragEnd: (_) => events.add('end'),
          ),
        ),
      ),
    );
    await tester.drag(find.byType(AppPanelDivider), const Offset(30, 0));
    expect(events.first, 'start');
    expect(events, contains('update'));
    expect(events.last, 'end');
  });

  testWidgets('a fixed-height AppTextField fills its height', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppFormTheme(
            child: Row(
              children: <Widget>[
                const Expanded(
                  child: AppTextField(initialValue: 'value', height: 32),
                ),
                AppIconButton(
                  icon: Icons.copy,
                  tooltip: 'Copy',
                  outlined: true,
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // The field is as tall as the 32 dp button beside it, not just its text.
    expect(tester.getSize(find.byType(TextFormField)).height, 32);
    expect(tester.getSize(find.byType(AppIconButton)).height, 32);
  });

  testWidgets('a flush AppListRow has no side padding', (
    WidgetTester tester,
  ) async {
    Future<(Rect, Rect, Rect)> measure(bool flush) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: AppListRow(
                  title: 'C:/work/project',
                  dense: true,
                  flush: flush,
                  onTap: null,
                  trailingInteractive: true,
                  trailing: AppIconButton(
                    icon: Icons.close,
                    tooltip: 'Remove',
                    outlined: true,
                    onPressed: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      return (
        tester.getRect(find.byType(AppListRow)),
        tester.getRect(find.text('C:/work/project')),
        tester.getRect(find.byType(AppIconButton)),
      );
    }

    final (Rect row, Rect title, Rect button) = await measure(true);
    expect(title.left, row.left);
    expect(button.right, row.right);

    final (Rect paddedRow, Rect paddedTitle, Rect paddedButton) = await measure(
      false,
    );
    expect(paddedTitle.left - paddedRow.left, 12);
    expect(paddedRow.right - paddedButton.right, 8);
  });

  testWidgets('AppFieldRow spaces the field like it spaces two buttons', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppFormTheme(
            child: AppFieldRow(
              field: const AppTextField(initialValue: 'value'),
              actions: <Widget>[
                AppIconButton(
                  key: const ValueKey<String>('first'),
                  icon: Icons.copy,
                  tooltip: 'Copy',
                  outlined: true,
                  onPressed: () {},
                ),
                AppIconButton(
                  key: const ValueKey<String>('second'),
                  icon: Icons.folder,
                  tooltip: 'Open',
                  outlined: true,
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final Rect field = tester.getRect(find.byType(TextFormField));
    final Rect first = tester.getRect(
      find.byKey(const ValueKey<String>('first')),
    );
    final Rect second = tester.getRect(
      find.byKey(const ValueKey<String>('second')),
    );
    expect(first.left - field.right, AppSpacing.control);
    expect(second.left - first.right, AppSpacing.control);
  });

  testWidgets('a flush row with a compact switch is as tall as its buttons', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: AppListRow(
              title: 'C:/work/project',
              dense: true,
              flush: true,
              onTap: null,
              trailingInteractive: true,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  AppSwitch(
                    compact: true,
                    value: true,
                    onChanged: (_) {},
                    semanticLabel: 'RAG',
                  ),
                  AppSpacing.controlGap,
                  AppIconButton(
                    icon: Icons.close,
                    tooltip: 'Remove',
                    outlined: true,
                    onPressed: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // No hidden padding: stacked rows are then spaced only by AppSpacing.row.
    expect(tester.getSize(find.byType(AppListRow)).height, 32);
  });
}
