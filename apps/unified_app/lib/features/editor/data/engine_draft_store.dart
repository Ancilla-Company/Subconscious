import 'package:core_business_logic/core_business_logic.dart';

import '../controller/editor_draft.dart';
import '../controller/file_gateway.dart';

/// Stores editor drafts in the engine's settings table.
///
/// Each draft is one row, keyed by the file (`rootIndex:path`) and tagged with
/// its workspace, so the drafts of one workspace can be listed or removed
/// together and a single file's draft can be replaced without touching the
/// rest. The engine keeps them in its database, which survives the app, so
/// unsaved text is still there after a restart or a crash.
final class EngineDraftStore implements DraftStore {
  EngineDraftStore({
    required this.clientProvider,
    required this.clientName,
    this.timeout = const Duration(seconds: 10),
  });

  /// Returns the engine client, or null while the engine is not connected.
  final RestEngineClient? Function() clientProvider;

  /// The settings `client` column value that marks rows owned by this app.
  final String clientName;
  final Duration timeout;

  static String tagFor(String workspaceUuid) => 'editor-draft:$workspaceUuid';

  RestEngineClient _client() =>
      clientProvider() ?? (throw const FileUnavailableException());

  @override
  Future<Map<String, EditorDraft>> loadAll(String workspaceUuid) async {
    final List<EngineSetting> rows = await _client()
        .getSettings(tag: tagFor(workspaceUuid), client: clientName)
        .timeout(timeout);
    final Map<String, EditorDraft> drafts = <String, EditorDraft>{};
    for (final EngineSetting row in rows) {
      final EditorDraft? draft = EditorDraft.tryDecode(row.key, row.value);
      if (draft != null) drafts[draft.key] = draft;
    }
    return drafts;
  }

  @override
  Future<void> save(String workspaceUuid, EditorDraft draft) async {
    await _client()
        .putSettings(<EngineSetting>[
          EngineSetting(
            key: draft.key,
            value: draft.encode(),
            tag: tagFor(workspaceUuid),
            client: clientName,
          ),
        ])
        .timeout(timeout);
  }

  @override
  Future<void> remove(String workspaceUuid, String key) async {
    await _client()
        .deleteSettings(
          key: key,
          tag: tagFor(workspaceUuid),
          client: clientName,
        )
        .timeout(timeout);
  }

  @override
  Future<void> removeAll(String workspaceUuid) async {
    await _client()
        .deleteSettings(tag: tagFor(workspaceUuid), client: clientName)
        .timeout(timeout);
  }
}
