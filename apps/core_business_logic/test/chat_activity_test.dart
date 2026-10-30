import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:test/test.dart';

WireFrame frame(String type, Map<String, dynamic> data, {String? id = 't1'}) =>
    WireFrame(type: type, id: id, data: data);

void main() {
  group('ChatActivity.tryParseFrame', () {
    test('chat.tool_call becomes a ToolCallInfo', () {
      final ChatActivity? activity = ChatActivity.tryParseFrame(
        frame('chat.tool_call', <String, dynamic>{
          'tool_call_id': 'c1',
          'tool_name': 'ask_helper',
          'title': 'ask helper',
          'kind': 'execute',
          'status': 'pending',
          'arguments': <String, dynamic>{'prompt': 'hi'},
        }),
      );
      final ToolCallInfo call = (activity! as ChatToolCall).call;
      expect(call.toolCallId, 'c1');
      expect(call.status, 'pending');
      expect(call.isWaitingForApproval, isTrue);
      expect(call.arguments, <String, dynamic>{'prompt': 'hi'});
    });

    test('chat.tool_progress carries a sub-agent step', () {
      final ChatActivity? activity = ChatActivity.tryParseFrame(
        frame('chat.tool_progress', <String, dynamic>{
          'tool_call_id': 'c1',
          'step': <String, dynamic>{
            'id': 'message-0',
            'kind': 'message',
            'text': 'hello',
          },
        }),
      );
      final ChatToolProgress progress = activity! as ChatToolProgress;
      expect(progress.toolCallId, 'c1');
      expect(progress.step.isMessage, isTrue);
      expect(progress.step.text, 'hello');
    });

    test('malformed or unrelated frames are ignored', () {
      expect(ChatActivity.tryParseFrame(frame('chat.delta', <String, dynamic>{})), isNull);
      expect(
        ChatActivity.tryParseFrame(frame('chat.tool_call', <String, dynamic>{'tool_name': 'x'})),
        isNull,
      );
      expect(
        ChatActivity.tryParseFrame(
          frame('chat.tool_progress', <String, dynamic>{'tool_call_id': 'c', 'step': 'nope'}),
        ),
        isNull,
      );
    });

    test('parseTaskEvent wraps activity for a hive task', () {
      final TaskEvent? event = parseTaskEvent(
        frame('chat.tool_call', <String, dynamic>{
          'tool_call_id': 'c1',
          'tool_name': 'get_note',
          'status': 'completed',
        }, id: 'task-9'),
      );
      expect(event, isA<TaskActivity>());
      expect((event! as TaskActivity).taskId, 'task-9');
    });
  });

  group('ToolCallInfo.tryParseRecord', () {
    test('a v2 record keeps approval, timing and sub-agent steps', () {
      final ToolCallInfo? call = ToolCallInfo.tryParseRecord(
        jsonEncode(<String, dynamic>{
          'v': 2,
          'toolCallId': 'c1',
          'toolName': 'ask_helper',
          'title': 'ask helper',
          'status': 'completed',
          'approval': 'approved',
          'approvalAt': '2026-10-30T10:00:00+00:00',
          'durationMs': 1200,
          'input': <String, dynamic>{'prompt': 'hi'},
          'output': <String, dynamic>{'output': 'hello'},
          'steps': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'tool-1', 'kind': 'tool', 'title': 'read file', 'status': 'completed'},
            <String, dynamic>{'id': 'message-0', 'kind': 'message', 'text': 'hello'},
          ],
        }),
        id: 'm1',
      );
      expect(call!.approval, 'approved');
      expect(call.approvalAt, isNotNull);
      expect(call.durationMs, 1200);
      expect(call.steps.map((ToolStep s) => s.id), <String>['tool-1', 'message-0']);
      expect(call.legacy, isFalse);
      expect(call.isFinished, isTrue);
    });

    test('older records still produce a card', () {
      final ToolCallInfo denied = ToolCallInfo.tryParseRecord(
        jsonEncode(<String, dynamic>{
          'toolName': 'remove_skill',
          'input': <String, dynamic>{'name': 'x'},
          'approval': 'denied',
        }),
        id: 'm2',
      )!;
      expect(denied.legacy, isTrue);
      expect(denied.status, 'failed');
      expect(denied.approval, 'denied');

      final ToolCallInfo ok = ToolCallInfo.tryParseRecord(
        jsonEncode(<String, dynamic>{'toolName': 'get_note', 'output': 'x', 'outcome': 'success'}),
        id: 'm3',
      )!;
      expect(ok.status, 'completed');
      expect(ok.toolCallId, 'm3');
    });

    test('content that is not a JSON object yields null', () {
      expect(ToolCallInfo.tryParseRecord('not json', id: 'x'), isNull);
      expect(ToolCallInfo.tryParseRecord('[1]', id: 'x'), isNull);
    });
  });

  test('withStep replaces a step by id and keeps earlier fields', () {
    ToolCallInfo call = const ToolCallInfo(toolCallId: 'c', toolName: 'ask_helper');
    call = call.withStep(const ToolStep(id: 'tool-1', kind: 'tool', title: 'read', status: 'pending'));
    call = call.withStep(const ToolStep(id: 'message-0', kind: 'message', text: 'a'));
    call = call.withStep(const ToolStep(id: 'tool-1', kind: 'tool', status: 'completed'));
    expect(call.steps.length, 2);
    expect(call.steps.first.title, 'read');
    expect(call.steps.first.status, 'completed');
  });
}
