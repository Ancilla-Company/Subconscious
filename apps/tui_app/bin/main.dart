import 'package:core_business_logic/core_business_logic.dart';
import 'package:dart_tui/dart_tui.dart';

Future<void> main() async =>
    Program(options: <ProgramOption>[withAltScreen(), withHideCursor()])
        .run(EngineTuiModel(repository: _createRepository()));

EngineRepository? _createRepository() {
  const String rawUrl = String.fromEnvironment('SUBCONSCIOUS_ENGINE_URL');
  const String token = String.fromEnvironment('SUBCONSCIOUS_ENGINE_TOKEN');
  final Uri? httpUri = Uri.tryParse(rawUrl);
  if (httpUri == null || httpUri.host.isEmpty || token.isEmpty) return null;
  final Uri wsUri = httpUri.replace(
    scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
    path: '/api/v1/events',
    queryParameters: <String, String>{'token': token},
  );
  return EngineRepository(
    rest: RestEngineClient(
      baseUri: httpUri.replace(path: '/api/v1/'),
      token: token,
    ),
    socket: WebSocketEngineClient(
      endpoint: wsUri,
      identity: const ClientIdentity(type: ClientType.tui),
    ),
  );
}

enum _Screen { workspaces, threads, messages }

final class EngineTuiModel extends Model {
  EngineTuiModel({
    required this.repository,
    this.screen = _Screen.workspaces,
    this.workspaces = const <Workspace>[],
    this.threads = const <ThreadInfo>[],
    this.messages = const <ChatMessage>[],
    this.workspaceIndex = 0,
    this.threadIndex = 0,
    this.error,
    this.composing = false,
    this.draft = '',
  });
  final EngineRepository? repository;
  final _Screen screen;
  final List<Workspace> workspaces;
  final List<ThreadInfo> threads;
  final List<ChatMessage> messages;
  final int workspaceIndex;
  final int threadIndex;
  final Object? error;
  final bool composing;
  final String draft;
  Workspace? get workspace => workspaces.isEmpty
      ? null
      : workspaces[workspaceIndex.clamp(0, workspaces.length - 1)];
  ThreadInfo? get thread => threads.isEmpty
      ? null
      : threads[threadIndex.clamp(0, threads.length - 1)];
  EngineTuiModel copy({
    _Screen? screen,
    List<Workspace>? workspaces,
    List<ThreadInfo>? threads,
    List<ChatMessage>? messages,
    int? workspaceIndex,
    int? threadIndex,
    Object? error,
    bool? composing,
    String? draft,
  }) => EngineTuiModel(
    repository: repository,
    screen: screen ?? this.screen,
    workspaces: workspaces ?? this.workspaces,
    threads: threads ?? this.threads,
    messages: messages ?? this.messages,
    workspaceIndex: workspaceIndex ?? this.workspaceIndex,
    threadIndex: threadIndex ?? this.threadIndex,
    error: error,
    composing: composing ?? this.composing,
    draft: draft ?? this.draft,
  );
  @override
  Cmd? init() => _loadWorkspaces();
  Cmd _loadWorkspaces() => () async {
    final EngineRepository? current = repository;
    if (current == null)
      return const _Failure(
        'Configure SUBCONSCIOUS_ENGINE_URL and SUBCONSCIOUS_ENGINE_TOKEN.',
      );
    try {
      await current.connect();
      return _Workspaces(await current.listWorkspaces());
    } on Object catch (error) {
      return _Failure(error.toString());
    }
  };
  Cmd _loadThreads(Workspace value) => () async {
    try {
      return _Threads(await repository!.listThreads(value.uuid));
    } on Object catch (error) {
      return _Failure(error.toString());
    }
  };
  Cmd _loadMessages(ThreadInfo value) => () async {
    try {
      return _Messages(await repository!.listMessages(value.uuid));
    } on Object catch (error) {
      return _Failure(error.toString());
    }
  };
  Cmd _send() => () async {
    try {
      final StringBuffer output = StringBuffer();
      await for (final String delta in repository!.streamChat(
        content: draft,
        threadUuid: thread!.uuid,
      )) {
        output.write(delta);
      }
      return _Sent(output.toString());
    } on Object catch (error) {
      return _Failure(error.toString());
    }
  };
  @override
  (Model, Cmd?) update(Msg msg) {
    if (msg is _Workspaces)
      return (copy(workspaces: msg.values, error: null), null);
    if (msg is _Threads)
      return (
        copy(
          screen: _Screen.threads,
          threads: msg.values,
          threadIndex: 0,
          error: null,
        ),
        null,
      );
    if (msg is _Messages)
      return (
        copy(screen: _Screen.messages, messages: msg.values, error: null),
        null,
      );
    if (msg is _Sent)
      return (
        copy(
          composing: false,
          draft: '',
          messages: <ChatMessage>[
            ...messages,
            ChatMessage(
              uuid: 'local',
              threadUuid: thread!.uuid,
              role: 'assistant',
              content: msg.value,
            ),
          ],
          error: null,
        ),
        null,
      );
    if (msg is _Failure)
      return (copy(error: msg.value, composing: false), null);
    if (msg is! KeyMsg) return (this, null);
    if (msg.key == 'q' || msg.key == 'ctrl+c') return (this, () => quit());
    if (composing) {
      if (msg.key == 'esc') return (copy(composing: false, draft: ''), null);
      if (msg.key == 'enter' && draft.trim().isNotEmpty)
        return (copy(), _send());
      if (msg.key == 'backspace')
        return (
          copy(
            draft: draft.isEmpty ? '' : draft.substring(0, draft.length - 1),
          ),
          null,
        );
      if (msg.key.length == 1) return (copy(draft: '$draft${msg.key}'), null);
      return (this, null);
    }
    if (msg.key == 'r')
      return (
        copy(error: null),
        screen == _Screen.workspaces
            ? _loadWorkspaces()
            : screen == _Screen.threads && workspace != null
            ? _loadThreads(workspace!)
            : thread != null
            ? _loadMessages(thread!)
            : null,
      );
    if (msg.key == 'up')
      return (
        screen == _Screen.workspaces
            ? copy(workspaceIndex: workspaceIndex > 0 ? workspaceIndex - 1 : 0)
            : copy(threadIndex: threadIndex > 0 ? threadIndex - 1 : 0),
        null,
      );
    if (msg.key == 'down')
      return (
        screen == _Screen.workspaces
            ? copy(
                workspaceIndex: workspaceIndex + 1 < workspaces.length
                    ? workspaceIndex + 1
                    : workspaceIndex,
              )
            : copy(
                threadIndex: threadIndex + 1 < threads.length
                    ? threadIndex + 1
                    : threadIndex,
              ),
        null,
      );
    if (msg.key == 'enter') {
      if (screen == _Screen.workspaces && workspace != null)
        return (copy(), _loadThreads(workspace!));
      if (screen == _Screen.threads && thread != null)
        return (copy(), _loadMessages(thread!));
    }
    if (msg.key == 'b' && screen != _Screen.workspaces)
      return (
        copy(
          screen: screen == _Screen.messages
              ? _Screen.threads
              : _Screen.workspaces,
        ),
        null,
      );
    if (msg.key == 'c' && screen == _Screen.messages && thread != null)
      return (copy(composing: true, draft: ''), null);
    return (this, null);
  }

  @override
  View view() {
    if (error != null)
      return newView('Subconscious error\n$error\n\n[r] retry · [q] quit');
    final String header = 'Subconscious · ${screen.name}';
    if (screen == _Screen.workspaces)
      return newView(
        '$header\n\n${_menu(workspaces.map((value) => value.name).toList(), workspaceIndex)}\n\n↑↓ select · Enter threads · r refresh · q quit',
      );
    if (screen == _Screen.threads)
      return newView(
        '$header · ${workspace?.name ?? ''}\n\n${_menu(threads.map((value) => value.title?.isNotEmpty == true ? value.title! : 'Untitled thread').toList(), threadIndex)}\n\n↑↓ select · Enter messages · b back · r refresh · q quit',
      );
    final String transcript = messages.isEmpty
        ? 'No messages yet.'
        : messages
              .map((value) => '${value.role}: ${value.content}')
              .join('\n\n');
    return newView(
      '$header · ${thread?.title ?? 'Untitled thread'}\n\n$transcript\n\n${composing ? 'Message: ${draft}_' : '[c] compose · b back · r refresh · q quit'}',
    );
  }

  String _menu(List<String> values, int selected) => values.isEmpty
      ? 'No items.'
      : List<String>.generate(
          values.length,
          (index) => '${index == selected ? '›' : ' '} ${values[index]}',
        ).join('\n');
}

final class _Workspaces extends Msg {
  _Workspaces(this.values);
  final List<Workspace> values;
}

final class _Threads extends Msg {
  _Threads(this.values);
  final List<ThreadInfo> values;
}

final class _Messages extends Msg {
  _Messages(this.values);
  final List<ChatMessage> values;
}

final class _Sent extends Msg {
  _Sent(this.value);
  final String value;
}

final class _Failure extends Msg {
  const _Failure(this.value);
  final String value;
}
