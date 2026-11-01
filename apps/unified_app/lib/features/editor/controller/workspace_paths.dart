/// Workspace-relative path helpers shared by the dashboard and the editor.
library;

/// Returns [path] with forward slashes, the form the engine always uses.
String normalizeWorkspacePath(String path) => path.replaceAll('\\', '/');

/// The stable key of a file within one of a workspace's directory roots.
String workspaceFileKey(int rootIndex, String path) =>
    '$rootIndex:${normalizeWorkspacePath(path)}';

/// A stable reference to a file within one of a workspace's directory roots.
final class WorkspaceFileReference {
  WorkspaceFileReference({required this.rootIndex, required this.path})
    : key = workspaceFileKey(rootIndex, path);

  final int rootIndex;
  final String path;
  final String key;

  factory WorkspaceFileReference.fromJson(Map<String, dynamic> json) {
    final Object? rootIndex = json['rootIndex'];
    final Object? path = json['path'];
    if (rootIndex is! int || rootIndex < 0 || path is! String || path.isEmpty) {
      throw const FormatException('Invalid workspace file reference.');
    }
    return WorkspaceFileReference(rootIndex: rootIndex, path: path);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'rootIndex': rootIndex,
    'path': path,
    'key': key,
  };
}

/// A file or directory that was moved inside one workspace root.
final class WorkspaceFileMove {
  const WorkspaceFileMove({
    required this.sourceRootIndex,
    required this.sourcePath,
    required this.destinationRootIndex,
    required this.destinationPath,
    required this.isDirectory,
  });

  final int sourceRootIndex;
  final String sourcePath;
  final int destinationRootIndex;
  final String destinationPath;
  final bool isDirectory;
}

/// Returns where [path] ends up after [move], or null when it is unaffected.
String? rebaseWorkspacePath({
  required int rootIndex,
  required String path,
  required WorkspaceFileMove move,
}) {
  if (rootIndex != move.sourceRootIndex) return null;
  final String normalized = normalizeWorkspacePath(path);
  final String source = normalizeWorkspacePath(move.sourcePath);
  if (normalized == source) return move.destinationPath;
  if (move.isDirectory && normalized.startsWith('$source/')) {
    return '${move.destinationPath}${normalized.substring(source.length)}';
  }
  return null;
}

/// Whether [path] in [rootIndex] is [targetPath] itself or, when the target is
/// a directory, anything inside it. Used to find what a delete takes with it.
bool isWorkspacePathAtOrUnder({
  required int rootIndex,
  required String path,
  required int targetRootIndex,
  required String targetPath,
  required bool targetIsDirectory,
}) {
  if (rootIndex != targetRootIndex) return false;
  final String normalized = normalizeWorkspacePath(path);
  final String target = normalizeWorkspacePath(targetPath);
  if (normalized == target) return true;
  return targetIsDirectory && normalized.startsWith('$target/');
}
