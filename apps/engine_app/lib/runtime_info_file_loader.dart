import 'dart:convert';
import 'dart:io';

import 'package:core_business_logic/core_business_logic.dart';

/// Desktop/CLI runtime discovery adapter. The core discovery contract remains
/// platform-neutral; only this host package touches the local filesystem.
final class FileRuntimeInfoLoader implements RuntimeInfoLoader {
  const FileRuntimeInfoLoader({required this.directory});

  final String directory;

  @override
  Future<EngineRuntimeInfo?> load() async {
    try {
      final String contents = await File('$directory/runtime.json').readAsString();
      final dynamic decoded = jsonDecode(contents);
      if (decoded is! Map) return null;
      return EngineRuntimeInfo.fromJson(decoded.cast<String, dynamic>());
    } on IOException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}
