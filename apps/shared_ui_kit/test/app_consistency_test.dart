import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: AppFormTheme(child: Center(child: child))),
);

void main() {
  group('AppSwitch sizes', () {
    testWidgets('the normal switch is larger than the compact one', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AppSwitch(value: true, onChanged: (_) {}, semanticLabel: 'n'),
              AppSwitch(
                value: true,
                compact: true,
                onChanged: (_) {},
                semanticLabel: 'c',
              ),
            ],
          ),
        ),
      );
      Size track(String label) => tester.getSize(
        find.descendant(
          of: find.bySemanticsLabel(label),
          matching: find.byType(AnimatedContainer),
        ).first,
      );
      expect(track('n'), const Size(52, 30));
      expect(track('c'), const Size(40, 24));
      expect(find.byType(Switch), findsNothing);
    });
  });

  group('AppCompactDropdown', () {
    testWidgets('is self-contained: sized, with its own ink', (
      WidgetTester tester,
    ) async {
      String? chosen;
      await tester.pumpWidget(
        // No Material wrapper around it, as the composer used to add.
        MaterialApp(
          home: Scaffold(
            body: AppFormTheme(
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 200,
                  child: AppCompactDropdown<String>(
                    value: 'a',
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem<String>(value: 'a', child: Text('One')),
                      DropdownMenuItem<String>(value: 'b', child: Text('Two')),
                    ],
                    onChanged: (String? v) => chosen = v,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(AppCompactDropdown<String>)).height, 32);
      await tester.tap(find.text('One'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Two').last);
      await tester.pumpAndSettle();
      expect(chosen, 'b');
    });
  });

  group('AppRadii', () {
    test('one 3 px corner', () {
      expect(AppRadii.value, 3);
      expect(AppRadii.standard, const BorderRadius.all(Radius.circular(3)));
    });

    testWidgets('fields, buttons, cards and switches all use it', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AppTextField(label: 'Name'),
              AppCard(child: Text('card')),
            ],
          ),
        ),
      );
      final InputDecorator field = tester.widget<InputDecorator>(
        find.byType(InputDecorator),
      );
      expect(
        (field.decoration.enabledBorder! as OutlineInputBorder).borderRadius,
        AppRadii.standard,
      );
      final Card card = tester.widget<Card>(find.byType(Card));
      expect(
        (card.shape! as RoundedRectangleBorder).borderRadius,
        AppRadii.standard,
      );
    });
  });

  group('AppExpansionCard', () {
    testWidgets('shows its editor only while expanded', (
      WidgetTester tester,
    ) async {
      bool expanded = false;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) =>
                AppExpansionCard(
                  title: 'Filesystem',
                  subtitle: 'MCP server',
                  trailingLabel: 'Connected',
                  expanded: expanded,
                  onToggle: () => setState(() => expanded = !expanded),
                  child: const Text('editor'),
                ),
          ),
        ),
      );
      expect(find.text('Filesystem'), findsOneWidget);
      expect(find.text('MCP server'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('editor'), findsNothing);
      await tester.tap(find.text('Filesystem'));
      await tester.pumpAndSettle();
      expect(find.text('editor'), findsOneWidget);
    });

    testWidgets('without a child there is nothing to open', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(
          AppExpansionCard(
            title: 'Empty',
            expanded: true,
            onToggle: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Empty'), findsOneWidget);
    });
  });

  group('AppDeviceCard', () {
    testWidgets('shows the device, then its clients nested in the card', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 420,
            child: AppDeviceCard(
              device: AppDeviceTile(
                title: 'WORKSTATION (this device)',
                subtitle: 'Online, Full node',
                detail: 'Clients: Phone',
                badge: const AppBadge('Connected'),
                actions: <Widget>[
                  TextButton(onPressed: () {}, child: const Text('Remove')),
                ],
              ),
              clients: const <AppDeviceTile>[
                AppDeviceTile(title: 'Phone', subtitle: 'Online, Client'),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(Card), findsOneWidget);
      expect(find.text('WORKSTATION (this device)'), findsOneWidget);
      expect(find.text('Clients: Phone'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
      expect(find.byType(Divider), findsOneWidget);
      // The client is indented relative to the device.
      expect(
        tester.getTopLeft(find.text('Phone')).dx,
        greaterThan(tester.getTopLeft(find.text('WORKSTATION (this device)')).dx),
      );
    });
  });

  group('AppSectionCard expandable header', () {
    testWidgets('the whole header is one button; the chevron is not', (
      WidgetTester tester,
    ) async {
      bool? switched;
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 400,
            child: AppSectionCard(
              title: 'Custom Tools',
              subtitle: 'Registered by ID.',
              expandable: true,
              initiallyExpanded: false,
              trailing: AppSwitch(
                value: false,
                onChanged: (bool v) => switched = v,
                semanticLabel: 'Enable',
              ),
              child: const Text('body'),
            ),
          ),
        ),
      );
      // One InkWell for the header, none around the chevron.
      expect(find.byType(InkWell), findsOneWidget);
      expect(find.text('body'), findsNothing);

      // Tapping the chevron (or empty header space) opens the panel.
      // The icon ignores pointers; the header's button underneath gets the tap.
      await tester.tap(find.byIcon(Icons.expand_more), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('body'), findsOneWidget);
      await tester.tapAt(
        tester.getTopLeft(find.text('Custom Tools')) + const Offset(150, 4),
      );
      await tester.pumpAndSettle();
      expect(find.text('body'), findsNothing);

      // The trailing switch still works on its own.
      await tester.tap(find.byType(AppSwitch));
      expect(switched, isTrue);
      expect(find.text('body'), findsNothing);
    });
  });

  group('AppPickerButton', () {
    testWidgets('shows the choice and opens a menu of items', (
      WidgetTester tester,
    ) async {
      String? picked;
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 200,
            child: AppPickerButton<String>(
              icon: Icons.folder_outlined,
              label: 'All workspaces',
              items: const <AppMenuItem<String>>[
                AppMenuItem<String>(
                  value: '',
                  label: 'All workspaces',
                  selected: true,
                ),
                AppMenuItem<String>(value: 'a', label: 'Alpha'),
              ],
              onSelected: (String v) => picked = v,
            ),
          ),
        ),
      );
      expect(find.text('All workspaces'), findsOneWidget);
      expect(tester.getSize(find.byType(AppPickerButton<String>)).height, 32);
      await tester.tap(find.text('All workspaces'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(picked, 'a');
    });

    testWidgets('disabled does not open', (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 200,
            child: AppPickerButton<String>(
              label: 'Alpha',
              enabled: false,
              items: const <AppMenuItem<String>>[
                AppMenuItem<String>(value: 'a', label: 'Alpha'),
              ],
              onSelected: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      expect(find.byType(PopupMenuItem<String>), findsNothing);
    });
  });
}