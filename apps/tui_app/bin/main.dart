import 'package:core_business_logic/core_business_logic.dart';
import 'package:dart_tui/dart_tui.dart';

Future<void> main() async {
  final EngineRepository? repository = _createRepository();
  await Program(options: <ProgramOption>[withAltScreen(), withHideCursor()]).run(EngineTuiModel(repository: repository));
}

EngineRepository? _createRepository() {
  const String rawUrl = String.fromEnvironment('SUBCONSCIOUS_ENGINE_URL');
  const String token = String.fromEnvironment('SUBCONSCIOUS_ENGINE_TOKEN');
  final Uri? httpUri = Uri.tryParse(rawUrl);
  if (httpUri == null || httpUri.host.isEmpty || token.isEmpty) return null;
  final Uri wsUri = httpUri.replace(scheme: httpUri.scheme == 'https' ? 'wss' : 'ws', path: '/api/v1/events', queryParameters: <String, String>{'token': token});
  return EngineRepository(rest: RestEngineClient(baseUri: httpUri.replace(path: '/api/v1/'), token: token), socket: WebSocketEngineClient(endpoint: wsUri));
}

final class EngineTuiModel extends Model {
  EngineTuiModel({required this.repository, this.workspaces, this.error});
  final EngineRepository? repository;
  final List<Workspace>? workspaces;
  final Object? error;

  @override
  Cmd? init() => () async {
    final EngineRepository? current = repository;
    if (current == null) return const _EngineUnavailable('Configure SUBCONSCIOUS_ENGINE_URL and SUBCONSCIOUS_ENGINE_TOKEN.');
    try {
      await current.connect();
      return _WorkspacesLoaded(await current.listWorkspaces());
    } on Object catch (caughtError) {
      return _EngineUnavailable(caughtError.toString());
    }
  };

  @override
  (Model, Cmd?) update(Msg msg) {
    if (msg is _WorkspacesLoaded) return (EngineTuiModel(repository: repository, workspaces: msg.workspaces), null);
    if (msg is _EngineUnavailable) return (EngineTuiModel(repository: repository, error: msg.message), null);
    if (msg is KeyMsg && (msg.key == 'q' || msg.key == 'ctrl+c')) return (this, () => quit());
    return (this, null);
  }

  @override
  View view() {
    if (error != null) return newView('Subconscious engine unavailable.\n$error\n\nPress q to quit.');
    if (workspaces == null) return newView('Connecting to Subconscious engine…');
    final String workspaceText = workspaces!.isEmpty ? 'No workspaces yet.' : workspaces!.map((Workspace workspace) => '• ${workspace.name}').join('\n');
    return newView('Subconscious\n\n$workspaceText\n\nPress q to quit.');
  }
}

final class _WorkspacesLoaded extends Msg {
  _WorkspacesLoaded(this.workspaces);
  final List<Workspace> workspaces;
}

final class _EngineUnavailable extends Msg {
  const _EngineUnavailable(this.message);
  final String message;
}
