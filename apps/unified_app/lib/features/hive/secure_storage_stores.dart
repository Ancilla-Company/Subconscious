import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Service names mirror the engine's keyring layout (webrtc.md 5.4).
const String _refreshKey = 'subconscious.server.refresh.v1';
const String _identityKey = 'subconscious.node.identity.v1';
const String _pinKeyPrefix = 'subconscious.node.pins.v1.';

FlutterSecureStorage defaultSecureStorage() => const FlutterSecureStorage();

/// Refresh token in the platform keystore (Keychain, Keystore, DPAPI, ...).
final class SecureRefreshTokenStore implements RefreshTokenStore {
  SecureRefreshTokenStore([FlutterSecureStorage? storage])
    : _storage = storage ?? defaultSecureStorage();
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _refreshKey);
  @override
  Future<void> write(String token) =>
      _storage.write(key: _refreshKey, value: token);
  @override
  Future<void> delete() => _storage.delete(key: _refreshKey);
}

/// Ed25519 seed (base64url) in the platform keystore. Never exported.
final class SecureIdentitySeedStore implements IdentitySeedStore {
  SecureIdentitySeedStore([FlutterSecureStorage? storage])
    : _storage = storage ?? defaultSecureStorage();
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _identityKey);
  @override
  Future<void> write(String seed) =>
      _storage.write(key: _identityKey, value: seed);
  @override
  Future<void> delete() => _storage.delete(key: _identityKey);
}

const String _clientIdKey = 'subconscious.hive.clientId.v1';

/// A random per-install id (32 hex characters) sent only to the local engine,
/// so it can recognise this GUI exactly. Created on first use.
final class SecureClientIdStore {
  SecureClientIdStore([FlutterSecureStorage? storage, Random? random])
    : _storage = storage ?? defaultSecureStorage(),
      _random = random ?? Random.secure();
  final FlutterSecureStorage _storage;
  final Random _random;

  Future<String> readOrCreate() async {
    final String? existing = await _storage.read(key: _clientIdKey);
    if (existing != null && existing.length == 32) return existing;
    final String created = <String>[
      for (int i = 0; i < 16; i++)
        _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    await _storage.write(key: _clientIdKey, value: created);
    return created;
  }
}

/// Pinned node keys and trust roots, one JSON blob per account.
///
/// [PinStore] is synchronous to read, so call [load] once before use.
final class SecurePinStore implements PinStore {
  SecurePinStore(this.userId, [FlutterSecureStorage? storage])
    : _storage = storage ?? defaultSecureStorage();
  final String userId;
  final FlutterSecureStorage _storage;

  @override
  final Map<String, String> keys = <String, String>{};
  @override
  final Set<String> roots = <String>{};

  String get _key => '$_pinKeyPrefix$userId';

  Future<SecurePinStore> load() async {
    final String? raw = await _storage.read(key: _key);
    if (raw == null) return this;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        final Object? k = decoded['keys'];
        final Object? r = decoded['roots'];
        if (k is Map) {
          keys.addAll(<String, String>{
            for (final MapEntry<dynamic, dynamic> e in k.entries)
              if (e.value is String) '${e.key}': e.value as String,
          });
        }
        if (r is List) roots.addAll(r.whereType<String>());
      }
    } on FormatException {
      // Start empty; keys are re-pinned from the verified directory.
    }
    return this;
  }

  @override
  Future<void> save() => _storage.write(
    key: _key,
    value: jsonEncode(<String, dynamic>{
      'keys': keys,
      'roots': roots.toList()..sort(),
    }),
  );
}
