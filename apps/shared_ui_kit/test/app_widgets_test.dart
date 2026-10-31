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

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
}) => tester.pumpWidget(_app(child, brightness: brightness));

void main() {
  group('AppDialog', () {
    testWidgets('shows heading, content and actions in a button row', (
      tester,
    ) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                result = await showAppDialog<bool>(
                  context: context,
                  builder: (BuildContext context) => AppDialog(
                    title: 'Delete?',
                    content: const Text('Really'),
                    actions: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(AppSectionHeading), findsOneWidget);
      expect(find.text('Delete?'), findsOneWidget);
      expect(find.byType(AppButtonRow), findsOneWidget);
      // It is wrapped in the kit theme: flat 3px dialog.
      final Material material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.elevation, 0);
      expect(
        (material.shape! as RoundedRectangleBorder).borderRadius,
        const BorderRadius.all(Radius.circular(3)),
      );
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('AppBottomSheet', () {
    testWidgets('has a drag handle and title and lifts above the keyboard', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showAppBottomSheet<void>(
                context: context,
                title: 'Options',
                builder: (BuildContext context) => const Text('body'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Drag handle'), findsOneWidget);
      expect(find.text('Options'), findsOneWidget);
      expect(find.text('body'), findsOneWidget);
      expect(find.byType(SafeArea), findsWidgets);
    });

    testWidgets('bottom padding follows the keyboard inset', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              viewInsets: EdgeInsets.only(bottom: 200),
            ),
            child: const Material(child: AppBottomSheet(child: Text('x'))),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final AnimatedPadding padding = tester.widget<AnimatedPadding>(
        find.byType(AnimatedPadding),
      );
      expect((padding.padding as EdgeInsets).bottom, 200);
    });
  });

  group('AppCard / AppSectionCard', () {
    testWidgets('AppCard taps and shows its child', (tester) async {
      int taps = 0;
      await _pump(
        tester,
        AppCard(onTap: () => taps++, child: const Text('hello')),
      );
      await tester.tap(find.text('hello'));
      expect(taps, 1);
    });

    testWidgets('AppSectionCard shows title and trailing', (tester) async {
      await _pump(
        tester,
        const AppSectionCard(
          title: 'Section',
          trailing: Text('T'),
          child: Text('body'),
        ),
      );
      expect(find.text('Section'), findsOneWidget);
      expect(find.text('T'), findsOneWidget);
      expect(find.text('body'), findsOneWidget);
    });

    testWidgets('expandable AppSectionCard toggles its body', (tester) async {
      await _pump(
        tester,
        const AppSectionCard(
          title: 'Section',
          expandable: true,
          initiallyExpanded: false,
          child: Text('body'),
        ),
      );
      expect(find.text('body'), findsNothing);
      await tester.tap(find.text('Section'));
      await tester.pump();
      expect(find.text('body'), findsOneWidget);
      await tester.tap(find.text('Section'));
      await tester.pump();
      expect(find.text('body'), findsNothing);
    });
  });

  group('AppListRow', () {
    for (final Brightness brightness in Brightness.values) {
      testWidgets(
        'selected fill matches FlyoutNavButton (${brightness.name})',
        (tester) async {
          await _pump(
            tester,
            Column(
              children: <Widget>[
                AppListRow(title: 'Row', selected: true, onTap: () {}),
                AppListRow(title: 'Other', onTap: () {}),
              ],
            ),
            brightness: brightness,
          );
          final ColorScheme colors = Theme.of(tester.element(find.text('Row')))
              .colorScheme;
          Color? fill(String t) => tester
              .widget<Material>(
                find
                    .descendant(
                      of: find.ancestor(
                        of: find.text(t),
                        matching: find.byType(AppListRow),
                      ),
                      matching: find.byType(Material),
                    )
                    .first,
              )
              .color;
          expect(fill('Row'), colors.secondaryContainer);
          expect(fill('Other'), Colors.transparent);
        },
      );
    }

    testWidgets('renders subtitle, leading, trailing; taps; semantics', (
      tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      int taps = 0;
      await _pump(
        tester,
        AppListRow(
          title: 'Title',
          subtitle: 'Sub',
          leading: const Icon(Icons.add),
          trailing: const Text('R'),
          selected: true,
          onTap: () => taps++,
        ),
      );
      expect(find.text('Sub'), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);
      expect(find.text('R'), findsOneWidget);
      await tester.tap(find.text('Title'));
      expect(taps, 1);
      expect(
        tester.getSemantics(find.byType(AppListRow)),
        matchesSemantics(
          label: 'Title, Sub',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
          hasLongPressAction: false,
          isFocusable: false,
        ),
      );
      handle.dispose();
    });

    testWidgets('minHeight raises the touch target', (tester) async {
      await _pump(tester, AppListRow(title: 'A', onTap: () {}, minHeight: 48));
      expect(tester.getSize(find.byType(AppListRow)).height, 48);
      await _pump(tester, AppListRow(title: 'A', dense: true, onTap: () {}));
      expect(tester.getSize(find.byType(AppListRow)).height, 32);
    });
  });

  group('AppTreeRow', () {
    testWidgets('is 30 high and indents by depth', (tester) async {
      await _pump(
        tester,
        Column(
          children: <Widget>[
            AppTreeRow(label: 'root', onTap: () {}),
            AppTreeRow(label: 'child', depth: 2, onTap: () {}),
          ],
        ),
      );
      expect(tester.getSize(find.byType(AppTreeRow).first).height, 30);
      final double rootX = tester.getTopLeft(find.text('root')).dx;
      final double childX = tester.getTopLeft(find.text('child')).dx;
      expect(childX - rootX, 28);
    });

    testWidgets('selected and highlighted fill, inert without onTap', (
      tester,
    ) async {
      await _pump(
        tester,
        const AppTreeRow(label: 'drop', highlighted: true, onTap: null),
      );
      final ColorScheme colors = Theme.of(tester.element(find.text('drop')))
          .colorScheme;
      final Material material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(AppTreeRow),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.color, colors.secondaryContainer);
    });

    testWidgets('minHeight raises the touch target', (tester) async {
      await _pump(tester, AppTreeRow(label: 'a', minHeight: 44, onTap: () {}));
      expect(tester.getSize(find.byType(AppTreeRow)).height, 44);
    });
  });

  group('AppIconButton', () {
    testWidgets('compact is 32, regular 40, minTouchTarget raises', (
      tester,
    ) async {
      await _pump(
        tester,
        AppIconButton(icon: Icons.add, tooltip: 'Add', onPressed: () {}),
      );
      expect(tester.getSize(find.byType(AppIconButton)), const Size(32, 32));
      await _pump(
        tester,
        AppIconButton(
          icon: Icons.add,
          tooltip: 'Add',
          size: AppIconButtonSize.regular,
          onPressed: () {},
        ),
      );
      expect(tester.getSize(find.byType(AppIconButton)), const Size(40, 40));
      await _pump(
        tester,
        AppIconButton(
          icon: Icons.add,
          tooltip: 'Add',
          minTouchTarget: 48,
          onPressed: () {},
        ),
      );
      expect(tester.getSize(find.byType(AppIconButton)), const Size(48, 48));
    });

    testWidgets('fires onPressed, has a tooltip, disables on null', (
      tester,
    ) async {
      int taps = 0;
      await _pump(
        tester,
        AppIconButton(icon: Icons.add, tooltip: 'Add', onPressed: () => taps++),
      );
      expect(find.byTooltip('Add'), findsOneWidget);
      await tester.tap(find.byType(AppIconButton));
      expect(taps, 1);
      await _pump(
        tester,
        const AppIconButton(icon: Icons.add, tooltip: 'Add', onPressed: null),
      );
      await tester.tap(find.byType(AppIconButton));
      expect(taps, 1);
    });

    testWidgets('selected uses secondaryContainer and selectedIcon', (
      tester,
    ) async {
      await _pump(
        tester,
        AppIconButton(
          icon: Icons.add,
          selectedIcon: Icons.remove,
          selected: true,
          tooltip: 'Toggle',
          onPressed: () {},
        ),
      );
      expect(find.byIcon(Icons.remove), findsOneWidget);
      expect(find.byIcon(Icons.add), findsNothing);
      final ColorScheme colors = Theme.of(
        tester.element(find.byType(AppIconButton)),
      ).colorScheme;
      final IconButton button = tester.widget<IconButton>(
        find.byType(IconButton),
      );
      expect(
        button.style!.backgroundColor!.resolve(<WidgetState>{}),
        colors.secondaryContainer,
      );
    });
  });

  group('AppStatusDot', () {
    testWidgets('uses the status tokens and labels', (tester) async {
      for (final AppStatus status in AppStatus.values) {
        await _pump(tester, AppStatusDot(status: status));
        expect(find.text(status.name), findsOneWidget);
        final BoxDecoration decoration =
            tester
                    .widget<DecoratedBox>(find.byType(DecoratedBox).last)
                    .decoration
                as BoxDecoration;
        expect(decoration.color, status.color);
      }
      expect(AppStatus.connected.color, AppColors.statusConnected);
      expect(AppStatus.connecting.color, AppColors.statusConnecting);
      expect(AppStatus.disconnected.color, AppColors.statusDisconnected);
    });

    testWidgets('custom label and label hidden', (tester) async {
      await _pump(
        tester,
        const AppStatusDot(
          status: AppStatus.connecting,
          label: 'starting engine',
        ),
      );
      expect(find.text('starting engine'), findsOneWidget);
      await _pump(
        tester,
        const AppStatusDot(status: AppStatus.connected, showLabel: false),
      );
      expect(find.text('connected'), findsNothing);
    });
  });

  group('AppBadge', () {
    for (final AppBadgeTone tone in AppBadgeTone.values) {
      testWidgets('renders ${tone.name}', (tester) async {
        await _pump(tester, AppBadge('3', tone: tone));
        expect(find.text('3'), findsOneWidget);
      });
    }
  });

  group('AppSegmentedControl', () {
    testWidgets('shows segments and reports the chosen value', (tester) async {
      String selected = 'a';
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) =>
                AppSegmentedControl<String>(
                  segments: const <AppSegment<String>>[
                    AppSegment<String>(value: 'a', label: 'Sign in'),
                    AppSegment<String>(value: 'b', label: 'Create'),
                  ],
                  selected: selected,
                  onChanged: (String v) => setState(() => selected = v),
                ),
          ),
        ),
      );
      expect(find.text('Sign in'), findsOneWidget);
      await tester.tap(find.text('Create'));
      await tester.pump();
      expect(selected, 'b');
    });
  });

  group('AppBanner', () {
    for (final AppBannerTone tone in AppBannerTone.values) {
      testWidgets('${tone.name} shows title, message and actions', (
        tester,
      ) async {
        int taps = 0;
        await _pump(
          tester,
          AppBanner(
            tone: tone,
            title: 'Heads up',
            message: 'Something',
            actions: <Widget>[
              TextButton(onPressed: () => taps++, child: const Text('Retry')),
            ],
          ),
        );
        expect(find.text('Heads up'), findsOneWidget);
        expect(find.text('Something'), findsOneWidget);
        await tester.tap(find.text('Retry'));
        expect(taps, 1);
      });
    }

    testWidgets('error tone uses errorContainer', (tester) async {
      await _pump(
        tester,
        const AppBanner(tone: AppBannerTone.error, message: 'bad'),
      );
      final ColorScheme colors = Theme.of(tester.element(find.text('bad')))
          .colorScheme;
      final BoxDecoration d =
          tester
                  .widget<DecoratedBox>(
                    find.descendant(
                      of: find.byType(AppBanner),
                      matching: find.byType(DecoratedBox),
                    ),
                  )
                  .decoration
              as BoxDecoration;
      expect(d.color, colors.errorContainer);
    });
  });

  group('AppMessageBubble', () {
    testWidgets('aligns by role', (tester) async {
      await tester.pumpWidget(
        _app(
          const SizedBox(
            width: 400,
            child: Column(
              children: <Widget>[
                AppMessageBubble(role: AppMessageRole.user, child: Text('u')),
                AppMessageBubble(
                  role: AppMessageRole.assistant,
                  child: Text('a'),
                ),
                AppMessageBubble(role: AppMessageRole.system, child: Text('s')),
              ],
            ),
          ),
        ),
      );
      final double user = tester.getCenter(find.text('u')).dx;
      final double assistant = tester.getCenter(find.text('a')).dx;
      final double system = tester.getCenter(find.text('s')).dx;
      expect(user, greaterThan(system));
      expect(assistant, lessThan(system));
    });

    testWidgets('user bubble is secondaryContainer', (tester) async {
      await _pump(
        tester,
        const AppMessageBubble(role: AppMessageRole.user, child: Text('u')),
      );
      final ColorScheme colors = Theme.of(tester.element(find.text('u')))
          .colorScheme;
      final BoxDecoration d =
          tester
                  .widget<DecoratedBox>(
                    find.descendant(
                      of: find.byType(AppMessageBubble),
                      matching: find.byType(DecoratedBox),
                    ),
                  )
                  .decoration
              as BoxDecoration;
      expect(d.color, colors.secondaryContainer);
    });
  });

  group('AppPopupMenu', () {
    testWidgets('opens, lists items, reports selection', (tester) async {
      String? chosen;
      await _pump(
        tester,
        AppPopupMenu<String>(
          items: const <AppMenuItem<String>>[
            AppMenuItem<String>(value: 'one', label: 'One'),
            AppMenuItem<String>(value: 'two', label: 'Two', icon: Icons.add),
          ],
          onSelected: (String v) => chosen = v,
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('One'), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);
      await tester.tap(find.text('Two'));
      await tester.pumpAndSettle();
      expect(chosen, 'two');
    });

    testWidgets('menu surface uses the kit shape', (tester) async {
      await _pump(
        tester,
        AppPopupMenu<int>(
          items: const <AppMenuItem<int>>[
            AppMenuItem<int>(value: 1, label: 'One'),
          ],
          onSelected: (_) {},
        ),
      );
      final PopupMenuButton<int> button = tester.widget<PopupMenuButton<int>>(
        find.byType(PopupMenuButton<int>),
      );
      expect(
        (button.shape! as RoundedRectangleBorder).borderRadius,
        const BorderRadius.all(Radius.circular(3)),
      );
      expect(button.surfaceTintColor, Colors.transparent);
    });
  });

  group('AppSearchField', () {
    testWidgets('has a search icon, hint and reports changes', (tester) async {
      String text = '';
      await _pump(tester, AppSearchField(onChanged: (String v) => text = v));
      expect(find.byIcon(Icons.search), findsOneWidget);
      expect(find.text('Search'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), 'abc');
      expect(text, 'abc');
    });
  });

  group('showAppSnack', () {
    testWidgets('shows a floating flat snack and replaces the previous', (
      tester,
    ) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) {
                captured = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      showAppSnack(captured, 'first');
      await tester.pump();
      showAppSnack(captured, 'second', isError: true);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('second'), findsOneWidget);
      final SnackBar snack = tester.widget<SnackBar>(find.byType(SnackBar));
      final ColorScheme colors = Theme.of(captured).colorScheme;
      expect(snack.backgroundColor, colors.errorContainer);
      expect(snack.behavior, SnackBarBehavior.floating);
      expect(snack.elevation, 0);
    });
  });

  group('AppFlyoutHeader', () {
    testWidgets('shows the logo widget and title', (tester) async {
      await _pump(
        tester,
        const AppFlyoutHeader(
          title: 'Subconscious',
          logo: Icon(Icons.circle, key: Key('logo')),
        ),
      );
      expect(find.byKey(const Key('logo')), findsOneWidget);
      expect(find.text('Subconscious'), findsOneWidget);
      expect(tester.getSize(find.byType(AppFlyoutHeader)).height, 48);
    });

    testWidgets('works without a logo', (tester) async {
      await _pump(tester, const AppFlyoutHeader(title: 'Only title'));
      expect(find.text('Only title'), findsOneWidget);
    });
  });

  testWidgets('AppEmptyMessage shows an optional action', (tester) async {
    await _pump(
      tester,
      AppEmptyMessage(
        'Nothing',
        action: OutlinedButton(onPressed: () {}, child: const Text('Retry')),
      ),
    );
    expect(find.text('Nothing'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
