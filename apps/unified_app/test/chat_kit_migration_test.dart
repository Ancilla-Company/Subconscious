import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';
import 'package:unified_app/features/chat/engine_llm_provider.dart';
import 'package:unified_app/features/chat/presentation/engine_chat_panel.dart';
import 'package:unified_app/features/tools/presentation/tool_policy_list.dart';

EngineLlmProvider _provider() {
  final EngineRepository repository = EngineRepository(
    rest: RestEngineClient(
      baseUri: Uri.parse('http://peer/api/v1/'),
      token: '',
    ),
    socket: PeerEngineSocket(linkProvider: () async => throw StateError('x')),
  );
  return EngineLlmProvider(repository: repository)
    ..history = <EngineChatMessage>[
      EngineChatMessage.user('hello there'),
      EngineChatMessage.assistant('cached reply'),
      EngineChatMessage.system('engine restarted'),
    ];
}

Widget _app(
  Widget body, {
  Brightness brightness = Brightness.light,
  ThemeData? theme,
}) => MaterialApp(
  theme: theme ?? ThemeData(brightness: brightness),
  home: Scaffold(body: body),
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  group('chat panel uses kit widgets', () {
    for (final Brightness brightness in Brightness.values) {
      testWidgets('message roles render through AppMessageBubble '
          '(${brightness.name})', (WidgetTester tester) async {
        await tester.pumpWidget(
          _app(
            EngineChatPanel(provider: _provider(), isComposerEnabled: true),
            brightness: brightness,
          ),
        );
        final List<AppMessageBubble> bubbles = tester
            .widgetList<AppMessageBubble>(find.byType(AppMessageBubble))
            .toList();
        expect(bubbles.map((AppMessageBubble b) => b.role), <AppMessageRole>[
          AppMessageRole.user,
          AppMessageRole.assistant,
          AppMessageRole.system,
        ]);
        // The assistant answer is unboxed.
        expect(bubbles[1].boxed, isFalse);
        expect(bubbles[0].boxed, isTrue);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('composer controls are AppIconButtons, 48dp on mobile', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _app(
          EngineChatPanel(
            provider: _provider(),
            isComposerEnabled: true,
            borderlessComposer: true,
            minTouchTarget: 48,
          ),
        ),
      );
      for (final String tooltip in <String>['Attach files', 'Send']) {
        final Finder button = find.ancestor(
          of: find.byTooltip(tooltip),
          matching: find.byType(AppIconButton),
        );
        expect(button, findsOneWidget, reason: tooltip);
        final Size size = tester.getSize(button);
        expect(size.width, greaterThanOrEqualTo(48), reason: tooltip);
        expect(size.height, greaterThanOrEqualTo(48), reason: tooltip);
      }
    });

    testWidgets('desktop composer controls stay compact (32dp)', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _app(EngineChatPanel(provider: _provider(), isComposerEnabled: true)),
      );
      final Finder send = find.ancestor(
        of: find.byTooltip('Send'),
        matching: find.byType(AppIconButton),
      );
      expect(tester.getSize(send), const Size(32, 32));
    });
  });

  group('tool approval banner at 360dp', () {
    ToolApprovalRequest request({
      String operation = 'execute',
      bool remote = false,
    }) => ToolApprovalRequest(
      turnId: 't',
      approvalId: 'ap1',
      threadUuid: 'th',
      toolName: 'run_shell_command_with_a_long_name',
      arguments: <String, dynamic>{'command': 'echo ' * 60, 'cwd': '/a/b/c'},
      operation: operation,
      remote: remote,
      peerName: 'Living-room laptop',
    );

    for (final Brightness brightness in Brightness.values) {
      for (final bool remote in <bool>[false, true]) {
        testWidgets('execute approval is visible and usable '
            '(${brightness.name}, remote: $remote)', (
          WidgetTester tester,
        ) async {
          tester.view.physicalSize = const Size(360 * 3, 800 * 3);
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.reset);
          bool? decision;
          await tester.pumpWidget(
            _app(
              EngineChatPanel(
                provider: _provider(),
                isComposerEnabled: true,
                borderlessComposer: true,
                minTouchTarget: 48,
                toolApproval: request(remote: remote),
                onToolApproval: (bool approved) => decision = approved,
              ),
              brightness: brightness,
            ),
          );
          expect(tester.takeException(), isNull);
          expect(find.byType(AppBanner), findsOneWidget);
          expect(
            find.text('Approval required: run_shell_command_with_a_long_name'),
            findsOneWidget,
          );
          expect(find.textContaining('Run: '), findsOneWidget);
          if (remote) {
            expect(
              find.byKey(const ValueKey<String>('remote-approval-peer')),
              findsOneWidget,
            );
          }
          final Finder approve = find.text('Approve once');
          expect(approve, findsOneWidget);
          // Fully on screen on a 360dp phone.
          final Rect rect = tester.getRect(approve);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(360));
          expect(rect.bottom, lessThanOrEqualTo(800));
          await tester.tap(approve);
          expect(decision, isTrue);
          await tester.tap(find.text('Deny'));
          expect(decision, isFalse);
        });
      }
    }
  });

  group('ToolPolicyList', () {
    ToolCatalog catalog() => ToolCatalog(
      builtin: <String, List<BuiltinToolCatalogEntry>>{
        'file_system': <BuiltinToolCatalogEntry>[
          const BuiltinToolCatalogEntry(
            name: 'read_file',
            doc: 'Read a file',
            operation: 'read',
          ),
        ],
      },
      configured: const <ToolRegistryEntry>[],
    );

    Widget host({
      required bool editable,
      required List<String> log,
      ToolCatalog? cat,
    }) => _app(
      SingleChildScrollView(
        child: ToolPolicyList(
          catalog: cat,
          editable: editable,
          builtinEnabled: true,
          configuredEnabled: true,
          builtinGroups: const <String, bool>{'file_system': true},
          builtinTools: const <String, Map<String, bool>>{
            'file_system': <String, bool>{'read_file': true},
          },
          configuredTools: const <String, bool>{},
          onBuiltinEnabled: (bool v) => log.add('builtin:$v'),
          onConfiguredEnabled: (bool v) => log.add('custom:$v'),
          onGroupChanged: (String g, bool v) => log.add('group:$g:$v'),
          onBuiltinToolChanged: (String g, String t, bool v) =>
              log.add('tool:$g:$t:$v'),
          onConfiguredToolChanged: (String u, bool v) => log.add('cfg:$u:$v'),
        ),
      ),
    );

    testWidgets('lists groups and tools and reports every change', (
      WidgetTester tester,
    ) async {
      final List<String> log = <String>[];
      await tester.pumpWidget(host(editable: true, log: log, cat: catalog()));
      expect(find.byType(AppSectionCard), findsNWidgets(2));
      expect(find.text('Builtin Tools'), findsOneWidget);
      expect(find.text('Custom Tools'), findsOneWidget);
      expect(find.text('File System'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Enable built-in tools'));
      await tester.tap(find.bySemanticsLabel('Enable File System tools'));
      expect(log, <String>['builtin:false', 'group:file_system:false']);

      // Expand the group, then flip a tool by its switch and by its row.
      await tester.tap(find.text('File System'));
      await tester.pumpAndSettle();
      expect(find.text('Read File'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Enable Read File'));
      await tester.tap(find.text('Read File'));
      expect(log.skip(2), <String>[
        'tool:file_system:read_file:false',
        'tool:file_system:read_file:false',
      ]);
    });

    testWidgets('read-only disables every switch', (WidgetTester tester) async {
      final List<String> log = <String>[];
      await tester.pumpWidget(host(editable: false, log: log, cat: catalog()));
      await tester.tap(find.bySemanticsLabel('Enable built-in tools'));
      await tester.tap(find.bySemanticsLabel('Enable custom tools'));
      expect(log, isEmpty);
    });

    testWidgets('empty catalog says so and fits 320dp', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host(editable: true, log: <String>[]));
      expect(find.text('No built-in tools are available.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Custom Tools'));
      await tester.pumpAndSettle();
      expect(find.text('No custom tools are configured.'), findsOneWidget);
    });
  });
}
