import 'dart:convert';

import 'package:http/http.dart' as http;

import 'http_debug_log.dart';

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
    this.onUnauthorized,
    http.Client? client,
    this.retryDelays = defaultRetryDelays,
    Future<void> Function(Duration)? retrySleep,
  }) : baseUri = _withSlash(baseUri),
       _client = client ?? createLoggingClient(),
       _retrySleep = retrySleep ?? Future<void>.delayed;

  final Uri baseUri;
  final String? Function() accessToken;

  /// Called once on a 401 before retrying.
  final Future<void> Function()? refreshAccessToken;

  /// Called when the server still answers 401 after a refresh attempt.
  final Future<void> Function(String reason)? onUnauthorized;

  /// 1, 2 and 4 seconds.
  static const List<Duration> defaultRetryDelays = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];

  /// Waits between retries of an idempotent GET on 502/503/504 or a network
  /// error. Non-GET requests are never retried.
  final List<Duration> retryDelays;
  final Future<void> Function(Duration) _retrySleep;

  final http.Client _client;

  Future<void> close() async => _client.close();

  Future<Map<String, dynamic>> register(Map<String, dynamic> body) =>
      _map('POST', 'nodes', body);

  /// Lists the account's nodes. With [callerNodeId] the server also answers
  /// `caller_online` (and logs a warning when the caller has no live
  /// signalling socket); send it only on a user refresh, after signalling had
  /// its chance to connect.
  Future<Map<String, dynamic>> listNodes({String? callerNodeId}) =>
      _map('GET', 'nodes', null, callerNodeId);

  /// Folds [nodeId] under an engine ([parentNodeId]) or clears the link when
  /// null. Old servers answer 404/405.
  Future<Map<String, dynamic>> setParent(String nodeId, String? parentNodeId) =>
      _map('PATCH', 'nodes/$nodeId', <String, dynamic>{
        'parent_node_id': parentNodeId,
      });

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
    final List<Duration> delays = method == 'GET' ? retryDelays : const <Duration>[];
    for (int retry = 0; ; retry++) {
      try {
        return await _send(method, path, body, nodeId);
      } on HiveApiException catch (caught) {
        final bool transient =
            caught.statusCode == 502 ||
            caught.statusCode == 503 ||
            caught.statusCode == 504;
        if (!transient || retry >= delays.length) rethrow;
        await _retrySleep(delays[retry]);
      }
    }
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, dynamic>? body,
    String? nodeId,
  ) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      final String? token = accessToken();
      if (token == null || token.isEmpty) {
        await onUnauthorized?.call('Sign in to use the hive.');
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
      if (streamed.statusCode == 401) {
        final String reason = _errorText(text, 401);
        await onUnauthorized?.call(reason);
        throw HiveApiException(reason, 401);
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
