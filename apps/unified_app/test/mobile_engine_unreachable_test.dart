import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/chat/engine_llm_provider.dart';
import 'package:unified_app/features/chat/presentation/engine_chat_panel.dart';

EngineLlmProvider _provider() {
  final EngineRepository repository = EngineRepository(
    rest: RestEngineClient(baseUri: Uri.parse('http://peer/api/v1/'), token: ''),
    socket: PeerEngineSocket(linkProvider: () async => throw StateError('x')),
  );
  return EngineLlmProvider(repository: repository)
    ..history = <EngineChatMessage>[
      EngineChatMessage.user('hello there'),
      EngineChatMessage.assistant('cached reply'),
    ];
}

Widget _app(
  EngineLlmProvider provider, {
  required bool connected,
  required VoidCallback onDevices,
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  theme: ThemeData(brightness: brightness),
  home: Scaffold(
    body: EngineChatPanel(
      provider: provider,
      isComposerEnabled: connected,
      onOpenDevices: onDevices,
    ),
  ),
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  for (final Brightness brightness in Brightness.values) {
    testWidgets('unreachable engine keeps messages, disables composer '
        '(${brightness.name})', (WidgetTester tester) async {
      final EngineLlmProvider provider = _provider();
      int opened = 0;
      await tester.pumpWidget(
        _app(
          provider,
          connected: false,
          onDevices: () => opened++,
          brightness: brightness,
        ),
      );
      expect(find.text('hello there'), findsOneWidget);
      expect(find.text('cached reply'), findsOneWidget);
      expect(find.text('No engine is reachable'), findsOneWidget);
      final TextField input = tester.widget<TextField>(
        find.byType(TextField).last,
      );
      expect(input.enabled, isFalse);
      await tester.tap(find.text('Devices'));
      expect(opened, 1);
    });
  }

  testWidgets('reconnect re-enables the composer and hides the notice', (
    WidgetTester tester,
  ) async {
    final EngineLlmProvider provider = _provider();
    await tester.pumpWidget(
      _app(provider, connected: false, onDevices: () {}),
    );
    expect(find.text('No engine is reachable'), findsOneWidget);
    await tester.pumpWidget(_app(provider, connected: true, onDevices: () {}));
    await tester.pump();
    expect(find.text('No engine is reachable'), findsNothing);
    expect(find.text('hello there'), findsOneWidget);
    final TextField input = tester.widget<TextField>(
      find.byType(TextField).last,
    );
    expect(input.enabled, isTrue);
  });
}
