import 'dart:convert';
import 'dart:typed_data';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unified_app/features/account/account_controller.dart';
import 'package:unified_app/features/dashboard/controller/dashboard_controller.dart';
import 'package:unified_app/features/dashboard/presentation/window_caption_widgets.dart';
import 'package:unified_app/features/hive/engine_card_view.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';
import 'package:unified_app/features/hive/presentation/nodes_page.dart';

const Map<String, dynamic> _loginBody = <String, dynamic>{
  'access_token': 'a',
  'token_type': 'bearer',
  'expires_in': 900,
  'refresh_token': 'r',
  'user': <String, dynamic>{
    'id': 'u-1',
    'email': 'a@b.c',
    'display_name': 'A',
    'avatar_url': null,
    'connected_providers': <String>[],
  },
};

NodeView _engine(String id, {bool online = true}) => NodeView(
  node: DirectoryNode(
    id: id,
    kind: 'engine',
    name: 'Engine $id',
    platform: 'windows',
    appVersion: '',
    publicKey: Uint8List(32),
    status: 'active',
    online: online,
  ),
  trusted: true,
  online: online,
  isLocal: false,
);

Future<HiveRuntime> _runtime() async {
  final HiveRuntime runtime = HiveRuntime(
    account: ServerAccountClient(
      baseUri: Uri.parse('https://api.test'),
      tokenStore: MemoryRefreshTokenStore(),
      client: MockClient(
        (http.Request r) async => http.Response(jsonEncode(_loginBody), 200),
      ),
    ),
  );
  await runtime.account.loginWithEmail(email: 'a@b.c', password: 'password1');
  return runtime;
}

Future<EngineRepository?> _noEngine({
  Uri? explicitEndpoint,
  String? explicitToken,
}) async => null;

void _singleSourceOfTruthTests() {
  test(
    'the card never says connected while the dashboard session is down',
    () async {
      final HiveRuntime runtime = await _runtime();
      runtime.engineState = EngineLinkState.connected;
      runtime.homeEngineId = 'e1';
      runtime.engineSessionUp = () => false;
      expect(runtime.engineState, EngineLinkState.failed);
      expect(engineCardViewFor(runtime).title, isNot(startsWith('Connected')));
      runtime.engineSessionUp = () => true;
      expect(runtime.engineState, EngineLinkState.connected);
    },
  );
}

/// `label:enabled` for every button under [root], in tree order.
List<String> _buttons(Finder root) {
  final List<String> seen = <String>[];
  for (final Element element
      in find
          .descendant(
            of: root,
            matching: find.byWidgetPredicate(
              (Widget w) =>
                  w is FilledButton || w is OutlinedButton || w is TextButton,
            ),
          )
          .evaluate()) {
    final Widget w = element.widget;
    final Text label =
        find
                .descendant(of: find.byWidget(w), matching: find.byType(Text))
                .evaluate()
                .first
                .widget
            as Text;
    final bool enabled = switch (w) {
      final FilledButton b => b.onPressed != null,
      final OutlinedButton b => b.onPressed != null,
      final TextButton b => b.onPressed != null,
      _ => false,
    };
    seen.add('${label.data}:$enabled');
  }
  return seen;
}

/// A card state: how to put the runtime there, and the buttons expected as
/// `label:enabled`.
final class _Case {
  const _Case(
    this.name,
    this.setup,
    this.buttons, {
    this.absent = const <String>[],
  });
  final String name;
  final void Function(HiveRuntime runtime) setup;
  final List<String> buttons;
  final List<String> absent;
}

void main() {
  _singleSourceOfTruthTests();
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  Future<void> pump(WidgetTester tester, HiveRuntime runtime) async {
    final AccountController account = AccountController(
      session: runtime,
      clientProvider: () => null,
      thinClient: true,
    );
    addTearDown(account.dispose);
    await tester.runAsync(account.restoreSession);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: DevicesSection(account: account)),
        ),
      ),
    );
    await tester.pump();
  }

  final List<_Case> cases = <_Case>[
    _Case(
      'connected',
      (HiveRuntime r) {
        r.nodes = <NodeView>[_engine('a')];
        r.homeEngineId = 'a';
        r.engineState = EngineLinkState.connected;
      },
      <String>['Disconnect:true'],
      absent: <String>['Connect', 'Reconnect'],
    ),
    _Case(
      'connecting',
      (HiveRuntime r) {
        r.nodes = <NodeView>[_engine('a')];
        r.engineState = EngineLinkState.connecting;
      },
      <String>['Cancel:true'],
      absent: <String>['Connect', 'Disconnect'],
    ),
    _Case('failed, candidate', (HiveRuntime r) {
      r.nodes = <NodeView>[_engine('a')];
      r.engineState = EngineLinkState.failed;
    }, <String>['Retry:true', 'Pause:true']),
    _Case('failed, no candidate', (HiveRuntime r) {
      r.nodes = <NodeView>[_engine('a', online: false)];
      r.engineState = EngineLinkState.failed;
    }, <String>['Connect:false', 'Pause:true']),
    _Case('failed, paused, candidate', (HiveRuntime r) {
      r.nodes = <NodeView>[_engine('a')];
      r.engineState = EngineLinkState.failed;
      r.autoConnect = false;
    }, <String>['Connect:true']),
    _Case('failed, paused, no candidate', (HiveRuntime r) {
      r.nodes = <NodeView>[_engine('a', online: false)];
      r.engineState = EngineLinkState.failed;
      r.autoConnect = false;
    }, <String>['Connect:false']),
    _Case(
      'disconnected, single candidate',
      (HiveRuntime r) {
        r.nodes = <NodeView>[_engine('a')];
      },
      <String>['Cancel:true'],
      absent: <String>['Connect'],
    ),
    _Case('disconnected, several (pick)', (HiveRuntime r) {
      r.nodes = <NodeView>[_engine('a'), _engine('b')];
    }, <String>['Pause:true']),
    _Case('disconnected, none, after hysteresis', (HiveRuntime r) {
      r.nodes = <NodeView>[_engine('a', online: false)];
    }, <String>['Connect:false']),
    _Case('disconnected, paused, candidate', (HiveRuntime r) {
      r.nodes = <NodeView>[_engine('a')];
      r.autoConnect = false;
    }, <String>['Connect:true']),
    _Case('disconnected, paused, no candidate', (HiveRuntime r) {
      r.nodes = <NodeView>[_engine('a', online: false)];
      r.autoConnect = false;
    }, <String>['Connect:false']),
  ];

  for (final _Case c in cases) {
    testWidgets('engine card: ${c.name}', (WidgetTester tester) async {
      final HiveRuntime runtime = (await tester.runAsync(_runtime))!;
      addTearDown(runtime.dispose);
      c.setup(runtime);
      await pump(tester, runtime);
      final Finder card = find.byKey(const ValueKey<String>('engine-card'));
      expect(card, findsOneWidget);

      final List<String> inCard = _buttons(card);
      expect(inCard, c.buttons, reason: 'card buttons: $inCard');
      for (final String label in c.absent) {
        expect(
          _buttons(find.byType(DevicesSection))
              .any((String s) => s.startsWith('$label:')),
          isFalse,
          reason: '$label must not be visible anywhere',
        );
      }
    });
  }

  testWidgets(
    'a disabled Connect shows its caption and uses the disabled style',
    (WidgetTester tester) async {
      final HiveRuntime runtime = (await tester.runAsync(_runtime))!;
      addTearDown(runtime.dispose);
      runtime.nodes = <NodeView>[_engine('a', online: false)];
      await pump(tester, runtime);
      expect(
        find.text(
          'No engine is online. This device connects as soon as one appears.',
        ),
        findsOneWidget,
      );
      final FilledButton connect = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Connect'),
      );
      expect(connect.onPressed, isNull);
    },
  );

  testWidgets('the pick row keeps one enabled Connect per engine tile', (
    WidgetTester tester,
  ) async {
    final HiveRuntime runtime = (await tester.runAsync(_runtime))!;
    addTearDown(runtime.dispose);
    runtime.nodes = <NodeView>[_engine('a'), _engine('b')];
    await pump(tester, runtime);
    expect(find.text('Choose an engine'), findsOneWidget);
    final List<String> all = _buttons(find.byType(DevicesSection));
    expect(all.where((String s) => s == 'Connect:true'), hasLength(2));
    expect(find.widgetWithText(TextButton, 'Pause'), findsOneWidget);
  });

  testWidgets('the connecting card shows a progress bar', (
    WidgetTester tester,
  ) async {
    final HiveRuntime runtime = (await tester.runAsync(_runtime))!;
    addTearDown(runtime.dispose);
    runtime.nodes = <NodeView>[_engine('a')];
    runtime.engineState = EngineLinkState.connecting;
    await pump(tester, runtime);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  test(
    'the title chip is amber, never disconnected, while the card connects',
    () async {
      final HiveRuntime runtime = await _runtime();
      addTearDown(runtime.dispose);
      final DashboardController dashboard = DashboardController(_noEngine)
        ..connectionStatus = EngineConnectionStatus.disconnected;
      addTearDown(dashboard.dispose);

      runtime.nodes = <NodeView>[_engine('a')];
      runtime.engineState = EngineLinkState.connecting;
      final (AppStatus, String) connecting = captionPresentation(
        dashboard.connectionStatus,
        runtime,
      );
      expect(connecting.$2, 'connecting');
      expect(connecting.$1, AppStatus.connecting);

      runtime.engineState = EngineLinkState.disconnected;
      runtime.nodes = <NodeView>[_engine('a', online: false)];
      runtime.autoConnect = false;
      expect(
        captionPresentation(dashboard.connectionStatus, runtime).$2,
        'disconnected',
      );

      runtime.linkingLocalEngine = true;
      expect(
        captionPresentation(dashboard.connectionStatus, runtime).$2,
        'starting engine',
      );

      dashboard.connectionStatus = EngineConnectionStatus.connected;
      expect(
        captionPresentation(dashboard.connectionStatus, runtime).$2,
        'connected',
      );
    },
  );
}
