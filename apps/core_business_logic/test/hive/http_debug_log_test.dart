import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const String _bearer = 'abcdef0123456789SECRETTOKEN';

void main() {
  late List<String> lines;

  LoggingHttpClient make(
    http.Response Function(http.Request) handler, {
    bool verbose = true,
    bool enabled = true,
  }) => LoggingHttpClient(
    MockClient((http.Request r) async => handler(r)),
    sink: lines.add,
    verbose: verbose,
    enabled: enabled,
  );

  setUp(() => lines = <String>[]);

  test('header redaction shows only length and last 4 chars', () {
    final String out = redactHeaderValue('Authorization', 'Bearer $_bearer');
    expect(out, contains('len=${'Bearer $_bearer'.length}'));
    expect(out, contains('last4=OKEN'));
    expect(out, isNot(contains('SECRET')));
    expect(redactHeaderValue('Authorization', 'short'), '<redacted len=5>');
    expect(redactHeaderValue('Accept', 'application/json'), 'application/json');
  });

  test('401 login logs status/url/elapsed and never secrets', () async {
    final LoggingHttpClient client = make(
      (http.Request r) => http.Response(
        jsonEncode(<String, dynamic>{'detail': 'Invalid email or password'}),
        401,
        headers: <String, String>{'content-type': 'application/json'},
      ),
    );
    final http.Response res = await client.post(
      Uri.parse('https://api.test/auth/email/login?native=true'),
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_bearer',
      },
      body: jsonEncode(<String, dynamic>{
        'email': 'alice@example.com',
        'password': 'hunter2-secret',
      }),
    );
    expect(res.statusCode, 401);
    expect(res.body, contains('Invalid email or password'));
    final String out = lines.join('\n');
    expect(out, contains('[http] POST https://api.test/auth/email/login'));
    expect(out, contains('-> 401'));
    expect(out, contains('ms'));
    expect(out, contains('Invalid email or password'));
    expect(out, contains('a***@example.com'));
    for (final String secret in <String>[
      'hunter2-secret',
      _bearer,
      'alice@example.com',
    ]) {
      expect(out, isNot(contains(secret)));
    }
  });

  test('tokens, codes and verifiers in bodies and queries are redacted', () async {
    final LoggingHttpClient client = make(
      (http.Request r) => http.Response(
        jsonEncode(<String, dynamic>{
          'access_token': 'ACCESS-SECRET-1',
          'refresh_token': 'REFRESH-SECRET-2',
          'user': <String, dynamic>{'id': 'u-1', 'email': 'a@b.c'},
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      ),
    );
    await client.post(
      Uri.parse('https://api.test/auth/native/token?code_verifier=VERIFIER-9'),
      body: jsonEncode(<String, dynamic>{
        'code': 'CODE-123456',
        'code_verifier': 'VERIFIER-9',
      }),
    );
    final String out = lines.join('\n');
    for (final String secret in <String>[
      'ACCESS-SECRET-1',
      'REFRESH-SECRET-2',
      'CODE-123456',
      'VERIFIER-9',
    ]) {
      expect(out, isNot(contains(secret)));
    }
    expect(out, contains('<redacted len=15>'));
    expect(out, contains('"id":"u-1"'));
  });

  test('response body is truncated to 2048 chars with a marker', () async {
    final LoggingHttpClient client = make(
      (http.Request r) => http.Response(
        jsonEncode(<String, dynamic>{'detail': 'x' * 5000}),
        500,
        headers: <String, String>{'content-type': 'application/json'},
      ),
    );
    await client.get(Uri.parse('https://api.test/nodes'));
    final String out = lines.single;
    expect(out, contains('(truncated'));
    expect(out.length, lessThan(2048 + 300));
  });

  test('non-JSON text has bearer values removed; binary is not printed', () {
    expect(
      redactBody('oops Bearer $_bearer end', 'text/plain'),
      isNot(contains(_bearer)),
    );
    expect(redactBody('RAWBYTES', 'audio/wav'), isNot(contains('RAWBYTES')));
  });

  test('default (not verbose) logs one line without bodies', () async {
    final LoggingHttpClient client = make(
      (http.Request r) => http.Response('{"access_token":"TOPSECRET"}', 200),
      verbose: false,
    );
    final http.Response res = await client.post(
      Uri.parse('https://api.test/x'),
      body: '{"password":"pw-secret"}',
    );
    expect(res.body, contains('TOPSECRET'), reason: 'caller still gets body');
    expect(lines, hasLength(1));
    expect(lines.single, matches(RegExp(r'^\[http\] POST https://api\.test/x -> 200 \d+ms$')));
  });

  test('disabled logs nothing; errors are logged and rethrown', () async {
    await make((http.Request r) => http.Response('', 200), enabled: false)
        .get(Uri.parse('https://api.test/x'));
    expect(lines, isEmpty);
    final LoggingHttpClient failing = LoggingHttpClient(
      MockClient((http.Request r) async => throw Exception('boom')),
      sink: lines.add,
      enabled: true,
      verbose: false,
    );
    await expectLater(
      failing.get(Uri.parse('https://api.test/x')),
      throwsException,
    );
    expect(lines.single, contains('failed'));
  });
}
