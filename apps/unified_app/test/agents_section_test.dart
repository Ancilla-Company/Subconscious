import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';
import 'package:unified_app/features/agents/presentation/agent_panel.dart';
import 'package:unified_app/features/chat/engine_llm_provider.dart';
import 'package:unified_app/features/chat/presentation/engine_chat_panel.dart';
import 'package:unified_app/features/context/presentation/context_panel.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';
import 'package:unified_app/features/settings/controller/settings_controller.dart';

import 'screen_helpers.dart';

Future<EngineRepository?> _noEngine({
  Uri? explicitEndpoint,
  String? explicitToken,
}) async => null;

const List<AgentInfo> _agents = <AgentInfo>[
  AgentInfo(
    uuid: 'a1',
    name: 'Researcher',
    description: 'Finds things on the web',
    workspaceUuid: 'w1',
  ),
  AgentInfo(uuid: 'a2', name: 'Editor', description: 'Polishes drafts'),
  AgentInfo(uuid: 'a3', name: 'Archivist', enabled: false, workspaceUuid: 'w2'),
];

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(body: AppFormTheme(child: child)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  late DashboardController dashboard;
  setUp(() {
    dashboard = DashboardController(_noEngine)..agents = _agents;
  });
  tearDown(() => dashboard.dispose());

  group('Agents context panel', () {
    testWidgets('lists every agent with icon, name and description', (
      WidgetTester tester,
    ) async {
      useScreen(tester, const Size(360, 800));
      await tester.pumpWidget(
        _app(
          ContextPanel(screen: DashboardSection.agents, controller: dashboard),
        ),
      );
      expect(find.text('Agents'), findsOneWidget);
      for (final AgentInfo agent in _agents) {
        expect(find.text(agent.name), findsOneWidget);
      }
      expect(find.text('Finds things on the web'), findsOneWidget);
      expect(find.byType(AppListRow), findsNWidgets(3));
      expect(find.byType(AppSearchField), findsOneWidget);
      // Only the account-wide agent carries the globe.
      expect(find.byTooltip('Available in every workspace'), findsOneWidget);
      expect(find.byTooltip('New agent'), findsOneWidget);
    });

    testWidgets('the search box has the bordered settings field style', (
      WidgetTester tester,
    ) async {
      useScreen(tester, const Size(360, 800));
      // Without the form theme around it, as the desktop context panel is.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContextPanel(
              screen: DashboardSection.agents,
              controller: dashboard,
            ),
          ),
        ),
      );
      final InputDecorator decorator = tester.widget<InputDecorator>(
        find.descendant(
          of: find.byType(AppSearchField),
          matching: find.byType(InputDecorator),
        ),
      );
      final ColorScheme colors = Theme.of(
        tester.element(find.byType(AppSearchField)),
      ).colorScheme;
      final InputBorder? border = decorator.decoration.enabledBorder;
      expect(border, isA<OutlineInputBorder>());
      expect(border!.borderSide.color, colors.outlineVariant);
    });

    testWidgets('the search box filters by name and description', (
      WidgetTester tester,
    ) async {
      useScreen(tester, const Size(360, 800));
      await tester.pumpWidget(
        _app(
          ContextPanel(screen: DashboardSection.agents, controller: dashboard),
        ),
      );
      await tester.enterText(find.byType(EditableText), 'POLISH');
      await tester.pump();
      expect(find.byType(AppListRow), findsOneWidget);
      expect(find.text('Editor'), findsOneWidget);

      await tester.enterText(find.byType(EditableText), 'web');
      await tester.pump();
      expect(find.text('Researcher'), findsOneWidget);

      await tester.enterText(find.byType(EditableText), 'nothing like it');
      await tester.pump();
      expect(find.byType(AppListRow), findsNothing);
      expect(find.textContaining('No agents match'), findsOneWidget);
    });

    testWidgets('tapping an agent selects it and opens its form', (
      WidgetTester tester,
    ) async {
      useScreen(tester, const Size(360, 800));
      await tester.pumpWidget(
        _app(
          ContextPanel(screen: DashboardSection.agents, controller: dashboard),
        ),
      );
      await tester.tap(find.text('Editor'));
      // Let the debounced save of the new selection run.
      await tester.pump(const Duration(seconds: 1));
      expect(dashboard.selectedAgent?.uuid, 'a2');
      expect(dashboard.settings.destination, MainPanelDestination.agent);
    });

    testWidgets('only the agents of the chat workspace and the account show', (
      WidgetTester tester,
    ) async {
      dashboard.activeWorkspace = const Workspace(uuid: 'w1', name: 'One');
      expect(dashboard.visibleAgents.map((AgentInfo a) => a.uuid), <String>[
        'a1',
        'a2',
      ]);
    });
  });

  group('Agent form', () {
    testWidgets('shows the selected agent in kit fields', (
      WidgetTester tester,
    ) async {
      useScreen(tester, const Size(900, 900));
      dashboard.selectedAgent = _agents.first;
      await tester.pumpWidget(_app(AgentMainPanel(controller: dashboard)));
      await tester.pump();
      expect(find.text('Edit agent'), findsOneWidget);
      expect(find.byType(AppTextField), findsWidgets);
      expect(find.widgetWithText(AppTextField, 'Name'), findsOneWidget);
      final EditableText name = tester.widget<EditableText>(
        find.byType(EditableText).first,
      );
      expect(name.controller.text, 'Researcher');
      expect(find.text('Available in'), findsOneWidget);
      expect(find.byType(AppSwitchTile), findsWidgets);
      expect(find.byTooltip('Delete agent'), findsOneWidget);
    });

    testWidgets('creating shows an empty form with cancel and create', (
      WidgetTester tester,
    ) async {
      useScreen(tester, const Size(900, 900));
      dashboard.isCreatingAgent = true;
      await tester.pumpWidget(_app(AgentMainPanel(controller: dashboard)));
      await tester.pump();
      expect(find.text('New agent'), findsOneWidget);
      expect(find.byTooltip('Cancel agent creation'), findsOneWidget);
      expect(find.byTooltip('Create agent'), findsOneWidget);
      expect(find.byTooltip('Delete agent'), findsNothing);
    });

    testWidgets('without a selection it asks to choose one', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_app(AgentMainPanel(controller: dashboard)));
      expect(find.textContaining('Select an agent'), findsOneWidget);
    });
  });

  group('Chat header', () {
    Widget chat({bool listVisible = false, VoidCallback? onToggle}) =>
        _app(
          EngineChatPanel(
            provider: EngineLlmProvider(),
            isComposerEnabled: false,
            title: 'Trip plans',
            threadsList: const Text('THREAD LIST'),
            threadsListVisible: listVisible,
            onToggleThreadsList: onToggle,
          ),
        );

    testWidgets('the name is a settings button and threads replace "more"', (
      WidgetTester tester,
    ) async {
      useScreen(tester, const Size(500, 800));
      int toggled = 0;
      await tester.pumpWidget(chat(onToggle: () => toggled++));
      expect(find.text('Trip plans'), findsOneWidget);
      expect(find.byTooltip('Thread settings'), findsOneWidget);
      expect(find.byTooltip('Threads'), findsOneWidget);
      expect(find.byTooltip('New thread'), findsOneWidget);
      expect(find.byType(AppListRow), findsOneWidget);
      expect(find.text('THREAD LIST'), findsNothing);

      await tester.tap(find.byTooltip('Threads'));
      expect(toggled, 1);
    });

    testWidgets('the thread list replaces the conversation and composer', (
      WidgetTester tester,
    ) async {
      useScreen(tester, const Size(500, 800));
      await tester.pumpWidget(chat(listVisible: true, onToggle: () {}));
      expect(find.text('THREAD LIST'), findsOneWidget);
      expect(find.byTooltip('Close threads'), findsOneWidget);
      expect(find.byType(EditableText), findsNothing);
    });

    testWidgets('without a thread list there is no threads button', (
      WidgetTester tester,
    ) async {
      useScreen(tester, const Size(500, 800));
      await tester.pumpWidget(
        _app(
          EngineChatPanel(
            provider: EngineLlmProvider(),
            isComposerEnabled: false,
          ),
        ),
      );
      expect(find.byTooltip('Threads'), findsNothing);
    });
  });
}
