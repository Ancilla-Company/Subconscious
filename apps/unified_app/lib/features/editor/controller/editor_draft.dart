import 'dart:convert';

import 'workspace_paths.dart';

/// Unsaved text kept outside the editor so it survives a restart or a crash.
///
/// A draft is tied to the version of the file it was typed against. If the file
/// has moved on by the time the draft is restored, the editor knows the draft
/// and the file have diverged instead of silently preferring one.
final class EditorDraft {
  const EditorDraft({
    required this.rootIndex,
    required this.path,
    required this.text,
    required this.baseVersion,
    required this.crlf,
    required this.selectionBase,
    required this.selectionExtent,
    required this.savedAt,
  });

  final int rootIndex;
  final String path;

  /// The editor text, with `\n` line breaks.
  final String text;

  /// The version of the file on disk that [text] was written against.
  final String? baseVersion;

  /// Whether the file uses CRLF line breaks on disk.
  final bool crlf;
  final int selectionBase;
  final int selectionExtent;
  final DateTime savedAt;

  String get key => workspaceFileKey(rootIndex, path);

  static const int formatVersion = 1;

  /// The settings value that stores this draft.
  String encode() => jsonEncode(<String, dynamic>{
    'v': formatVersion,
    'text': text,
    'base': baseVersion,
    'crlf': crlf,
    'sel': <int>[selectionBase, selectionExtent],
    'at': savedAt.toUtc().toIso8601String(),
  });

  /// Reads a draft from its settings [key] (`rootIndex:path`) and [value].
  ///
  /// Returns null for anything that is not a well-formed draft, so one bad row
  /// cannot stop the other drafts from being restored.
  static EditorDraft? tryDecode(String key, String value) {
    final int separator = key.indexOf(':');
    if (separator < 1) return null;
    final int? rootIndex = int.tryParse(key.substring(0, separator));
    final String path = key.substring(separator + 1);
    if (rootIndex == null || rootIndex < 0 || path.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(value);
      if (decoded is! Map || decoded['v'] != formatVersion) return null;
      final Object? text = decoded['text'];
      if (text is! String) return null;
      final Object? selection = decoded['sel'];
      int base = text.length;
      int extent = text.length;
      if (selection is List &&
          selection.length == 2 &&
          selection[0] is int &&
          selection[1] is int) {
        base = (selection[0] as int).clamp(0, text.length);
        extent = (selection[1] as int).clamp(0, text.length);
      }
      return EditorDraft(
        rootIndex: rootIndex,
        path: path,
        text: text,
        baseVersion: decoded['base'] is String
            ? decoded['base'] as String
            : null,
        crlf: decoded['crlf'] == true,
        selectionBase: base,
        selectionExtent: extent,
        savedAt:
            DateTime.tryParse('${decoded['at']}') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
    } on FormatException {
      return null;
    }
  }
}
