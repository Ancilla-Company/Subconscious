import 'dart:convert';

import 'engine_models.dart';

/// One step a running tool reported about itself, for example a sub-agent
/// (an `ask_<agent>` tool) writing part of its reply or calling its own tool.
final class ToolStep {
  const ToolStep({
    required this.id,
    required this.kind,
    this.title,
    this.text,
    this.toolKind,
    this.status,
  });

  /// Stable within one tool call; a later step with the same id replaces it.
  final String id;

  /// `message` (text the sub-agent wrote) or `tool` (a call it made).
  final String kind;
  final String? title;
  final String? text;
  final String? toolKind;
  final String? status;

  bool get isMessage => kind == 'message';

  static ToolStep? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    String? text(String key) {
      final Object? value = raw[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    return ToolStep(
      id: id,
      kind: raw['kind'] is String ? raw['kind'] as String : 'message',
      title: text('title'),
      text: text('text'),
      toolKind: text('tool_kind') ?? text('toolKind'),
      status: text('status'),
    );
  }
}

/// A tool call as the chat shows it: live (from `chat.tool_call` frames) or
/// stored (a `tool` message in the thread).
final class ToolCallInfo {
  const ToolCallInfo({
    required this.toolCallId,
    required this.toolName,
    this.title,
    this.kind,
    this.status = 'pending',
    this.arguments,
    this.output,
    this.error,
    this.approval,
    this.approvalAt,
    this.durationMs,
    this.steps = const <ToolStep>[],
    this.legacy = false,
  });

  final String toolCallId;
  final String toolName;
  final String? title;

  /// ACP tool kind: read, edit, delete, move, search, execute, fetch, other.
  final String? kind;

  /// `pending` (waiting for approval), `in_progress`, `completed`, `failed`
  /// or `interrupted` (the turn ended before the tool did).
  final String status;
  final Object? arguments;
  final Object? output;
  final String? error;

  /// `approved`, `denied` or `not_required`; null while the decision is open.
  final String? approval;
  final DateTime? approvalAt;
  final int? durationMs;
  final List<ToolStep> steps;

  /// True for records stored before tool calls were logged in full.
  final bool legacy;

  bool get isFinished =>
      status == 'completed' || status == 'failed' || status == 'interrupted';
  bool get isWaitingForApproval => status == 'pending' && approval == null;

  ToolCallInfo copyWith({
    String? title,
    String? kind,
    String? status,
    Object? arguments,
    Object? output,
    String? error,
    String? approval,
    List<ToolStep>? steps,
  }) => ToolCallInfo(
    toolCallId: toolCallId,
    toolName: toolName,
    title: title ?? this.title,
    kind: kind ?? this.kind,
    status: status ?? this.status,
    arguments: arguments ?? this.arguments,
    output: output ?? this.output,
    error: error ?? this.error,
    approval: approval ?? this.approval,
    approvalAt: approvalAt,
    durationMs: durationMs,
    steps: steps ?? this.steps,
    legacy: legacy,
  );

  /// This call with [step] added, or replacing the step that has its id.
  ToolCallInfo withStep(ToolStep step) {
    final List<ToolStep> next = <ToolStep>[...steps];
    final int index = next.indexWhere((ToolStep item) => item.id == step.id);
    if (index < 0) {
      next.add(step);
    } else {
      final ToolStep old = next[index];
      next[index] = ToolStep(
        id: step.id,
        kind: step.kind,
        title: step.title ?? old.title,
        text: step.text ?? old.text,
        toolKind: step.toolKind ?? old.toolKind,
        status: step.status ?? old.status,
      );
    }
    return copyWith(steps: next);
  }

  /// From a `chat.tool_call` frame's data.
  static ToolCallInfo? tryParseFrame(Map<String, dynamic> data) {
    final Object? id = data['tool_call_id'];
    final Object? name = data['tool_name'];
    if (id is! String || name is! String) return null;
    String? text(String key) {
      final Object? value = data[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    return ToolCallInfo(
      toolCallId: id,
      toolName: name,
      title: text('title'),
      kind: text('kind'),
      status: text('status') ?? 'pending',
      arguments: data['arguments'],
      output: data['output'],
      error: text('error'),
    );
  }

  /// From the content of a stored `tool` message; null if it is not JSON.
  static ToolCallInfo? tryParseRecord(String content, {required String id}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final Map<String, dynamic> record = decoded.cast<String, dynamic>();
    String? text(String key) {
      final Object? value = record[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    final String name = text('toolName') ?? 'tool';
    if (record['v'] == 2) {
      return ToolCallInfo(
        toolCallId: text('toolCallId') ?? id,
        toolName: name,
        title: text('title'),
        kind: text('kind'),
        status: text('status') ?? 'completed',
        arguments: record['input'],
        output: record['output'],
        error: text('error'),
        approval: text('approval'),
        approvalAt: DateTime.tryParse(text('approvalAt') ?? ''),
        durationMs: record['durationMs'] is num
            ? (record['durationMs'] as num).toInt()
            : null,
        steps: <ToolStep>[
          if (record['steps'] is List)
            for (final Object? raw in record['steps'] as List<Object?>)
              if (ToolStep.tryParse(raw) case final ToolStep step) step,
        ],
      );
    }
    // Older records: {toolName, output, outcome} or {toolName, input, approval}.
    final String? approval = text('approval');
    final String outcome = text('outcome') ?? 'success';
    final bool failed = outcome != 'success' || approval == 'denied';
    return ToolCallInfo(
      toolCallId: id,
      toolName: name,
      status: failed ? 'failed' : 'completed',
      arguments: record['input'],
      output: record['output'],
      error: text('error') ?? (approval == 'denied' ? 'Denied.' : null),
      approval: approval,
      legacy: true,
    );
  }
}

/// A tool event of a running turn, in the order the engine sent it.
sealed class ChatActivity {
  const ChatActivity();

  /// Parses `chat.tool_call` and `chat.tool_progress`; null for any other or
  /// malformed frame.
  static ChatActivity? tryParseFrame(WireFrame frame) {
    final Map<String, dynamic> data = frame.data ?? const <String, dynamic>{};
    switch (frame.type) {
      case 'chat.tool_call':
        final ToolCallInfo? call = ToolCallInfo.tryParseFrame(data);
        return call == null ? null : ChatToolCall(call);
      case 'chat.tool_progress':
        final Object? id = data['tool_call_id'];
        final ToolStep? step = ToolStep.tryParse(data['step']);
        return id is String && step != null ? ChatToolProgress(id, step) : null;
    }
    return null;
  }
}

/// A tool call started, waits for approval, finished or failed.
final class ChatToolCall extends ChatActivity {
  const ChatToolCall(this.call);
  final ToolCallInfo call;
}

/// A step reported by a running tool (a sub-agent working).
final class ChatToolProgress extends ChatActivity {
  const ChatToolProgress(this.toolCallId, this.step);
  final String toolCallId;
  final ToolStep step;
}

/// Frame types [ChatActivity.tryParseFrame] understands.
const Set<String> chatActivityFrameTypes = <String>{
  'chat.tool_call',
  'chat.tool_progress',
};
