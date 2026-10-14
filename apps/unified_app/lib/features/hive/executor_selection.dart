import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One place a task can run (webrtc.md 7.4).
@immutable
final class ExecutorOption {
  const ExecutorOption({
    required this.nodeId,
    required this.name,
    this.platform,
    this.tier,
  });

  /// Hive node id; null means the engine this app is connected to (default).
  final String? nodeId;
  final String name;
  final String? platform;

  /// Connection tier of an open link (`direct`, `ws-relay`, ...), if any.
  final String? tier;

  bool get isHome => nodeId == null;

  String get subtitle => <String>[
    if (platform != null && platform!.isNotEmpty) platform!,
    if (tier != null && tier!.isNotEmpty) tier!,
  ].join(' \u00b7 ');

  @override
  bool operator ==(Object other) =>
      other is ExecutorOption &&
      other.nodeId == nodeId &&
      other.name == name &&
      other.platform == platform &&
      other.tier == tier;

  @override
  int get hashCode => Object.hash(nodeId, name, platform, tier);
}

/// Source of executor choices for the composer and the devices page.
abstract interface class ExecutorDirectory implements Listenable {
  /// Home engine first, then other active, verified, online full nodes.
  List<ExecutorOption> get options;

  /// Display name for [nodeId] (a node of the hive), or null when unknown.
  String? nameOf(String nodeId);

  Future<String?> loadSelection(String threadUuid);
  Future<void> saveSelection(String threadUuid, String? nodeId);
}

/// Per thread executor choice kept on this device only (never synced).
abstract interface class ExecutorPreferenceStore {
  Future<String?> read(String threadUuid);

  /// A null [nodeId] clears the choice (back to the home engine).
  Future<void> write(String threadUuid, String? nodeId);
}

final class MemoryExecutorPreferenceStore implements ExecutorPreferenceStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String threadUuid) async => _values[threadUuid];

  @override
  Future<void> write(String threadUuid, String? nodeId) async {
    if (nodeId == null) {
      _values.remove(threadUuid);
    } else {
      _values[threadUuid] = nodeId;
    }
  }
}

final class SecureExecutorPreferenceStore implements ExecutorPreferenceStore {
  SecureExecutorPreferenceStore(this._storage);
  final FlutterSecureStorage _storage;

  static String _key(String threadUuid) =>
      'subconscious.hive.executor.v1.$threadUuid';

  @override
  Future<String?> read(String threadUuid) async {
    try {
      final String? value = await _storage.read(key: _key(threadUuid));
      return value == null || value.isEmpty ? null : value;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String threadUuid, String? nodeId) async {
    try {
      if (nodeId == null) {
        await _storage.delete(key: _key(threadUuid));
      } else {
        await _storage.write(key: _key(threadUuid), value: nodeId);
      }
    } on Object {
      // The choice still applies for this session.
    }
  }
}
