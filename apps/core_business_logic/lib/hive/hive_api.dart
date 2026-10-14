import 'dart:convert';

import 'package:http/http.dart' as http;

final class HiveApiException implements Exception {
  const HiveApiException(this.message, [this.statusCode = 502]);
  final String message;
  final int statusCode;
  @override
  String toString() => 'HiveApiException($statusCode): $message';
}

/// Client for the server's `/nodes` registry. Never logs tokens.
final class HiveApi {
  HiveApi({
    required Uri baseUri,
    required this.accessToken,
    this.refreshAccessToken,
    http.Client? client,
  }) : baseUri = _withSlash(baseUri),
       _client = client ?? http.Client();

  final Uri baseUri;
  final String? Function() accessToken;

  /// Called once on a 401 before retrying.
  final Future<void> Function()? refreshAccessToken;
  final http.Client _client;

  Future<void> close() async => _client.close();

  Future<Map<String, dynamic>> register(Map<String, dynamic> body) =>
      _map('POST', 'nodes', body);

  Future<Map<String, dynamic>> listNodes() => _map('GET', 'nodes');

  Future<void> approve({
    required String nodeId,
    required String approverNodeId,
    required String approvalSig,
  }) async {
    await _map('POST', 'nodes/$nodeId/approve', <String, dynamic>{
      'approver_node_id': approverNodeId,
      'approval_sig': approvalSig,
    });
  }

  Future<void> revoke(String nodeId) async {
    await _map('DELETE', 'nodes/$nodeId');
  }

  Future<Map<String, dynamic>> createInvite(String nodeId) =>
      _map('POST', 'nodes/invites', <String, dynamic>{}, nodeId);

  /// `{ticket, challenge, expires_in}`.
  Future<Map<String, dynamic>> signalTicket(String nodeId) =>
      _map('POST', 'nodes/$nodeId/signal-ticket', <String, dynamic>{});

  /// `{ice_servers: [{urls, username?, credential?}], ws_relay_enabled, ttl}`.
  Future<Map<String, dynamic>> iceConfig(String nodeId) =>
      _map('POST', 'nodes/$nodeId/ice-config', <String, dynamic>{});

  Future<Map<String, dynamic>> _map(
    String method,
    String path, [
    Map<String, dynamic>? body,
    String? nodeId,
  ]) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      final String? token = accessToken();
      if (token == null || token.isEmpty) {
        throw const HiveApiException('Sign in to use the hive.', 401);
      }
      final http.Request request = http.Request(method, baseUri.resolve(path))
        ..headers['Authorization'] = 'Bearer $token'
        ..headers['Accept'] = 'application/json';
      if (nodeId != null) request.headers['X-Node-Id'] = nodeId;
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      final http.StreamedResponse streamed;
      final String text;
      try {
        streamed = await _client.send(request);
        text = await streamed.stream.bytesToString();
      } on Object {
        throw const HiveApiException('Could not reach the hive server.');
      }
      if (streamed.statusCode == 401 &&
          attempt == 0 &&
          refreshAccessToken != null) {
        await refreshAccessToken!();
        continue;
      }
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        throw HiveApiException(_errorText(text, streamed.statusCode), streamed.statusCode);
      }
      if (text.trim().isEmpty) return <String, dynamic>{};
      try {
        final Object? decoded = jsonDecode(text);
        if (decoded is Map) return decoded.cast<String, dynamic>();
      } on FormatException {
        // Fall through.
      }
      throw const HiveApiException('The hive server returned an invalid response.');
    }
    throw const HiveApiException('The hive server rejected the session.', 401);
  }
}

String _errorText(String body, int status) {
  try {
    final Object? value = jsonDecode(body);
    if (value is Map) {
      for (final String key in <String>['message', 'error', 'detail']) {
        final Object? text = value[key];
        if (text is String && text.trim().isNotEmpty) {
          return text.trim().length > 200 ? text.trim().substring(0, 200) : text.trim();
        }
      }
    }
  } on FormatException {
    // Use the generic message.
  }
  return 'The hive server returned status $status.';
}

Uri _withSlash(Uri value) =>
    value.path.endsWith('/') ? value : value.replace(path: '${value.path}/');
