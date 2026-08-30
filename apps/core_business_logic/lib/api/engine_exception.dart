import 'package:http/http.dart' as http;

final class EngineApiException implements Exception {
  EngineApiException({required this.method, required this.uri, required this.statusCode, this.body});
  final String method;
  final Uri uri;
  final int statusCode;
  final String? body;

  @override
  String toString() {
    final suffix = body == null || body!.trim().isEmpty ? '' : ' — ${body!.trim().substring(0, body!.trim().length.clamp(0, 300))}';
    return '$method ${uri.path} failed: $statusCode$suffix';
  }
}

EngineApiException apiException(http.BaseRequest request, http.StreamedResponse response, String? body) => EngineApiException(method: request.method, uri: request.url, statusCode: response.statusCode, body: body);
