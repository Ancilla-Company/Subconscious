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
  group('AppPanelDivider', () {
    testWidgets('is 5px wide and reports horizontal drags', (tester) async {
      final List<double> deltas = <double>[];
      await tester.pumpWidget(
        _app(
          SizedBox(
            height: 100,
            child: AppPanelDivider(
              onDragUpdate: (DragUpdateDetails d) => deltas.add(d.delta.dx),
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(AppPanelDivider)).width, 5);
      await tester.drag(find.byType(AppPanelDivider), const Offset(20, 0));
      expect(deltas, isNotEmpty);
      expect(deltas.reduce((double a, double b) => a + b), greaterThan(0));
    });

    testWidgets('without a callback it is a plain rule', (tester) async {
      await tester.pumpWidget(
        _app(const SizedBox(height: 100, child: AppPanelDivider())),
      );
      expect(find.byType(GestureDetector), findsNothing);
    });
  });

  group('AppToolbar', () {
    testWidgets('wraps icon buttons and dividers', (tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 90,
            child: AppToolbar(
              children: <Widget>[
                AppIconButton(
                  icon: Icons.add,
                  tooltip: 'Add',
                  onPressed: () => taps++,
                ),
                const AppToolbarDivider(),
                AppIconButton(
                  icon: Icons.remove,
                  tooltip: 'Remove',
                  onPressed: () {},
                ),
                AppIconButton(
                  icon: Icons.close,
                  tooltip: 'Close',
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Add'));
      expect(taps, 1);
    });

    testWidgets('AppTextToggle reports taps and selection', (tester) async {
      bool selected = false;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) =>
                AppTextToggle(
                  label: 'Aa',
                  tooltip: 'Match case',
                  selected: selected,
                  onPressed: () => setState(() => selected = !selected),
                ),
          ),
        ),
      );
      await tester.tap(find.byType(AppTextToggle));
      await tester.pump();
      expect(selected, isTrue);
      expect(find.bySemanticsLabel('Match case'), findsOneWidget);
    });
  });

  group('SidebarButton badge', () {
    testWidgets('shows the attention dot only when asked', (tester) async {
      Future<void> pump({required bool badge}) => tester.pumpWidget(
        _app(
          SidebarButton(
            icon: Icons.chat_bubble_outline,
            selectedIcon: Icons.chat_bubble,
            tooltip: 'Threads',
            badge: badge,
            onPressed: () {},
          ),
        ),
      );
      await pump(badge: false);
      expect(find.bySemanticsLabel('Needs attention'), findsNothing);
      await pump(badge: true);
      expect(find.bySemanticsLabel('Needs attention'), findsOneWidget);
    });

    testWidgets('disabled when onPressed is null', (tester) async {
      await tester.pumpWidget(
        _app(
          const SidebarButton(
            icon: Icons.settings_outlined,
            selectedIcon: Icons.settings,
            tooltip: 'Settings',
            onPressed: null,
          ),
        ),
      );
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNull,
      );
    });
  });

  group('AppSwitch', () {
    testWidgets('toggles by tap and exposes its label', (tester) async {
      bool? value;
      await tester.pumpWidget(
        _app(
          AppSwitch(
            value: false,
            onChanged: (bool v) => value = v,
            semanticLabel: 'Enable tools',
          ),
        ),
      );
      expect(find.bySemanticsLabel('Enable tools'), findsOneWidget);
      await tester.tap(find.byType(AppSwitch));
      expect(value, isTrue);
    });

    testWidgets('is inert when disabled', (tester) async {
      await tester.pumpWidget(
        _app(
          const AppSwitch(
            value: true,
            onChanged: null,
            semanticLabel: 'Enable tools',
          ),
        ),
      );
      await tester.tap(find.byType(AppSwitch));
      expect(tester.takeException(), isNull);
    });
  });

  group('AppBadge', () {
    testWidgets('removable badge calls onDeleted and names the action', (
      tester,
    ) async {
      int removed = 0;
      await tester.pumpWidget(
        _app(
          AppBadge(
            'notes.md',
            icon: Icons.attach_file,
            deleteTooltip: 'Remove notes.md',
            onDeleted: () => removed++,
          ),
        ),
      );
      expect(find.text('notes.md'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      expect(removed, 1);
      expect(find.bySemanticsLabel('Remove notes.md'), findsOneWidget);
    });

    testWidgets('long labels shrink to maxWidth without overflow', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(AppBadge('x' * 200, maxWidth: 100, icon: Icons.edit)),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(AppBadge)).width, lessThan(160));
    });
  });

  group('AppIconButton extras', () {
    testWidgets('busy swaps the icon for a spinner', (tester) async {
      await tester.pumpWidget(
        _app(
          AppIconButton(
            icon: Icons.save,
            tooltip: 'Save',
            busy: true,
            onPressed: () {},
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.save), findsNothing);
    });

    testWidgets('destructive tints the icon with the error colour', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          AppIconButton(
            icon: Icons.delete,
            tooltip: 'Delete',
            destructive: true,
            onPressed: () {},
          ),
        ),
      );
      final ButtonStyle style = tester
          .widget<IconButton>(find.byType(IconButton))
          .style!;
      final Color error = Theme.of(tester.element(find.byType(IconButton)))
          .colorScheme
          .error;
      expect(style.foregroundColor!.resolve(<WidgetState>{}), error);
    });

    testWidgets('minTouchTarget grows the tappable box', (tester) async {
      await tester.pumpWidget(
        _app(
          AppIconButton(
            icon: Icons.add,
            tooltip: 'Add',
            minTouchTarget: 48,
            onPressed: () {},
          ),
        ),
      );
      expect(tester.getSize(find.byType(AppIconButton)), const Size(48, 48));
    });
  });

  group('AppPopupMenu extras', () {
    testWidgets('checked items with subtitles render a tick', (tester) async {
      String? chosen;
      await tester.pumpWidget(
        _app(
          AppPopupMenu<String>(
            icon: Icons.laptop,
            items: const <AppMenuItem<String>>[
              AppMenuItem<String>(
                value: 'a',
                label: 'Laptop',
                subtitle: 'Windows · LAN',
                checked: true,
              ),
              AppMenuItem<String>(value: 'b', label: 'Phone', checked: false),
            ],
            onSelected: (String v) => chosen = v,
          ),
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('Windows · LAN'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
      await tester.tap(find.text('Phone'));
      await tester.pumpAndSettle();
      expect(chosen, 'b');
    });

    testWidgets('below sheetBreakpoint it opens an AppBottomSheet', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      String? chosen;
      await tester.pumpWidget(
        _app(
          AppPopupMenu<String>(
            tooltip: 'Run on',
            sheetBreakpoint: 600,
            items: const <AppMenuItem<String>>[
              AppMenuItem<String>(value: 'a', label: 'Laptop', checked: true),
              AppMenuItem<String>(value: 'b', label: 'Phone', checked: false),
            ],
            onSelected: (String v) => chosen = v,
          ),
        ),
      );
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      await tester.tap(find.byTooltip('Run on'));
      await tester.pumpAndSettle();
      expect(find.byType(AppBottomSheet), findsOneWidget);
      // Rows are touch sized.
      expect(
        tester.getSize(find.widgetWithText(AppListRow, 'Phone')).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.text('Phone'));
      await tester.pumpAndSettle();
      expect(chosen, 'b');
      expect(find.byType(AppBottomSheet), findsNothing);
    });

    testWidgets('at or above the breakpoint it stays a floating menu', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          AppPopupMenu<String>(
            sheetBreakpoint: 600,
            items: const <AppMenuItem<String>>[
              AppMenuItem<String>(value: 'a', label: 'Laptop'),
            ],
            onSelected: (String v) {},
          ),
        ),
      );
      expect(find.byType(PopupMenuButton<String>), findsOneWidget);
    });
  });

  group('AppSectionCard controlled', () {
    testWidgets('follows expanded and calls onToggle; trailing keeps taps', (
      tester,
    ) async {
      bool expanded = false;
      bool? switched;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) =>
                AppSectionCard(
                  title: 'Section',
                  subtitle: 'Sub',
                  expanded: expanded,
                  onToggle: () => setState(() => expanded = !expanded),
                  trailing: AppSwitch(
                    value: false,
                    onChanged: (bool v) => switched = v,
                    semanticLabel: 'Enable section',
                  ),
                  child: const Text('body'),
                ),
          ),
        ),
      );
      expect(find.text('Sub'), findsOneWidget);
      expect(find.text('body'), findsNothing);
      await tester.tap(find.text('Section'));
      await tester.pumpAndSettle();
      expect(find.text('body'), findsOneWidget);
      // The switch is outside the tappable title: it toggles itself only.
      await tester.tap(find.byType(AppSwitch));
      await tester.pumpAndSettle();
      expect(switched, isTrue);
      expect(expanded, isTrue);
      expect(find.bySemanticsLabel('Enable section'), findsOneWidget);
    });
  });

  group('AppListRow trailingInteractive', () {
    testWidgets('keeps the trailing switch reachable and the row tappable', (
      tester,
    ) async {
      int rowTaps = 0;
      bool? switched;
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 320,
            child: AppListRow(
              title: 'Tool',
              subtitle: 'does things',
              minHeight: 48,
              trailingInteractive: true,
              onTap: () => rowTaps++,
              trailing: AppSwitch(
                value: false,
                onChanged: (bool v) => switched = v,
                semanticLabel: 'Enable Tool',
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Tool'));
      expect(rowTaps, 1);
      await tester.tap(find.byType(AppSwitch));
      expect(switched, isTrue);
      expect(rowTaps, 1);
      expect(find.bySemanticsLabel('Enable Tool'), findsOneWidget);
    });
  });

  group('AppBanner extras', () {
    testWidgets('preface, content and a truncated message at 300dp', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 300,
            child: AppBanner(
              tone: AppBannerTone.warning,
              preface: const Text('Laptop asks'),
              title: 'Approval required: write_file',
              message: 'x ' * 400,
              messageMaxLines: 3,
              content: const Text('extra body'),
              actions: <Widget>[
                TextButton(onPressed: () {}, child: const Text('Deny')),
                FilledButton(
                  onPressed: () {},
                  child: const Text('Approve once'),
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Laptop asks'), findsOneWidget);
      expect(find.text('extra body'), findsOneWidget);
      expect(find.text('Approve once'), findsOneWidget);
    });

    for (final Brightness b in Brightness.values) {
      testWidgets('warning tone is amber regardless of accent (${b.name})', (
        tester,
      ) async {
        await tester.pumpWidget(
          _app(
            const AppBanner(tone: AppBannerTone.warning, message: 'careful'),
            brightness: b,
          ),
        );
        final DecoratedBox box = tester.widget<DecoratedBox>(
          find
              .descendant(
                of: find.byType(AppBanner),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        final Color color = (box.decoration as BoxDecoration).color!;
        expect(
          color,
          b == Brightness.dark
              ? AppColors.warningContainerDark
              : AppColors.warningContainerLight,
        );
      });
    }
  });

  group('AppMessageBubble unboxed assistant', () {
    testWidgets('uses the full width with no border', (tester) async {
      await tester.pumpWidget(
        _app(
          const SizedBox(
            width: 300,
            child: AppMessageBubble(
              role: AppMessageRole.assistant,
              boxed: false,
              child: Text('markdown'),
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(AppMessageBubble)).width, 300);
      expect(
        find.descendant(
          of: find.byType(AppMessageBubble),
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
      );
    });
  });

  group('AppRadii', () {
    test('exposes the shared corner scale', () {
      expect(AppRadii.xs, const BorderRadius.all(Radius.circular(3)));
      expect(AppRadii.sm, const BorderRadius.all(Radius.circular(4)));
      expect(AppRadii.md, const BorderRadius.all(Radius.circular(6)));
      expect(AppRadii.lg, const BorderRadius.all(Radius.circular(8)));
      expect(
        AppRadii.surfaceFor(TargetPlatform.windows),
        BorderRadius.circular(8),
      );
      expect(
        AppRadii.surfaceFor(TargetPlatform.iOS),
        BorderRadius.circular(12),
      );
    });
  });
}
