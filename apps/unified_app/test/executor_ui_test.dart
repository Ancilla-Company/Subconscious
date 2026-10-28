import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/chat/engine_llm_provider.dart';
import 'package:unified_app/features/chat/presentation/executor_widgets.dart';
import 'package:unified_app/features/hive/executor_selection.dart';

final class _Link implements PeerLink {
  final StreamController<InboundEnvelope> inbound =
      StreamController<InboundEnvelope>.broadcast();
  final List<Envelope> sent = <Envelope>[];
  final Completer<void> _done = Completer<void>();
  void Function(Envelope e)? script;

  @override
  String get remoteNodeId => 'n_home';
  @override
  String get tier => 'direct';
  @override
  bool get isOpen => !_done.isCompleted;
  @override
  Stream<InboundEnvelope> get envelopes => inbound.stream;
  @override
  Future<void> get done => _done.future;

  @override
  Future<void> send(String channel, Envelope envelope) async {
    sent.add(envelope);
    scheduleMicrotask(() {
      if (envelope.type == 'client.hello') {
        receive(
          'control',
          Envelope(
            type: 'client.hello.ack',
            id: envelope.id,
            data: const <String, dynamic>{},
          ),
        );
      } else {
        script?.call(envelope);
      }
    });
  }

  void receive(String channel, Envelope e) =>
      inbound.add(InboundEnvelope(channel, e));

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }
}

Map<String, dynamic> task(String status, {String? error}) => <String, dynamic>{
  'task_id': 't1',
  'thread_uuid': 'th1',
  'executor_node_id': 'n_laptop',
  'status': status,
  'error': error,
};

Future<(EngineLlmProvider, _Link)> providerOver() async {
  final _Link link = _Link();
  final EngineRepository repository = EngineRepository(
    rest: RestEngineClient(
      baseUri: Uri.parse('http://peer/api/v1/'),
      token: '',
    ),
    socket: PeerEngineSocket(linkProvider: () async => link),
  );
  await repository.connect();
  final EngineLlmProvider provider = EngineLlmProvider(
    repository: repository,
    threadUuid: 'th1',
  )..nodeNameOf = ((String id) => id == 'n_laptop' ? 'Work laptop' : null);
  return (provider, link);
}

final class _Directory extends ChangeNotifier implements ExecutorDirectory {
  _Directory(this.options);
  @override
  List<ExecutorOption> options;
  @override
  String? nameOf(String nodeId) =>
      options.where((ExecutorOption o) => o.nodeId == nodeId).firstOrNull?.name;
  @override
  Future<String?> loadSelection(String threadUuid) async => null;
  @override
  Future<void> saveSelection(String threadUuid, String? nodeId) async {}
}

const ExecutorOption _home = ExecutorOption(
  nodeId: null,
  name: 'Desktop (home)',
  platform: 'windows',
  tier: 'direct',
);
const ExecutorOption _laptop = ExecutorOption(
  nodeId: 'n_laptop',
  name: 'Work laptop',
  platform: 'macos',
  tier: 'ws-relay',
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  test('executor choice is stored per thread on this device', () async {
    final SecureExecutorPreferenceStore store = SecureExecutorPreferenceStore(
      const FlutterSecureStorage(),
    );
    expect(await store.read('th1'), isNull);
    await store.write('th1', 'n_laptop');
    await store.write('th2', 'n_other');
    expect(await store.read('th1'), 'n_laptop');
    expect(await store.read('th2'), 'n_other');
    await store.write('th1', null);
    expect(await store.read('th1'), isNull);
    expect(await store.read('th2'), 'n_other');
  });

  testWidgets(
    'the picker lists name, platform and tier and reports the choice',
    (WidgetTester tester) async {
      final (EngineLlmProvider provider, _) = await providerOver();
      final _Directory directory = _Directory(<ExecutorOption>[_home, _laptop]);
      String? chosen = 'unset';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExecutorPicker(
              provider: provider,
              directory: directory,
              onSelected: (String? id) => chosen = id,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey<String>('executor-picker')));
      await tester.pumpAndSettle();
      expect(find.text('Desktop (home)'), findsOneWidget);
      expect(find.text('windows \u00b7 direct'), findsOneWidget);
      expect(find.text('Work laptop'), findsOneWidget);
      expect(find.text('macos \u00b7 ws-relay'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('executor-n_laptop')));
      await tester.pumpAndSettle();
      expect(chosen, 'n_laptop');
    },
  );

  testWidgets('the picker is hidden when there is nothing to choose', (
    WidgetTester tester,
  ) async {
    final (EngineLlmProvider provider, _) = await providerOver();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExecutorPicker(
            provider: provider,
            directory: _Directory(<ExecutorOption>[_home]),
            onSelected: (String? _) {},
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey<String>('executor-picker')), findsNothing);
  });

  test(
    'a remote executor message runs as a task and badges the reply',
    () async {
      final (EngineLlmProvider provider, _Link link) = await providerOver();
      link.script = (Envelope e) {
        if (e.type != 'task.submit') return;
        expect(e.dataMap!['executor'], 'n_laptop');
        expect(e.dataMap!['thread_uuid'], 'th1');
        link.receive(
          'control',
          Envelope(type: 'task.accepted', id: e.id, data: task('queued')),
        );
        link.receive(
          'control',
          Envelope(type: 'task.status', id: 't1', data: task('running')),
        );
        link.receive(
          'events',
          Envelope(
            type: 'chat.delta',
            id: 't1',
            data: const <String, dynamic>{'delta': 'Hi '},
          ),
        );
        link.receive(
          'events',
          Envelope(
            type: 'chat.delta',
            id: 't1',
            data: const <String, dynamic>{'delta': 'there'},
          ),
        );
        link.receive(
          'control',
          Envelope(type: 'task.status', id: 't1', data: task('done')),
        );
      };
      provider.selectExecutor('n_laptop');
      final List<String> deltas = await provider
          .sendMessageStream('hello')
          .toList();
      expect(deltas.join(), 'Hi there');
      expect(provider.taskStatus, TaskStatus.done);
      expect(provider.history.last.text, 'Hi there');
      expect(provider.history.last.ranOn, 'Work laptop');
      expect(provider.ranOnLabel, 'Work laptop');
      expect(link.sent.any((Envelope e) => e.type == 'chat.send'), isFalse);
    },
  );

  test('without an executor the existing chat path is used', () async {
    final (EngineLlmProvider provider, _Link link) = await providerOver();
    link.script = (Envelope e) {
      if (e.type != 'chat.send') return;
      link.receive(
        'events',
        Envelope(
          type: 'chat.delta',
          id: e.id,
          data: const <String, dynamic>{'delta': 'ok'},
        ),
      );
      link.receive(
        'events',
        Envelope(type: 'chat.done', id: e.id, data: const <String, dynamic>{}),
      );
    };
    final List<String> deltas = await provider
        .sendMessageStream('hello')
        .toList();
    expect(deltas.join(), 'ok');
    expect(provider.taskStatus, isNull);
    expect(link.sent.any((Envelope e) => e.type == 'task.submit'), isFalse);
  });

  test('a failed task keeps its error and marks the state failed', () async {
    final (EngineLlmProvider provider, _Link link) = await providerOver();
    link.script = (Envelope e) {
      if (e.type != 'task.submit') return;
      link.receive(
        'control',
        Envelope(type: 'task.accepted', id: e.id, data: task('running')),
      );
      link.receive(
        'control',
        Envelope(
          type: 'task.status',
          id: 't1',
          data: task('failed', error: 'model missing'),
        ),
      );
    };
    provider.selectExecutor('n_laptop');
    await expectLater(
      provider.sendMessageStream('hello').toList(),
      throwsStateError,
    );
    expect(provider.taskStatus, TaskStatus.failed);
    expect(provider.taskError, 'model missing');
  });

  testWidgets(
    'the status bar shows state and node, and cancel sends task.cancel',
    (WidgetTester tester) async {
      final (EngineLlmProvider provider, _Link link) = await providerOver();
      provider
        ..taskStatus = TaskStatus.running
        ..activeTaskId = 't1'
        ..taskExecutorNodeId = 'n_laptop';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TaskStatusBar(provider: provider)),
        ),
      );
      expect(find.text('Running on Work laptop'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('task-cancel')));
      await tester.pump();
      final Envelope cancel = link.sent.firstWhere(
        (Envelope e) => e.type == 'task.cancel',
      );
      expect(cancel.dataMap!['task_id'], 't1');

      for (final (TaskStatus status, String label) in <(TaskStatus, String)>[
        (TaskStatus.queued, 'Queued on Work laptop'),
        (TaskStatus.waitingApproval, 'Waiting for approval on Work laptop'),
        (TaskStatus.done, 'Done on Work laptop'),
        (TaskStatus.cancelled, 'Cancelled on Work laptop'),
        (TaskStatus.interrupted, 'Interrupted on Work laptop'),
      ]) {
        provider.taskStatus = status;
        provider.bindThread('th1'); // notifies listeners
        await tester.pump();
        expect(find.text(label), findsOneWidget, reason: '$status');
      }
      expect(
        find.byKey(const ValueKey<String>('task-cancel')),
        findsNothing,
        reason: 'finished tasks cannot be cancelled',
      );
    },
  );
}
