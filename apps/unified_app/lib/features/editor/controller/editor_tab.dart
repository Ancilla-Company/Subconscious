import 'package:flutter/services.dart';

import 'file_gateway.dart';
import 'workspace_paths.dart';

/// Which editor a text file opens in.
enum EditorKind {
  /// Markdown source with live styling and an optional rendered preview.
  markdown,

  /// Prose or data in a plain wrapped text field.
  plainText,

  /// Source code with syntax highlighting.
  code;

  static EditorKind forPath(String path) {
    final String lower = path.toLowerCase();
    if (lower.endsWith('.md') || lower.endsWith('.markdown')) {
      return EditorKind.markdown;
    }
    if (lower.endsWith('.txt')) return EditorKind.plainText;
    return EditorKind.code;
  }
}

/// How the file on disk differs from what an open tab was based on.
enum ExternalChange {
  /// The file on disk is what the tab was loaded from or last saved as.
  none,

  /// Another program, or the AI assistant, changed the file after the tab
  /// loaded it.
  changed,

  /// The file was removed or moved away from this path.
  deleted,
}

/// One open file in the editor.
sealed class EditorTab {
  EditorTab({
    required this.workspaceUuid,
    required this.rootIndex,
    required this.path,
  });

  /// The workspace this file belongs to. Kept on the tab so that a save can
  /// never be sent to whichever workspace happens to be active later.
  final String workspaceUuid;
  int rootIndex;
  String path;

  String get key => workspaceFileKey(rootIndex, path);

  String get name => normalizeWorkspacePath(path).split('/').last;

  WorkspaceFileReference get reference =>
      WorkspaceFileReference(rootIndex: rootIndex, path: path);
}

/// An image or document shown read-only.
final class PreviewTab extends EditorTab {
  PreviewTab({
    required super.workspaceUuid,
    required super.rootIndex,
    required super.path,
    required this.bytes,
    required this.kind,
    required this.mediaType,
  });

  final Uint8List bytes;
  final PreviewKind kind;
  final String mediaType;

  bool get isImage => kind == PreviewKind.image;
  bool get isDocument => kind == PreviewKind.pdf || kind == PreviewKind.docx;
  bool get isSvg => mediaType == 'image/svg+xml';
}

/// A text file being edited.
///
/// The editor text is authoritative while the tab is open. [savedText] is what
/// the file held at the last read or successful save, so the tab is dirty
/// exactly when the two differ, and undoing back to the saved text clears it.
final class TextTab extends EditorTab {
  TextTab({
    required super.workspaceUuid,
    required super.rootIndex,
    required super.path,
    required this.text,
    required this.savedText,
    required this.diskVersion,
    required this.crlf,
    TextSelection? selection,
  }) : kind = EditorKind.forPath(path),
       selection = selection ?? const TextSelection.collapsed(offset: 0);

  /// Files longer than this lose live styling and other per-keystroke work,
  /// because a text field lays out the whole document on every change.
  static const int largeFileChars = 200000;

  final EditorKind kind;

  /// The text in the editor, with `\n` line breaks unless the file mixes styles.
  String text;

  /// The text as of the last read or successful save.
  String savedText;

  /// The engine's version of the bytes that [savedText] came from.
  String? diskVersion;

  /// Whether the file uses CRLF on disk and gets it back when written.
  bool crlf;

  TextSelection selection;

  /// How far the editor was scrolled when the tab was last shown, so switching
  /// tabs brings the view back to the same place.
  double scrollOffset = 0;

  ExternalChange external = ExternalChange.none;

  /// The version found on disk when [external] is [ExternalChange.changed].
  String? externalVersion;

  bool isSaving = false;

  /// The last save failure, cleared by the next attempt.
  Object? saveError;

  /// Set when this tab's text came back from a stored draft after a restart.
  bool recoveredFromDraft = false;

  /// Bumped whenever the text is replaced from outside the editor, so the text
  /// field rebuilds instead of keeping stale content.
  int revision = 0;

  bool get isDirty => text != savedText;

  bool get isLarge => text.length > largeFileChars;

  /// Whether a save would be attempted against a file that is not as expected.
  bool get hasExternalChange => external != ExternalChange.none;
}
