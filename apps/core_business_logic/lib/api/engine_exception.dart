import 'dart:convert';

import 'package:http/http.dart' as http;

final class EngineApiException implements Exception {
  EngineApiException({required this.method, required this.uri, required this.statusCode, this.body});
  final String method;
  final Uri uri;
  final int statusCode;
  final String? body;

  Map<String, dynamic>? get _json {
    final String? text = body;
    if (text == null || text.trim().isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(text);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } on FormatException {
      return null;
    }
  }

  /// Machine-readable error code from the engine, such as `version_conflict`.
  String? get code => _json?['code'] as String?;

  /// The engine's own message, without the request line.
  String? get engineMessage => _json?['error'] as String?;

  /// True when a guarded write was refused because the file changed on disk.
  bool get isVersionConflict => statusCode == 409 && code == 'version_conflict';

  /// Version of the file as it is now on disk, reported with a conflict.
  String? get currentVersion => _json?['currentVersion'] as String?;

  @override
  String toString() {
    final suffix = body == null || body!.trim().isEmpty ? '' : ' — ${body!.trim().substring(0, body!.trim().length.clamp(0, 300))}';
    return '$method ${uri.path} failed: $statusCode$suffix';
  }
}

EngineApiException apiException(http.BaseRequest request, http.StreamedResponse response, String? body) => EngineApiException(method: request.method, uri: request.url, statusCode: response.statusCode, body: body);
