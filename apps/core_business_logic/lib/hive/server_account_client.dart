import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'encoding.dart';
import 'hive_api.dart';

/// Persists the refresh token (flutter_secure_storage in the app).
abstract interface class RefreshTokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> delete();
}

final class MemoryRefreshTokenStore implements RefreshTokenStore {
  String? _value;
  @override
  Future<String?> read() async => _value;
  @override
  Future<void> write(String token) async => _value = token;
  @override
  Future<void> delete() async => _value = null;
}

final class ServerUser {
  const ServerUser({
    required this.id,
    required this.email,
    this.displayName,
  });
  final String id;
  final String email;
  final String? displayName;
}

/// PKCE material for the native OAuth flow (`/auth/{slug}/login?native=true`).
final class PkcePair {
  const PkcePair({required this.verifier, required this.challenge});
  final String verifier;
  final String challenge;
}

/// Creates a 64 char verifier and its S256 challenge (43 chars, base64url).
Future<PkcePair> createPkcePair({Random? random}) async {
  final Random rng = random ?? Random.secure();
  final String verifier = b64uEncode(
    List<int>.generate(48, (int _) => rng.nextInt(256)),
  );
  final String challenge = b64uEncode(await sha256Bytes(ascii.encode(verifier)));
  return PkcePair(verifier: verifier, challenge: challenge);
}

/// Email login, refresh-token rotation and native PKCE exchange against
/// `subconscious-server` (`app/routers/auth.py`).
///
/// Native clients call the endpoints with `?native=true` so the refresh token
/// is returned in the JSON body instead of an httponly cookie.
final class ServerAccountClient {
  ServerAccountClient({
    required Uri baseUri,
    required this.tokenStore,
    http.Client? client,
    DateTime Function()? clock,
  }) : baseUri = baseUri.path.endsWith('/')
           ? baseUri
           : baseUri.replace(path: '${baseUri.path}/'),
       _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now;

  final Uri baseUri;
  final RefreshTokenStore tokenStore;
  final http.Client _client;
  final DateTime Function() _clock;

  String? _accessToken;
  DateTime? _accessExpiry;
  ServerUser? user;
  Future<String?>? _refreshing;

  bool get isSignedIn => _accessToken != null;

  /// Current access token (may be expired); use [ensureAccessToken] to refresh.
  String? get accessToken => _accessToken;

  Future<void> close() async => _client.close();

  Future<ServerUser> loginWithEmail({
    required String email,
    required String password,
  }) async => _acceptAuth(
    await _post('auth/email/login', <String, dynamic>{
      'email': email,
      'password': password,
    }, query: const <String, String>{'native': 'true'}),
  );

  /// `POST /auth/email/register`: emails a verification code. Returns the
  /// server's message for the user.
  Future<String> requestSignupCode(String email) async {
    final Map<String, dynamic> body = await _post(
      'auth/email/register',
      <String, dynamic>{'email': email},
    );
    final Object? message = body['message'];
    return message is String && message.trim().isNotEmpty
        ? message
        : 'Check your email for a verification code.';
  }

  /// `POST /auth/email/verify` then `POST /auth/email/complete?native=true`.
  Future<ServerUser> completeSignup({
    required String email,
    required String code,
    required String password,
    String? displayName,
  }) async {
    final Map<String, dynamic> verified = await _post(
      'auth/email/verify',
      <String, dynamic>{'email': email, 'code': code},
    );
    final Object? token = verified['verification_token'];
    if (token is! String || token.isEmpty) {
      throw const HiveApiException('The server returned an invalid response.');
    }
    final String name = displayName?.trim() ?? '';
    return _acceptAuth(
      await _post(
        'auth/email/complete',
        <String, dynamic>{
          'verification_token': token,
          'password': password,
          if (name.isNotEmpty) 'display_name': name,
        },
        query: const <String, String>{'native': 'true'},
      ),
    );
  }

  /// `GET /auth/{slug}/login?native=true...`; returns the provider URL to open.
  Future<Uri> beginNativeLogin({
    required String provider,
    required Uri loopbackRedirect,
    required PkcePair pkce,
  }) async {
    final Uri uri = baseUri
        .resolve('auth/${Uri.encodeComponent(provider)}/login')
        .replace(
          queryParameters: <String, String>{
            'native': 'true',
            'redirect_to': loopbackRedirect.toString(),
            'code_challenge': pkce.challenge,
            'code_challenge_method': 'S256',
          },
        );
    final Map<String, dynamic> body = await _send(http.Request('GET', uri));
    final Object? url = body['url'];
    if (url is! String) {
      throw const HiveApiException('The server returned no sign-in URL.');
    }
    return Uri.parse(url);
  }

  /// `POST /auth/native/token {code, code_verifier}`.
  Future<ServerUser> exchangeNativeCode({
    required String code,
    required String codeVerifier,
  }) async => _acceptAuth(
    await _post('auth/native/token', <String, dynamic>{
      'code': code,
      'code_verifier': codeVerifier,
    }),
  );

  /// Restores a session from the stored refresh token. Returns false if none.
  Future<bool> restore() async {
    if (await _refresh() == null) return false;
    await _loadUser();
    return true;
  }

  /// `GET /auth/me` fills [user] after a restored session.
  Future<void> _loadUser() async {
    final http.Request request = http.Request('GET', baseUri.resolve('auth/me'))
      ..headers['Authorization'] = 'Bearer $_accessToken';
    final Map<String, dynamic> raw = await _send(request);
    if (raw['id'] != null && raw['email'] != null) {
      user = ServerUser(
        id: '${raw['id']}',
        email: '${raw['email']}',
        displayName: raw['display_name'] as String?,
      );
    }
  }

  /// A non-expired access token, rotating the refresh token when needed.
  Future<String?> ensureAccessToken() async {
    final DateTime? expiry = _accessExpiry;
    if (_accessToken != null &&
        expiry != null &&
        _clock().isBefore(expiry.subtract(const Duration(seconds: 30)))) {
      return _accessToken;
    }
    return _refresh();
  }

  /// Forces a refresh (use after a 401).
  Future<void> forceRefresh() async {
    _accessExpiry = null;
    await _refresh();
  }

  Future<void> logout() async {
    final String? refresh = await tokenStore.read();
    try {
      if (refresh != null) {
        await _post('auth/logout', <String, dynamic>{'refresh_token': refresh});
      }
    } on Object {
      // Local sign-out still proceeds.
    }
    _accessToken = null;
    _accessExpiry = null;
    user = null;
    await tokenStore.delete();
  }

  /// Rotation invalidates the old token, so concurrent callers share one call.
  Future<String?> _refresh() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<String?> _doRefresh() async {
    final String? refresh = await tokenStore.read();
    if (refresh == null || refresh.isEmpty) return null;
    final Map<String, dynamic> body;
    try {
      body = await _post('auth/refresh', <String, dynamic>{
        'refresh_token': refresh,
      });
    } on HiveApiException catch (error) {
      if (error.statusCode == 401) {
        _accessToken = null;
        await tokenStore.delete();
        return null;
      }
      rethrow;
    }
    _storeAccess(body);
    final Object? rotated = body['refresh_token'];
    if (rotated is String && rotated.isNotEmpty) await tokenStore.write(rotated);
    return _accessToken;
  }

  Future<ServerUser> _acceptAuth(Map<String, dynamic> body) async {
    _storeAccess(body);
    final Object? refresh = body['refresh_token'];
    if (refresh is String && refresh.isNotEmpty) {
      await tokenStore.write(refresh);
    }
    final Object? raw = body['user'];
    if (raw is! Map || raw['id'] == null || raw['email'] == null) {
      throw const HiveApiException('The server returned no user.');
    }
    final ServerUser parsed = ServerUser(
      id: '${raw['id']}',
      email: '${raw['email']}',
      displayName: raw['display_name'] as String?,
    );
    user = parsed;
    return parsed;
  }

  void _storeAccess(Map<String, dynamic> body) {
    final Object? token = body['access_token'];
    if (token is! String || token.isEmpty) {
      throw const HiveApiException('The server returned no access token.');
    }
    _accessToken = token;
    final Object? seconds = body['expires_in'];
    _accessExpiry = _clock().add(
      Duration(seconds: seconds is num ? seconds.toInt() : 300),
    );
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    Map<String, String> query = const <String, String>{},
  }) {
    final Uri uri = baseUri
        .resolve(path)
        .replace(queryParameters: query.isEmpty ? null : query);
    final http.Request request = http.Request('POST', uri)
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(body);
    return _send(request);
  }

  Future<Map<String, dynamic>> _send(http.Request request) async {
    request.headers['Accept'] = 'application/json';
    final http.StreamedResponse response;
    final String text;
    try {
      response = await _client.send(request);
      text = await response.stream.bytesToString();
    } on Object {
      throw const HiveApiException('Could not reach the Subconscious server.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HiveApiException(_detail(text, response.statusCode), response.statusCode);
    }
    if (text.trim().isEmpty) return <String, dynamic>{};
    final Object? decoded = jsonDecode(text);
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw const HiveApiException('The server returned an invalid response.');
  }
}

String _detail(String body, int status) {
  try {
    final Object? value = jsonDecode(body);
    if (value is Map) {
      for (final String key in const <String>['message', 'error', 'detail']) {
        final Object? message = value[key];
        if (message is String && message.trim().isNotEmpty) {
          return message.trim();
        }
      }
    }
  } on FormatException {
    // Generic message below.
  }
  return 'The server returned status $status.';
}
