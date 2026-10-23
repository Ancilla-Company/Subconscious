// Shared attach-and-gate helper of the Dart live (end-to-end) test tier.
//
// The Python side owns the stack: `scripts/live_stack.py` boots the REAL
// subconscious-server and REAL engine processes and writes `stack.json`.
// Dart live tests never start the stack, they only attach to it.
//
// unified_app's live tests import this file by relative path
// (`../../../core_business_logic/test/live/live_stack.dart`). It therefore uses
// only `dart:*` and `package:http` (a dependency of both packages), not
// `package:test`, so the same code compiles in either package.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Skip message of every live test when no stack is reachable.
const String liveSkipReason =
    'live test: start the stack with the task "Live: Start stack" '
    '(or set SC_LIVE_STACK=<path to stack.json>)';

/// An account seeded by the stack launcher.
final class LiveAccount {
  const LiveAccount({
    required this.label,
    required this.email,
    required this.password,
    required this.userId,
    required this.accessToken,
    required this.refreshToken,
  });

  factory LiveAccount.fromJson(String label, Map<String, dynamic> json) =>
      LiveAccount(
        label: label,
        email: json['email'] as String,
        password: json['password'] as String,
        userId: json['userId'] as String,
        accessToken: json['accessToken'] as String,
        refreshToken: json['refreshToken'] as String,
      );

  final String label;
  final String email;
  final String password;
  final String userId;

  /// Issued by the launcher. Fine for plain REST checks; clients under test
  /// sign in themselves (a refresh token is single use, so it is never spent
  /// here).
  final String accessToken;
  final String refreshToken;
}

/// A real engine process of the stack.
final class LiveEngine {
  const LiveEngine({
    required this.name,
    required this.account,
    required this.url,
    required this.token,
    required this.nodeId,
  });

  factory LiveEngine.fromJson(Map<String, dynamic> json) => LiveEngine(
    name: json['name'] as String,
    account: json['account'] as String,
    url: json['url'] as String,
    token: json['token'] as String,
    nodeId: json['nodeId'] as String,
  );

  final String name;

  /// Label of the owning account in [LiveStack.accounts] (`alice`, `bob`).
  final String account;

  /// `http://127.0.0.1:PORT` (loopback).
  final String url;

  /// The engine's master token (full access).
  final String token;
  final String nodeId;

  Uri get uri => Uri.parse(url);
  Map<String, String> get headers => <String, String>{
    'Authorization': 'Bearer $token',
  };
}

/// The attached stack (`stack.json`).
final class LiveStack {
  const LiveStack({
    required this.file,
    required this.serverUrl,
    required this.accounts,
    required this.engines,
  });

  final String file;

  /// `http://127.0.0.1:PORT`, the root of the server (`/nodes`, `/auth/...`).
  final String serverUrl;
  final Map<String, LiveAccount> accounts;
  final List<LiveEngine> engines;

  Uri get serverUri => Uri.parse(serverUrl);
  LiveAccount get alice => accounts['alice']!;
  LiveAccount get bob => accounts['bob']!;

  /// The first engine (alice's).
  LiveEngine get engine => engines.first;

  /// Finds the stack, or null when none is reachable. Never throws.
  ///
  /// The file is `SC_LIVE_STACK`, else `<repo root>/build/live-stack/stack.json`
  /// (the repo root is the nearest parent holding `scripts/live_stack.py`). The
  /// server answers `/health` and the first engine its own `/api/v1/health`
  /// (2 s each), so a stale file left by a crashed launcher counts as absent.
  static Future<LiveStack?> resolve() async {
    try {
      final String? path = stackFilePath();
      if (path == null) return null;
      final File file = File(path);
      if (!file.existsSync()) return null;
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final Map<String, dynamic> json = decoded.cast<String, dynamic>();
      final Map<String, dynamic> server = (json['server'] as Map)
          .cast<String, dynamic>();
      final Map<String, dynamic> accounts = (json['accounts'] as Map)
          .cast<String, dynamic>();
      final LiveStack stack = LiveStack(
        file: file.absolute.path,
        serverUrl: server['url'] as String,
        accounts: <String, LiveAccount>{
          for (final MapEntry<String, dynamic> e in accounts.entries)
            e.key: LiveAccount.fromJson(
              e.key,
              (e.value as Map).cast<String, dynamic>(),
            ),
        },
        engines: <LiveEngine>[
          for (final Object? e in json['engines'] as List)
            LiveEngine.fromJson((e as Map).cast<String, dynamic>()),
        ],
      );
      if (stack.engines.isEmpty) return null;
      if (!await _answers(Uri.parse('${stack.serverUrl}/health'))) return null;
      if (!await _answers(stack.engine.uri.resolve('/api/v1/health'))) {
        return null;
      }
      return stack;
    } on Object {
      return null;
    }
  }

  /// The `stack.json` this run would attach to (it may not exist).
  static String? stackFilePath() {
    final String? env = Platform.environment['SC_LIVE_STACK'];
    if (env != null && env.trim().isNotEmpty) return env.trim();
    Directory dir = Directory.current.absolute;
    for (int i = 0; i < 8; i++) {
      if (File(_join(dir.path, 'scripts', 'live_stack.py')).existsSync()) {
        return _join(dir.path, 'build', 'live-stack', 'stack.json');
      }
      final Directory parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  static String _join(String a, String b, [String? c, String? d]) =>
      <String>[a, b, ?c, ?d].join(Platform.pathSeparator);

  static Future<bool> _answers(Uri url) async {
    final http.Client client = http.Client();
    try {
      final http.Response response = await client
          .get(url)
          .timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } on Object {
      return false;
    } finally {
      client.close();
    }
  }
}

/// Polls [probe] until it returns non-null and returns that value. Throws a
/// [TimeoutException] naming [what] and the last thing seen on timeout.
Future<T> eventually<T extends Object>(
  Future<T?> Function() probe, {
  required String what,
  Duration timeout = const Duration(seconds: 20),
  Duration step = const Duration(milliseconds: 150),
}) async {
  final Stopwatch clock = Stopwatch()..start();
  Object? lastError;
  while (clock.elapsed < timeout) {
    try {
      final T? value = await probe();
      if (value != null) return value;
    } on Object catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(step);
  }
  throw TimeoutException(
    'Timed out after ${timeout.inSeconds} s waiting for: $what'
    '${lastError == null ? '' : ' (last error: $lastError)'}',
  );
}

/// Reads JSON from the server or an engine; throws on a non-2xx status.
Future<Object?> getJson(
  Uri url, {
  Map<String, String> headers = const <String, String>{},
}) async {
  final http.Client client = http.Client();
  try {
    final http.Response response = await client
        .get(url, headers: headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'GET $url -> ${response.statusCode}: ${response.body}',
      );
    }
    return response.body.isEmpty ? null : jsonDecode(response.body);
  } finally {
    client.close();
  }
}

/// The account's nodes as the SERVER lists them (`GET /nodes`), by node id.
Future<Map<String, Map<String, dynamic>>> serverNodes(
  LiveStack stack,
  String accessToken,
) async {
  final Object? body = await getJson(
    stack.serverUri.resolve('/nodes'),
    headers: <String, String>{'Authorization': 'Bearer $accessToken'},
  );
  return <String, Map<String, dynamic>>{
    for (final Object? n in (body! as Map)['nodes'] as List)
      (n! as Map)['id'] as String: (n as Map).cast<String, dynamic>(),
  };
}

/// The engine's own device list (`GET /api/v1/hive/nodes`), by node id.
Future<Map<String, Map<String, dynamic>>> engineNodes(LiveEngine engine) async {
  final Object? body = await getJson(
    engine.uri.resolve('/api/v1/hive/nodes'),
    headers: engine.headers,
  );
  return <String, Map<String, dynamic>>{
    for (final Object? n in (body! as Map)['nodes'] as List)
      (n! as Map)['id'] as String: (n as Map).cast<String, dynamic>(),
  };
}

/// Waits until the server lists [nodeId] and [accept] holds for it.
Future<Map<String, dynamic>> serverNodeIs(
  LiveStack stack,
  String accessToken,
  String nodeId,
  bool Function(Map<String, dynamic>? node) accept, {
  required String what,
  Duration timeout = const Duration(seconds: 15),
}) async {
  Map<String, dynamic>? seen;
  try {
    return await eventually<Map<String, dynamic>>(
      () async {
        seen = (await serverNodes(stack, accessToken))[nodeId];
        return accept(seen) ? (seen ?? <String, dynamic>{}) : null;
      },
      what: what,
      timeout: timeout,
    );
  } on TimeoutException catch (error) {
    throw TimeoutException('${error.message}; last seen on the server: $seen');
  }
}

/// Waits until the engine's device list holds [nodeId] and [accept] holds.
Future<Map<String, dynamic>> engineNodeIs(
  LiveEngine engine,
  String nodeId,
  bool Function(Map<String, dynamic>? node) accept, {
  required String what,
  Duration timeout = const Duration(seconds: 20),
}) async {
  Map<String, dynamic>? seen;
  try {
    return await eventually<Map<String, dynamic>>(
      () async {
        seen = (await engineNodes(engine))[nodeId];
        return accept(seen) ? (seen ?? <String, dynamic>{}) : null;
      },
      what: what,
      timeout: timeout,
    );
  } on TimeoutException catch (error) {
    throw TimeoutException('${error.message}; last seen on the engine: $seen');
  }
}

/// Creates a workspace on the real engine (default model: the dev `echo`
/// model) and returns its uuid.
Future<String> createWorkspace(LiveEngine engine, String name) async {
  final http.Client client = http.Client();
  try {
    final http.Response response = await client
        .post(
          engine.uri.resolve('/api/v1/workspaces'),
          headers: <String, String>{
            ...engine.headers,
            'Content-Type': 'application/json',
          },
          body: jsonEncode(<String, dynamic>{
            'name': name,
            'defaultModelId': 'echo',
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw HttpException(
        'create workspace -> ${response.statusCode}: ${response.body}',
      );
    }
    return (jsonDecode(response.body) as Map)['uuid'] as String;
  } finally {
    client.close();
  }
}

/// A name that is unique per run, so repeated runs against one stack never
/// see each other's leftovers.
String uniqueName(String prefix) =>
    '$prefix-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
