import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'channel_codec.dart';
import 'peer_link.dart';

const int maxTunnelRequestBytes = 4 * 1024 * 1024;
const Duration tunnelRequestTimeout = Duration(seconds: 60);
const Set<String> _allowedRequestHeaders = <String>{
  'content-type',
  'accept',
  'accept-language',
};

/// REST over the `rpc` data channel (webrtc.md 6.2).
///
/// Request:  `{id, type:"http.request", data:{method, path, query, headers, body}}`
/// Response: `{id, type:"http.response", data:{status, headers, body}}`
/// with base64 bodies. Inject into `RestEngineClient(client: ...)`. The
/// engine authorises by peer role, so no bearer token is sent or needed.
final class DataChannelHttpClient extends http.BaseClient {
  DataChannelHttpClient({
    required PeerLink link,
    this.timeout = tunnelRequestTimeout,
  }) : _link = link {
    _subscription = link.envelopes.listen(_onEnvelope);
    unawaited(link.done.then<void>((_) => _failAll('The peer link closed.')));
  }

  final PeerLink _link;
  final Duration timeout;
  late final StreamSubscription<InboundEnvelope> _subscription;
  final Map<String, Completer<Map<String, dynamic>>> _pending =
      <String, Completer<Map<String, dynamic>>>{};
  int _sequence = 0;
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed || !_link.isOpen) {
      throw http.ClientException('The peer link is closed.', request.url);
    }
    final Uint8List body = await request.finalize().toBytes();
    if (body.length > maxTunnelRequestBytes) {
      throw http.ClientException('Request body is too large.', request.url);
    }
    final String id = 'h-${_sequence++}';
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      await _link.send(
        'rpc',
        Envelope(
          type: 'http.request',
          id: id,
          data: <String, dynamic>{
            'method': request.method.toUpperCase(),
            'path': request.url.path,
            if (request.url.queryParameters.isNotEmpty)
              'query': request.url.queryParameters,
            'headers': <String, String>{
              for (final MapEntry<String, String> e in request.headers.entries)
                if (_allowedRequestHeaders.contains(e.key.toLowerCase()))
                  e.key.toLowerCase(): e.value,
            },
            if (body.isNotEmpty) 'body': base64.encode(body),
          },
        ),
      );
      final Map<String, dynamic> data = await completer.future.timeout(
        timeout,
        onTimeout: () => throw http.ClientException(
          'The remote engine did not respond in time.',
          request.url,
        ),
      );
      final int status = (data['status'] as num?)?.toInt() ?? 502;
      final Object? rawBody = data['body'];
      final Uint8List bytes = rawBody is String && rawBody.isNotEmpty
          ? base64.decode(rawBody)
          : Uint8List(0);
      final Object? rawHeaders = data['headers'];
      final Map<String, String> headers = <String, String>{
        if (rawHeaders is Map)
          for (final MapEntry<dynamic, dynamic> e in rawHeaders.entries)
            '${e.key}'.toLowerCase(): '${e.value}',
        'content-length': '${bytes.length}',
      };
      return http.StreamedResponse(
        Stream<List<int>>.value(bytes),
        status,
        contentLength: bytes.length,
        request: request,
        headers: headers,
      );
    } finally {
      _pending.remove(id);
    }
  }

  void _onEnvelope(InboundEnvelope inbound) {
    if (inbound.channel != 'rpc' || inbound.envelope.type != 'http.response') {
      return;
    }
    final String? id = inbound.envelope.id;
    final Map<String, dynamic>? data = inbound.envelope.dataMap;
    if (id == null || data == null) return;
    final Completer<Map<String, dynamic>>? completer = _pending[id];
    if (completer != null && !completer.isCompleted) completer.complete(data);
  }

  void _failAll(String message) {
    for (final Completer<Map<String, dynamic>> c in _pending.values.toList()) {
      if (!c.isCompleted) c.completeError(http.ClientException(message));
    }
  }

  @override
  void close() {
    _closed = true;
    _failAll('The client was closed.');
    unawaited(_subscription.cancel());
  }
}
