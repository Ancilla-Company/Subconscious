import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:test/test.dart';

import 'hive/peer_connector_test.dart' show until;
import 'hive/peer_engine_socket_test.dart' show FakeLink;

Map<String, dynamic> taskJson(
  String id,
  String status, {
  String? executor,
  String? error,
}) => <String, dynamic>{
  'task_id': id,
  'thread_uuid': 'th1',
  'workspace_uuid': null,
  'executor_node_id': executor ?? 'n_exec',
  'requester_node_id': 'n_me',
  'status': status,
  'rev': 1,
  'turn_id': id,
  'model_id': null,
  'client_msg_uuid': 'cm',
  'created_at': '2025-01-01T00:00:00+00:00',
  'started_at': null,
  'finished_at': null,
  'error': error,
};

WireFrame frame(String type, String? id, Map<String, dynamic> data) =>
    WireFrame(type: type, id: id, data: data);

/// Fake engine behind a [FakeLink]: acks the hello and runs [script] for
/// every `task.submit`.
FakeLink engineLink(void Function(FakeLink link, Envelope submit) script) {
  final FakeLink link = FakeLink();
  link.onSend = (String channel, Envelope e) {
    Future<void>.microtask(() {
      if (e.type == 'client.hello') {
        link.receive('control', Envelope(type: 'client.hello.ack', id: e.id, data: const <String, dynamic>{}));
      } else if (e.type == 'task.submit') {
        script(link, e);
      }
    });
  };
  return link;
}

EngineRepository repositoryOver(FakeLink link) => EngineRepository(
  rest: RestEngineClient(baseUri: Uri.parse('http://peer/api/v1/'), token: ''),
  socket: PeerEngineSocket(linkProvider: () async => link),
);

void main() {
  group('parseTaskEvent', () {
    test('task.accepted carries the submit id and the task row', () {
      final TaskEvent? event = parseTaskEvent(frame('task.accepted', 's1', taskJson('t1', 'queued')));
      expect(event, isA<TaskAccepted>());
      final TaskAccepted accepted = event! as TaskAccepted;
      expect(accepted.submitId, 's1');
      expect(accepted.task.taskId, 't1');
      expect(accepted.task.status, TaskStatus.queued);
      expect(accepted.task.executorNodeId, 'n_exec');
    });

    test('task.status maps every status including waiting_approval', () {
      for (final (String wire, TaskStatus status) in <(String, TaskStatus)>[
        ('queued', TaskStatus.queued),
        ('running', TaskStatus.running),
        ('waiting_approval', TaskStatus.waitingApproval),
        ('done', TaskStatus.done),
        ('failed', TaskStatus.failed),
        ('cancelled', TaskStatus.cancelled),
        ('interrupted', TaskStatus.interrupted),
      ]) {
        final TaskEvent? event = parseTaskEvent(frame('task.status', 't1', taskJson('t1', wire)));
        expect((event! as TaskStatusChanged).task.status, status);
        expect(status.wireName, wire);
      }
      expect(TaskStatus.done.isTerminal, isTrue);
      expect(TaskStatus.waitingApproval.isTerminal, isFalse);
      expect(TaskStatus.parse('weird'), TaskStatus.unknown);
    });

    test('task.error, chat.delta/done/error/cancelled are keyed by task id', () {
      final TaskRejected rejected = parseTaskEvent(
        frame('task.error', 's1', <String, dynamic>{'error': 'nope', 'client_msg_uuid': 'cm'}),
      )! as TaskRejected;
      expect((rejected.error, rejected.submitId, rejected.clientMsgUuid), ('nope', 's1', 'cm'));

      expect(
        (parseTaskEvent(frame('chat.delta', 't1', <String, dynamic>{'thread_uuid': 'th1', 'delta': 'x'}))! as TaskDelta).taskId,
        't1',
      );
      expect(parseTaskEvent(frame('chat.done', 't1', <String, dynamic>{'thread_uuid': 'th1'})), isA<TaskChatDone>());
      expect(
        (parseTaskEvent(frame('chat.error', 't1', <String, dynamic>{'error': 'boom'}))! as TaskChatError).error,
        'boom',
      );
      expect(parseTaskEvent(frame('chat.cancelled', 't1', const <String, dynamic>{})), isA<TaskChatCancelled>());
      expect(parseTaskEvent(frame('chat.delta', null, <String, dynamic>{'delta': 'x'})), isNull);
      expect(parseTaskEvent(frame('thread.subscribed', null, <String, dynamic>{'thread_uuid': 'th1'})), isA<ThreadSubscribed>());
      expect(parseTaskEvent(frame('something.else', 't1', const <String, dynamic>{})), isNull);
      expect(parseTaskEvent(frame('task.status', 't1', <String, dynamic>{'status': 'done'})), isNull, reason: 'no task_id');
    });

    test('a remote tool approval request carries the peer and operation', () {
      final ToolApprovalRequested event = parseTaskEvent(
        frame('tool.approval.request', 't9', <String, dynamic>{
          'approval_id': 'a1',
          'remote': true,
          'peer_node_id': 'n_peer',
          'peer_name': 'Work laptop',
          'tool_name': 'read_filesystem_file',
          'arguments': <String, dynamic>{'path': 'D:\\shared\\a.txt'},
          'task_id': 't9',
          'operation': 'read',
        }),
      )! as ToolApprovalRequested;
      final ToolApprovalRequest request = event.request;
      expect(request.remote, isTrue);
      expect(request.peerName, 'Work laptop');
      expect(request.peerNodeId, 'n_peer');
      expect(request.operation, 'read');
      expect(request.toolName, 'read_filesystem_file');
      expect(request.approvalId, 'a1');
      expect(request.turnId, 't9');
      expect(event.taskId, 't9');
    });

    test('a local approval request is not remote and missing fields are rejected', () {
      final ToolApprovalRequested local = parseTaskEvent(
        frame('tool.approval.request', 'turn1', <String, dynamic>{
          'approval_id': 'a2',
          'thread_uuid': 'th1',
          'tool_name': 'write',
          'arguments': <String, dynamic>{},
        }),
      )! as ToolApprovalRequested;
      expect(local.request.remote, isFalse);
      expect(local.request.peerName, isNull);
      expect(local.request.operation, 'update');
      expect(parseTaskEvent(frame('tool.approval.request', 't', <String, dynamic>{'approval_id': 'a'})), isNull);
    });

    test('tool.approval.resolved identifies the prompt to dismiss', () {
      final ToolApprovalResolved event = parseTaskEvent(
        frame('tool.approval.resolved', 't9', <String, dynamic>{'approval_id': 'a1', 'decision': 'deny'}),
      )! as ToolApprovalResolved;
      expect((event.approvalId, event.decision, event.taskId), ('a1', 'deny', 't9'));
    });
  });

  group('task submit payload', () {
    test('matches the engine parser: one of thread/workspace, optional fields', () {
      final Map<String, dynamic> data = buildTaskSubmitData(
        content: 'hello',
        threadUuid: 'th1',
        clientMsgUuid: 'cm1',
        executor: 'n_exec',
        modelId: 'm1',
        fileContext: const ChatFileContext(activeFile: ChatFileReference(rootIndex: 0, path: 'a.md')),
      );
      expect(data['thread_uuid'], 'th1');
      expect(data.containsKey('workspace_uuid'), isFalse);
      expect(data['client_msg_uuid'], 'cm1');
      expect(data['executor'], 'n_exec');
      expect(data['model_id'], 'm1');
      expect(data['file_context'], isA<Map<String, dynamic>>());
      expect(buildTaskSubmitData(content: 'x', workspaceUuid: 'w1')['new_thread'], isTrue);
      expect(() => buildTaskSubmitData(content: 'x'), throwsArgumentError);
      expect(() => buildTaskSubmitData(content: 'x', threadUuid: 'a', workspaceUuid: 'b'), throwsArgumentError);
      expect(() => buildTaskSubmitData(content: '  ', threadUuid: 'a'), throwsArgumentError);
    });
  });

  group('PeerEngineSocket task frames', () {
    test('sends task.submit/cancel and thread.subscribe/unsubscribe on control', () async {
      final FakeLink link = engineLink((FakeLink _, Envelope _) {});
      final PeerEngineSocket socket = PeerEngineSocket(linkProvider: () async => link);
      await socket.connect();

      final String submitId = socket.submitTask(
        content: 'do it',
        workspaceUuid: 'w1',
        executor: 'n_exec',
        clientMsgUuid: 'cm1',
      );
      final (String, Envelope) submit = link.sent.last;
      expect(submit.$1, 'control');
      expect(submit.$2.type, 'task.submit');
      expect(submit.$2.id, submitId);
      expect(submit.$2.dataMap!['workspace_uuid'], 'w1');
      expect(submit.$2.dataMap!['executor'], 'n_exec');
      expect(submit.$2.dataMap!['client_msg_uuid'], 'cm1');
      expect(submit.$2.dataMap!.containsKey('thread_uuid'), isFalse);

      socket.cancelTask('t1');
      expect(link.sent.last.$2.type, 'task.cancel');
      expect(link.sent.last.$2.id, 't1');
      expect(link.sent.last.$2.dataMap, <String, dynamic>{'task_id': 't1'});

      socket.subscribeThread('th1');
      expect(link.sent.last.$2.type, 'thread.subscribe');
      expect(link.sent.last.$2.dataMap, <String, dynamic>{'thread_uuid': 'th1'});
      socket.unsubscribeThread('th1');
      expect(link.sent.last.$2.type, 'thread.unsubscribe');
    });

    test('taskEvents delivers typed events from control and events channels', () async {
      final FakeLink link = engineLink((FakeLink _, Envelope _) {});
      final PeerEngineSocket socket = PeerEngineSocket(linkProvider: () async => link);
      await socket.connect();
      final List<TaskEvent> events = <TaskEvent>[];
      socket.taskEvents.listen(events.add);
      link.receive('control', Envelope(type: 'task.status', id: 't1', data: taskJson('t1', 'running')));
      link.receive('events', Envelope(type: 'chat.delta', id: 't1', data: const <String, dynamic>{'delta': 'a'}));
      link.receive('control', Envelope(type: 'pong', data: const <String, dynamic>{}));
      await until(() => events.length == 2);
      expect(events[0], isA<TaskStatusChanged>());
      expect(events[1], isA<TaskDelta>());
    });
  });

  group('EngineRepository.runTask', () {
    test('streams accepted, status and deltas, then completes on done', () async {
      final FakeLink link = engineLink((FakeLink l, Envelope submit) {
        l.receive('control', Envelope(type: 'task.accepted', id: submit.id, data: taskJson('t1', 'queued')));
        l.receive('control', Envelope(type: 'task.status', id: 't1', data: taskJson('t1', 'running')));
        l.receive('events', Envelope(type: 'chat.delta', id: 't1', data: const <String, dynamic>{'thread_uuid': 'th1', 'delta': 'Hel'}));
        // Another task's frames are ignored.
        l.receive('events', Envelope(type: 'chat.delta', id: 'other', data: const <String, dynamic>{'delta': 'zzz'}));
        l.receive('events', Envelope(type: 'chat.delta', id: 't1', data: const <String, dynamic>{'thread_uuid': 'th1', 'delta': 'lo'}));
        l.receive('events', Envelope(type: 'chat.done', id: 't1', data: const <String, dynamic>{'thread_uuid': 'th1'}));
        l.receive('control', Envelope(type: 'task.status', id: 't1', data: taskJson('t1', 'done')));
      });
      final EngineRepository repository = repositoryOver(link);
      await repository.connect();
      final List<TaskEvent> events = await repository
          .runTask(content: 'hi', threadUuid: 'th1', executor: 'n_exec')
          .toList();
      final String text = events.whereType<TaskDelta>().map((TaskDelta d) => d.delta).join();
      expect(text, 'Hello');
      expect(events.first, isA<TaskAccepted>());
      expect(events.whereType<TaskStatusChanged>().last.task.status, TaskStatus.done);
      final Envelope submit = link.sent.firstWhere(((String, Envelope) s) => s.$2.type == 'task.submit').$2;
      expect(submit.dataMap!['executor'], 'n_exec');
      expect(submit.dataMap!['thread_uuid'], 'th1');
    });

    test('a refused submit throws', () async {
      final FakeLink link = engineLink((FakeLink l, Envelope submit) {
        l.receive('control', Envelope(type: 'task.error', id: submit.id, data: const <String, dynamic>{'error': 'executor offline'}));
      });
      final EngineRepository repository = repositoryOver(link);
      await repository.connect();
      await expectLater(
        repository.runTask(content: 'hi', threadUuid: 'th1').toList(),
        throwsA(isA<StateError>().having((StateError e) => e.message, 'message', 'executor offline')),
      );
    });

    test('a failed task throws with the executor error', () async {
      final FakeLink link = engineLink((FakeLink l, Envelope submit) {
        l.receive('control', Envelope(type: 'task.accepted', id: submit.id, data: taskJson('t1', 'running')));
        l.receive('control', Envelope(type: 'task.status', id: 't1', data: taskJson('t1', 'failed', error: 'model missing')));
      });
      final EngineRepository repository = repositoryOver(link);
      await repository.connect();
      await expectLater(
        repository.runTask(content: 'hi', threadUuid: 'th1').toList(),
        throwsA(isA<StateError>().having((StateError e) => e.message, 'message', 'model missing')),
      );
    });

    test('cancelled ends the stream without an error', () async {
      final FakeLink link = engineLink((FakeLink l, Envelope submit) {
        l.receive('control', Envelope(type: 'task.accepted', id: submit.id, data: taskJson('t1', 'running')));
        l.receive('control', Envelope(type: 'task.status', id: 't1', data: taskJson('t1', 'cancelled')));
      });
      final EngineRepository repository = repositoryOver(link);
      await repository.connect();
      final List<TaskEvent> events = await repository.runTask(content: 'hi', threadUuid: 'th1').toList();
      expect(events.whereType<TaskStatusChanged>().last.task.status, TaskStatus.cancelled);
    });

    test('abandoning the stream sends task.cancel', () async {
      final FakeLink link = engineLink((FakeLink l, Envelope submit) {
        l.receive('control', Envelope(type: 'task.accepted', id: submit.id, data: taskJson('t1', 'running')));
      });
      final EngineRepository repository = repositoryOver(link);
      await repository.connect();
      final Completer<void> accepted = Completer<void>();
      final StreamSubscription<TaskEvent> subscription = repository
          .runTask(content: 'hi', threadUuid: 'th1')
          .listen((TaskEvent e) {
            if (e is TaskAccepted && !accepted.isCompleted) accepted.complete();
          });
      await accepted.future;
      await subscription.cancel();
      await until(() => link.sent.any(((String, Envelope) s) => s.$2.type == 'task.cancel'));
      final Envelope cancel = link.sent.firstWhere(((String, Envelope) s) => s.$2.type == 'task.cancel').$2;
      expect(cancel.dataMap!['task_id'], 't1');
    });

    test('a refused remote approval prompt surfaces for the task', () async {
      final FakeLink link = engineLink((FakeLink l, Envelope submit) {
        l.receive('control', Envelope(type: 'task.accepted', id: submit.id, data: taskJson('t1', 'running')));
        l.receive('control', Envelope(type: 'tool.approval.request', id: 't1', data: const <String, dynamic>{
          'approval_id': 'a1',
          'remote': true,
          'peer_name': 'Desk',
          'tool_name': 'calculate',
          'arguments': <String, dynamic>{},
          'task_id': 't1',
          'operation': 'read',
        }));
        l.receive('control', Envelope(type: 'tool.approval.resolved', id: 't1', data: const <String, dynamic>{'approval_id': 'a1'}));
        l.receive('control', Envelope(type: 'task.status', id: 't1', data: taskJson('t1', 'done')));
      });
      final EngineRepository repository = repositoryOver(link);
      await repository.connect();
      final List<TaskEvent> events = await repository.runTask(content: 'hi', threadUuid: 'th1').toList();
      expect(events.whereType<ToolApprovalRequested>().single.request.peerName, 'Desk');
      expect(events.whereType<ToolApprovalResolved>().single.approvalId, 'a1');
    });
  });

  group('WebSocketEngineClient task frames', () {
    late HttpServer server;
    late List<Map<String, dynamic>> received;
    WebSocket? serverSocket;

    setUp(() async {
      received = <Map<String, dynamic>>[];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        final WebSocket socket = await WebSocketTransformer.upgrade(request);
        serverSocket = socket;
        socket.listen((Object? raw) {
          final Map<String, dynamic> f = jsonDecode(raw! as String) as Map<String, dynamic>;
          received.add(f);
          if (f['type'] == 'client.hello') {
            socket.add(jsonEncode(<String, dynamic>{'v': 1, 'type': 'client.hello.ack', 'id': f['id'], 'data': <String, dynamic>{}}));
          }
        });
      });
    });

    tearDown(() async {
      await serverSocket?.close();
      await server.close(force: true);
    });

    test('uses the same wire frames as the peer socket', () async {
      final WebSocketEngineClient client = WebSocketEngineClient(
        endpoint: Uri.parse('ws://127.0.0.1:${server.port}/api/v1/events'),
      );
      await client.connect();
      final List<TaskEvent> events = <TaskEvent>[];
      client.taskEvents.listen(events.add);

      final String id = client.submitTask(content: 'go', threadUuid: 'th1', executor: 'n_exec', clientMsgUuid: 'cm1');
      client.cancelTask('t1');
      client.subscribeThread('th1');
      client.unsubscribeThread('th1');
      await until(() => received.length >= 5);
      final Map<String, dynamic> submit = received.firstWhere((Map<String, dynamic> f) => f['type'] == 'task.submit');
      expect(submit['id'], id);
      expect((submit['data'] as Map)['executor'], 'n_exec');
      expect((submit['data'] as Map)['thread_uuid'], 'th1');
      expect(received.map((Map<String, dynamic> f) => f['type']), containsAll(<String>['task.cancel', 'thread.subscribe', 'thread.unsubscribe']));
      expect(received.firstWhere((Map<String, dynamic> f) => f['type'] == 'task.cancel')['id'], 't1');

      serverSocket!.add(jsonEncode(<String, dynamic>{'v': 1, 'type': 'task.accepted', 'id': id, 'data': taskJson('t1', 'queued')}));
      serverSocket!.add(jsonEncode(<String, dynamic>{'v': 1, 'type': 'chat.delta', 'id': 't1', 'data': <String, dynamic>{'delta': 'x'}}));
      await until(() => events.length == 2);
      expect((events.first as TaskAccepted).submitId, id);
      expect(events.last, isA<TaskDelta>());
      await client.dispose();
    });
  });
}
