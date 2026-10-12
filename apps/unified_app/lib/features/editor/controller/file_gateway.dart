import 'dart:typed_data';

import 'editor_draft.dart';

/// How a file that cannot be edited as text is shown instead.
enum PreviewKind {
  image,
  pdf,
  docx;

  /// The preview kind for [path], or null for files that are edited as text.
  static PreviewKind? forPath(String path) {
    final String lower = path.toLowerCase();
    if (const <String>[
      '.bmp',
      '.gif',
      '.jpeg',
      '.jpg',
      '.png',
      '.svg',
      '.webp',
    ].any(lower.endsWith)) {
      return PreviewKind.image;
    }
    if (lower.endsWith('.pdf')) return PreviewKind.pdf;
    if (lower.endsWith('.docx')) return PreviewKind.docx;
    return null;
  }
}

/// A text file as read from disk.
final class FileSnapshot {
  const FileSnapshot({required this.text, required this.version});

  /// The content exactly as stored, with the original line breaks.
  final String text;

  /// The version token the engine reported for these bytes.
  final String? version;
}

/// A read-only rendering source for an image or document.
final class PreviewSnapshot {
  const PreviewSnapshot({
    required this.bytes,
    required this.kind,
    required this.mediaType,
  });

  final Uint8List bytes;
  final PreviewKind kind;
  final String mediaType;
}

/// The engine could not be reached, so nothing was read or written.
final class FileUnavailableException implements Exception {
  const FileUnavailableException([
    this.message = 'The Subconscious engine is not connected.',
  ]);

  final String message;

  @override
  String toString() => message;
}

/// The file no longer exists on disk.
final class FileMissingException implements Exception {
  const FileMissingException();

  @override
  String toString() => 'The file no longer exists on disk.';
}

/// A write was refused because the file on disk changed after it was read.
final class FileConflictException implements Exception {
  const FileConflictException({this.currentVersion});

  /// The version now on disk, when the engine reported it.
  final String? currentVersion;

  @override
  String toString() => 'The file changed on disk after it was opened.';
}

/// Reads and writes workspace files for the editor.
///
/// Every call names its workspace explicitly. A save that started in one
/// workspace must never land in another because the user switched while it was
/// in flight.
abstract interface class FileGateway {
  /// Whether requests can be attempted right now.
  bool get isAvailable;

  Future<FileSnapshot> readText(
    String workspaceUuid,
    int rootIndex,
    String path,
  );

  Future<PreviewSnapshot> readPreview(
    String workspaceUuid,
    int rootIndex,
    String path,
  );

  /// Overwrites the file and returns the new version.
  ///
  /// With [expectedVersion] the write is refused with a
  /// [FileConflictException] when the file on disk is not at that version.
  Future<String?> write(
    String workspaceUuid,
    int rootIndex,
    String path,
    String content, {
    String? expectedVersion,
  });

  /// Creates a file that does not exist and returns its version.
  Future<String?> create(
    String workspaceUuid,
    int rootIndex,
    String path,
    String content,
  );

  /// The version of the file on disk. Throws [FileMissingException] when the
  /// file is gone.
  Future<String> currentVersion(
    String workspaceUuid,
    int rootIndex,
    String path,
  );
}

/// Keeps unsaved editor text outside the process.
abstract interface class DraftStore {
  /// All drafts stored for [workspaceUuid], keyed by file key.
  Future<Map<String, EditorDraft>> loadAll(String workspaceUuid);

  Future<void> save(String workspaceUuid, EditorDraft draft);

  Future<void> remove(String workspaceUuid, String key);

  Future<void> removeAll(String workspaceUuid);
}
