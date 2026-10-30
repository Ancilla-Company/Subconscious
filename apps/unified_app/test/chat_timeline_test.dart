import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';
import 'package:unified_app/features/chat/engine_llm_provider.dart';
import 'package:unified_app/features/chat/presentation/tool_activity_tile.dart';

final class _Link implements PeerLink {
  final StreamController<InboundEnvelope> inbound =
      StreamController<InboundEnvelope>.broadcast();
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

  void emit(String turn, String type, Map<String, dynamic> data) =>
      receive('events', Envelope(type: type, id: turn, data: data));

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }
}

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
  return (
    EngineLlmProvider(repository: repository, threadUuid: 'th1'),
    link,
  );
}

Map<String, dynamic> toolFrame(String status, {Map<String, dynamic>? extra}) =>
    <String, dynamic>{
      'tool_call_id': 'c1',
      'tool_name': 'ask_helper',
      'title': 'ask helper',
      'kind': 'execute',
      'status': status,
      ...?extra,
    };

String roles(EngineLlmProvider provider) => provider.history
    .map(
      (EngineChatMessage m) => switch (m.origin) {
        EngineChatMessageOrigin.user => 'user',
        EngineChatMessageOrigin.assistant => 'assistant:${m.text}',
        EngineChatMessageOrigin.system => 'system',
        EngineChatMessageOrigin.tool => 'tool:${m.toolCall!.status}',
      },
    )
    .join(' | ');

ChatMessage stored(String uuid, String role, String content) => ChatMessage(
  uuid: uuid,
  threadUuid: 'th1',
  role: role,
  content: content,
);

void main() {
  test('text, tool call and sub-agent steps appear in the order they happen', () async {
    final (EngineLlmProvider provider, _Link link) = await providerOver();
    link.script = (Envelope e) {
      if (e.type != 'chat.send') return;
      final String t = e.id!;
      link
        ..emit(t, 'chat.delta', <String, dynamic>{'delta': 'Let me ask. '})
        ..emit(t, 'chat.tool_call', toolFrame('pending', extra: <String, dynamic>{
          'arguments': <String, dynamic>{'prompt': 'hi'},
        }))
        ..emit(t, 'chat.tool_call', toolFrame('in_progress'))
        ..emit(t, 'chat.tool_progress', <String, dynamic>{
          'tool_call_id': 'c1',
          'step': <String, dynamic>{'id': 'message-0', 'kind': 'message', 'text': 'hello'},
        })
        ..emit(t, 'chat.tool_call', toolFrame('completed', extra: <String, dynamic>{
          'output': <String, dynamic>{'output': 'hello'},
        }))
        ..emit(t, 'chat.delta', <String, dynamic>{'delta': 'It said hello.'})
        ..emit(t, 'chat.done', const <String, dynamic>{});
    };
    final List<String> deltas = await provider.sendMessageStream('go').toList();
    expect(deltas.join(), 'Let me ask. It said hello.');
    expect(
      roles(provider),
      'user | assistant:Let me ask.  | tool:completed | assistant:It said hello.',
    );
    final ToolCallInfo call = provider.history
        .firstWhere((EngineChatMessage m) => m.toolCall != null)
        .toolCall!;
    expect(call.arguments, <String, dynamic>{'prompt': 'hi'});
    expect(call.output, <String, dynamic>{'output': 'hello'});
    expect(call.steps.single.text, 'hello');
    // Nothing is left marked as streaming; the timing goes on the last reply.
    expect(provider.history.any(provider.isStreaming), isFalse);
    expect(provider.history.last.elapsed, isNotNull);
  });

  test('a refresh in the middle of a turn neither duplicates nor drops anything', () async {
    final (EngineLlmProvider provider, _Link link) = await providerOver();
    late final String turn;
    link.script = (Envelope e) {
      if (e.type != 'chat.send') return;
      turn = e.id!;
      link
        ..emit(turn, 'chat.delta', <String, dynamic>{'delta': 'Checking. '})
        ..emit(turn, 'chat.tool_call', toolFrame('in_progress'));
    };
    final Completer<void> finished = Completer<void>();
    provider.sendMessageStream('go').listen((_) {}, onDone: finished.complete);
    await pumpEventQueue();
    expect(roles(provider), 'user | assistant:Checking.  | tool:in_progress');

    // The engine has stored the text and the user message so far; another
    // device's refresh arrives while this turn is still streaming.
    provider.replaceEngineHistory(<ChatMessage>[
      stored('u1', 'user', 'go'),
      stored('a1', 'assistant', 'Checking. '),
    ]);
    expect(roles(provider), 'user | assistant:Checking.  | tool:in_progress');

    link
      ..emit(turn, 'chat.tool_call', toolFrame('completed'))
      ..emit(turn, 'chat.delta', <String, dynamic>{'delta': 'Done.'})
      ..emit(turn, 'chat.done', const <String, dynamic>{});
    await finished.future;
    expect(
      roles(provider),
      'user | assistant:Checking.  | tool:completed | assistant:Done.',
    );

    // After the turn the stored copy replaces the live one, tool card included.
    provider.replaceEngineHistory(<ChatMessage>[
      stored('u1', 'user', 'go'),
      stored('a1', 'assistant', 'Checking. '),
      stored(
        't1',
        'tool',
        jsonEncode(<String, dynamic>{
          'v': 2,
          'toolCallId': 'c1',
          'toolName': 'ask_helper',
          'status': 'completed',
          'approval': 'approved',
        }),
      ),
      stored('a2', 'assistant', 'Done.'),
    ]);
    expect(
      roles(provider),
      'user | assistant:Checking.  | tool:completed | assistant:Done.',
    );
    expect(
      provider.history.firstWhere((EngineChatMessage m) => m.toolCall != null).toolCall!.approval,
      'approved',
    );
  });

  test('a failed turn keeps the text and tool calls already shown', () async {
    final (EngineLlmProvider provider, _Link link) = await providerOver();
    link.script = (Envelope e) {
      if (e.type != 'chat.send') return;
      final String t = e.id!;
      link
        ..emit(t, 'chat.delta', <String, dynamic>{'delta': 'Half an ans'})
        ..emit(t, 'chat.tool_call', toolFrame('failed', extra: <String, dynamic>{'error': 'denied'}))
        ..emit(t, 'chat.error', <String, dynamic>{'error': 'model fell over'});
    };
    await expectLater(provider.sendMessageStream('go').toList(), throwsStateError);
    expect(roles(provider), 'user | assistant:Half an ans | tool:failed');
  });

  test('stored tool records of every age become cards; unreadable ones are skipped', () async {
    final (EngineLlmProvider provider, _) = await providerOver();
    provider.replaceEngineHistory(<ChatMessage>[
      stored('t1', 'tool', jsonEncode(<String, dynamic>{'toolName': 'get_note', 'output': 'x', 'outcome': 'success'})),
      stored('t2', 'tool', 'not json'),
    ]);
    expect(roles(provider), 'tool:completed');
  });

  group('ToolActivityTile', () {
    Widget host(ToolCallInfo call) => MaterialApp(
      home: Scaffold(
        body: AppFormTheme(child: SingleChildScrollView(child: ToolActivityTile(call: call))),
      ),
    );

    testWidgets('shows approval, sub-agent badge, duration and opens to the details', (tester) async {
      await tester.pumpWidget(
        host(
          const ToolCallInfo(
            toolCallId: 'c1',
            toolName: 'ask_helper',
            title: 'ask helper',
            status: 'completed',
            approval: 'approved',
            durationMs: 1500,
            arguments: <String, dynamic>{'prompt': 'hi'},
            output: <String, dynamic>{'output': 'hello'},
            steps: <ToolStep>[
              ToolStep(id: 'tool-1', kind: 'tool', title: 'read file', status: 'completed'),
              ToolStep(id: 'message-0', kind: 'message', text: 'what the agent wrote'),
            ],
          ),
        ),
      );
      expect(find.byType(AppActivityCard), findsOneWidget);
      expect(find.text('ask helper'), findsOneWidget);
      expect(find.text('Approved'), findsOneWidget);
      expect(find.text('Sub-agent'), findsOneWidget);
      expect(find.text('1.5 s'), findsOneWidget);
      expect(find.text('what the agent wrote'), findsNothing);

      await tester.tap(find.text('ask helper'));
      await tester.pumpAndSettle();
      expect(find.text('what the agent wrote'), findsOneWidget);
      expect(find.text('read file'), findsOneWidget);
      expect(find.text('Input'), findsOneWidget);
    });

    testWidgets('a denied call says so and a pending one asks for approval', (tester) async {
      await tester.pumpWidget(
        host(const ToolCallInfo(
          toolCallId: 'c', toolName: 'remove_skill', status: 'failed', approval: 'denied', error: 'denied')),
      );
      expect(find.text('Denied'), findsOneWidget);
      expect(find.text('You denied this call'), findsOneWidget);
      expect(find.text('remove skill'), findsOneWidget); // title from the tool name

      await tester.pumpWidget(
        host(const ToolCallInfo(toolCallId: 'c', toolName: 'delete_note', status: 'pending')),
      );
      expect(find.text('Needs approval'), findsOneWidget);
    });
  });
}
