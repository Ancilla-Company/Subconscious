import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

Widget _host(
  Widget child, {
  Brightness brightness = Brightness.light,
  TargetPlatform platform = TargetPlatform.android,
}) => MaterialApp(
  theme: ThemeData(brightness: brightness, platform: platform),
  home: Builder(
    builder: (BuildContext context) => Theme(
      data: appFormTheme(context),
      child: Scaffold(
        body: SingleChildScrollView(child: SizedBox(width: 400, child: child)),
      ),
    ),
  ),
);

void main() {
  for (final Brightness brightness in Brightness.values) {
    for (final TargetPlatform platform in TargetPlatform.values) {
      testWidgets('field variants share one height on ${platform.name} '
          '(${brightness.name})', (WidgetTester tester) async {
        await tester.pumpWidget(
          _host(
            const Column(
              children: <Widget>[
                AppTextField(key: ValueKey<String>('plain'), label: 'Plain'),
                AppTextField(
                  key: ValueKey<String>('secret'),
                  label: 'Secret',
                  obscureText: true,
                ),
                AppTextField(
                  key: ValueKey<String>('email'),
                  label: 'Email',
                  keyboardType: TextInputType.emailAddress,
                  hintText: 'you@example.com',
                ),
              ],
            ),
            brightness: brightness,
            platform: platform,
          ),
        );
        double height(String key) => tester
            .getSize(
              find.descendant(
                of: find.byKey(ValueKey<String>(key)),
                matching: find.byType(TextFormField),
              ),
            )
            .height;
        expect(height('plain'), height('secret'));
        expect(height('plain'), height('email'));
        expect(find.text('Plain'), findsOneWidget);
      }, variant: TargetPlatformVariant.only(platform));
    }
  }

  testWidgets('label sits above the field', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const AppTextField(label: 'Name')));
    expect(
      tester.getBottomLeft(find.text('Name')).dy,
      lessThanOrEqualTo(tester.getTopLeft(find.byType(TextFormField)).dy),
    );
  });

  testWidgets('no label renders a bare field', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const AppTextField(hintText: 'hint')));
    expect(find.byType(AppFieldLabel), findsNothing);
    expect(find.text('hint'), findsOneWidget);
  });

  testWidgets('obscure field hides text and stays single line', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const AppTextField(label: 'Password', obscureText: true, maxLines: 4),
      ),
    );
    await tester.enterText(find.byType(TextFormField), 'hunter22');
    final EditableText editable = tester.widget(find.byType(EditableText));
    expect(editable.obscureText, isTrue);
    expect(editable.maxLines, 1);
  });

  testWidgets('helper text is shown only when given', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(const AppTextField(label: 'A')));
    expect(find.text('Guidance'), findsNothing);
    await tester.pumpWidget(
      _host(const AppTextField(label: 'A', helperText: 'Guidance')),
    );
    expect(find.text('Guidance'), findsOneWidget);
  });

  testWidgets('multi-line field is taller than a single line', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const Column(
          children: <Widget>[
            AppTextField(key: ValueKey<String>('one'), label: 'One'),
            AppTextField(
              key: ValueKey<String>('many'),
              label: 'Many',
              minLines: 4,
              maxLines: 6,
            ),
          ],
        ),
      ),
    );
    double height(String key) => tester
        .getSize(
          find.descendant(
            of: find.byKey(ValueKey<String>(key)),
            matching: find.byType(TextFormField),
          ),
        )
        .height;
    expect(height('many'), greaterThan(height('one')));
  });

  testWidgets('read-only value row has icon, fixed height and value', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const AppTextField(
          label: 'Port',
          initialValue: '50505',
          readOnly: true,
          height: 32,
          prefixIcon: Icon(Icons.lan, size: 17),
        ),
      ),
    );
    expect(find.byIcon(Icons.lan), findsOneWidget);
    expect(find.text('50505'), findsOneWidget);
    expect(tester.getSize(find.byType(TextFormField)).height, 32);
    final EditableText editable = tester.widget(find.byType(EditableText));
    expect(editable.readOnly, isTrue);
  });

  testWidgets('text field reports changes and submission', (
    WidgetTester tester,
  ) async {
    final List<String> changed = <String>[];
    final List<String> submitted = <String>[];
    await tester.pumpWidget(
      _host(
        AppTextField(
          label: 'Q',
          onChanged: changed.add,
          onSubmitted: submitted.add,
        ),
      ),
    );
    await tester.enterText(find.byType(TextFormField), 'abc');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    expect(changed, <String>['abc']);
    expect(submitted, <String>['abc']);
  });

  testWidgets('AppFieldLabel shows bold text', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const AppFieldLabel('Hello')));
    final Text text = tester.widget(find.text('Hello'));
    expect(text.style?.fontWeight, FontWeight.bold);
  });

  testWidgets('AppDropdown selects and calls onChanged', (
    WidgetTester tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      _host(
        AppDropdown(
          label: 'Mode',
          value: 'A',
          options: const <String>['A', 'B'],
          onChanged: (String v) => picked = v,
        ),
      ),
    );
    expect(find.text('Mode'), findsOneWidget);
    await tester.tap(find.byType(InputDecorator));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B').last);
    await tester.pumpAndSettle();
    expect(picked, 'B');
  });

  testWidgets('AppDropdownField selects and calls onChanged', (
    WidgetTester tester,
  ) async {
    int? picked;
    await tester.pumpWidget(
      _host(
        AppDropdownField<int>(
          hint: const Text('Pick'),
          items: const <DropdownMenuItem<int>>[
            DropdownMenuItem<int>(value: 1, child: Text('One')),
            DropdownMenuItem<int>(value: 2, child: Text('Two')),
          ],
          onChanged: (int? v) => picked = v,
        ),
      ),
    );
    expect(find.text('Pick'), findsOneWidget);
    await tester.tap(find.byType(AppDropdownField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Two').last);
    await tester.pumpAndSettle();
    expect(picked, 2);
  });

  testWidgets('AppCompactDropdown picks a value without a form outline', (
    WidgetTester tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) =>
              AppCompactDropdown<String>(
                value: 'a',
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(value: 'a', child: Text('All')),
                  DropdownMenuItem<String>(value: 'b', child: Text('Beta')),
                ],
                onChanged: (String? value) => picked = value,
              ),
        ),
      ),
    );
    expect(find.byType(InputDecorator), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beta').last);
    await tester.pumpAndSettle();
    expect(picked, 'b');
  });

  testWidgets('AppButtonRow right-aligns its children', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AppButtonRow(
          children: <Widget>[
            TextButton(onPressed: () {}, child: const Text('Cancel')),
            FilledButton(onPressed: () {}, child: const Text('Save')),
          ],
        ),
      ),
    );
    final double right = tester.getTopRight(find.byType(AppButtonRow)).dx;
    expect(
      tester.getTopRight(find.byType(FilledButton)).dx,
      closeTo(right, 0.5),
    );
    expect(
      tester.getTopLeft(find.byType(FilledButton)).dx,
      greaterThan(tester.getTopLeft(find.byType(TextButton)).dx),
    );
  });

  testWidgets('AppSwitchTile toggles', (WidgetTester tester) async {
    bool value = false;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) =>
              AppSwitchTile(
                title: 'Enabled',
                subtitle: 'Turns it on',
                value: value,
                onChanged: (bool v) => setState(() => value = v),
              ),
        ),
      ),
    );
    expect(find.text('Turns it on'), findsOneWidget);
    // The kit's rectangular switch, never the round Material one.
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(AppSwitch), findsOneWidget);
    await tester.tap(find.byType(AppSwitch));
    await tester.pump();
    expect(value, isTrue);
    await tester.tap(find.text('Enabled'));
    await tester.pump();
    expect(value, isFalse);
  });

  testWidgets('error, heading and empty message render', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const Column(
          children: <Widget>[
            AppFormError(error: 'Boom'),
            AppSectionHeading(title: 'Heading'),
            AppEmptyMessage('Nothing here'),
          ],
        ),
      ),
    );
    expect(find.text('Boom'), findsOneWidget);
    expect(find.text('Heading'), findsOneWidget);
    expect(find.text('Nothing here'), findsOneWidget);
  });
}
