import 'dart:convert';

import 'package:http/http.dart' as http;

/// `--dart-define=SUBCONSCIOUS_HTTP_LOG=verbose` adds redacted request and
/// response bodies to the per-request line (debug builds only).
const String httpLogFlag = String.fromEnvironment('SUBCONSCIOUS_HTTP_LOG');

/// Receives one finished log line. The app sets this to `debugPrint`.
typedef HttpLogSink = void Function(String line);

/// Max response body characters printed.
const int httpLogBodyLimit = 2048;

const int _maxBufferedBytes = 64 * 1024;

bool get _isDebugBuild {
  bool debug = false;
  assert(debug = true);
  return debug;
}

// ignore: avoid_print
void _printSink(String line) => print(line);

/// Global sink for [LoggingHttpClient]; replace in `main` with `debugPrint`.
HttpLogSink httpLogSink = _printSink;

const List<String> _secretHeaders = <String>[
  'authorization',
  'proxy-authorization',
  'cookie',
  'set-cookie',
  'x-api-key',
];

const List<String> _secretKeyParts = <String>[
  'password',
  'token',
  'code',
  'ticket',
  'challenge',
  'secret',
  'credential',
  'signature',
  'approval_sig',
  'seed',
  'private',
];

/// `<redacted len=N>` for [value]; no characters of the value are shown.
String redactedMarker(Object? value) => '<redacted len=${'$value'.length}>';

/// Header value safe to print: presence, length and (when long) last 4 chars.
String redactHeaderValue(String name, String value) {
  if (!_secretHeaders.contains(name.toLowerCase())) return value;
  if (value.length < 12) return '<redacted len=${value.length}>';
  return '<redacted len=${value.length} last4=${value.substring(value.length - 4)}>';
}

String redactEmail(String email) {
  final int at = email.indexOf('@');
  if (at < 1) return redactedMarker(email);
  return '${email[0]}***${email.substring(at)}';
}

bool _isSecretKey(String key) {
  final String lower = key.toLowerCase();
  for (final String part in _secretKeyParts) {
    if (lower.contains(part)) return true;
  }
  return false;
}

Object? _redactValue(String? key, Object? value) {
  if (key != null && _isSecretKey(key)) {
    return value == null ? null : redactedMarker(value);
  }
  if (key != null && key.toLowerCase() == 'email' && value is String) {
    return redactEmail(value);
  }
  if (value is Map) {
    return <String, Object?>{
      for (final MapEntry<dynamic, dynamic> e in value.entries)
        '${e.key}': _redactValue('${e.key}', e.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final Object? item in value) _redactValue(key, item)];
  }
  return value;
}

/// Query string with secret values replaced.
String redactUrl(Uri uri) {
  if (uri.queryParameters.isEmpty) return uri.toString();
  final Map<String, String> query = <String, String>{
    for (final MapEntry<String, String> e in uri.queryParameters.entries)
      e.key: _isSecretKey(e.key)
          ? redactedMarker(e.value)
          : e.key.toLowerCase() == 'email'
          ? redactEmail(e.value)
          : e.value,
  };
  return uri.replace(queryParameters: query).toString();
}


/// Body text safe to print and truncated to [limit] characters. JSON bodies
/// have secret keys redacted at any depth; other content is not printed.
String redactBody(String body, String? contentType, {int limit = httpLogBodyLimit}) {
  final String type = (contentType ?? '').toLowerCase();
  if (body.isEmpty) return '';
  if (body.length > _maxBufferedBytes) {
    return '<body omitted, ${body.length} bytes>';
  }
  String text;
  try {
    text = jsonEncode(_redactValue(null, jsonDecode(body)));
  } on FormatException {
    final String label = type.isEmpty ? 'unknown' : type.split(';').first;
    return '<$label ${body.length} bytes>';
  }
  if (text.length <= limit) return text;
  return '${text.substring(0, limit)}...(truncated ${text.length - limit} chars)';
}

/// [http.Client] wrapper logging method, URL, status and elapsed time of every
/// request. Verbose mode (`SUBCONSCIOUS_HTTP_LOG=verbose`, debug builds) also
/// logs redacted bodies. Secrets are never printed.
final class LoggingHttpClient extends http.BaseClient {
  LoggingHttpClient(
    this._inner, {
    HttpLogSink? sink,
    bool? enabled,
    bool? verbose,
  }) : _sink = sink,
       enabled = enabled ?? _isDebugBuild,
       verbose = verbose ?? (_isDebugBuild && httpLogFlag == 'verbose');

  final http.Client _inner;
  final HttpLogSink? _sink;
  final bool enabled;
  final bool verbose;

  void _log(String line) => (_sink ?? httpLogSink)(line);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!enabled) return _inner.send(request);
    final Stopwatch watch = Stopwatch()..start();
    final String head = '[http] ${request.method} ${redactUrl(request.url)}';
    final String? requestBody = verbose && request is http.Request
        ? redactBody(request.body, request.headers['Content-Type'])
        : null;
    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } on Object catch (error) {
      _log('$head -> failed ${watch.elapsedMilliseconds}ms (${error.runtimeType})');
      rethrow;
    }
    if (!verbose) {
      _log('$head -> ${response.statusCode} ${watch.elapsedMilliseconds}ms');
      return response;
    }
    final List<int> bytes = await response.stream.toBytes();
    final String type = response.headers['content-type'] ?? '';
    String text = '';
    if (bytes.length <= _maxBufferedBytes) {
      text = redactBody(utf8.decode(bytes, allowMalformed: true), type);
    } else {
      text = '<body omitted, ${bytes.length} bytes>';
    }
    final StringBuffer line = StringBuffer(
      '$head -> ${response.statusCode} ${watch.elapsedMilliseconds}ms',
    );
    if (requestBody != null && requestBody.isNotEmpty) {
      line.write(' req=$requestBody');
    }
    if (text.isNotEmpty) line.write(' res=$text');
    _log(line.toString());
    return http.StreamedResponse(
      http.ByteStream.fromBytes(bytes),
      response.statusCode,
      contentLength: bytes.length,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}

/// Shared factory: a logging wrapper around a fresh [http.Client].
http.Client createLoggingClient() => LoggingHttpClient(http.Client());
