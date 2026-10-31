import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';
import 'package:unified_app/features/chat/presentation/threads_list.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';

Future<EngineRepository?> _noEngine({
  Uri? explicitEndpoint,
  String? explicitToken,
}) async => null;

const List<ThreadInfo> _threads = <ThreadInfo>[
  ThreadInfo(uuid: 't1', workspaceUuid: 'w1', title: 'Trip plans'),
  ThreadInfo(uuid: 't2', workspaceUuid: 'w2', title: 'Budget review'),
  ThreadInfo(uuid: 't3', workspaceUuid: 'w1'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  late DashboardController dashboard;
  setUp(() {
    dashboard = DashboardController(_noEngine)
      ..workspaces = const <Workspace>[
        Workspace(uuid: 'w1', name: 'Alpha'),
        Workspace(uuid: 'w2', name: 'Beta'),
      ]
      ..threads = _threads
      ..threadsListVisible = true;
  });
  tearDown(() => dashboard.dispose());

  Widget app(double width) => MaterialApp(
    // The list sits outside the form theme in the app, as here.
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: ThreadsList(controller: dashboard),
        ),
      ),
    ),
  );

  testWidgets('the header has the picker and, at the far right, close', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(app(400));
    expect(find.text('Threads'), findsOneWidget);
    expect(find.byType(AppPickerButton<String>), findsOneWidget);
    final Rect picker = tester.getRect(
      find.byType(AppPickerButton<String>),
    );
    final Rect close = tester.getRect(
      find.ancestor(
        of: find.byTooltip('Close threads'),
        matching: find.byType(AppIconButton),
      ),
    );
    expect(close.left, greaterThanOrEqualTo(picker.right));
    expect(close.right, closeTo(392, 1)); // 8 dp from the right edge
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Close threads'));
    expect(dashboard.threadsListVisible, isFalse);
  });

  testWidgets('a narrow list does not overflow', (WidgetTester tester) async {
    await tester.pumpWidget(app(240));
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Close threads'), findsOneWidget);
  });

  testWidgets('the search box is bordered and filters the threads', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(app(400));
    expect(find.byType(AppSearchField), findsOneWidget);
    final InputDecorator decorator = tester.widget<InputDecorator>(
      find.descendant(
        of: find.byType(AppSearchField),
        matching: find.byType(InputDecorator),
      ),
    );
    expect(decorator.decoration.enabledBorder, isA<OutlineInputBorder>());

    expect(find.byType(AppListRow), findsNWidgets(3));
    await tester.enterText(find.byType(EditableText), 'BUDGET');
    await tester.pump();
    expect(find.byType(AppListRow), findsOneWidget);
    expect(find.text('Budget review'), findsOneWidget);

    // In the all-workspaces list the workspace name matches too.
    await tester.enterText(find.byType(EditableText), 'alpha');
    await tester.pump();
    expect(find.byType(AppListRow), findsNWidgets(2));
    expect(find.text('Untitled thread'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'zzz');
    await tester.pump();
    expect(find.byType(AppListRow), findsNothing);
    expect(find.textContaining('No threads match'), findsOneWidget);
  });
}
