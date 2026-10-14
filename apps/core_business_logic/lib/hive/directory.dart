import 'dart:typed_data';

import 'encoding.dart';
import 'identity.dart';

const int _maxChainDepth = 8;

/// One entry of `GET /nodes`.
final class DirectoryNode {
  const DirectoryNode({
    required this.id,
    required this.kind,
    required this.name,
    required this.platform,
    required this.appVersion,
    required this.publicKey,
    required this.status,
    this.approvedBy,
    this.approvalSig,
    this.capabilities = const <String, dynamic>{},
    this.online = false,
    this.lastSeenAt,
  });

  final String id;

  /// `engine` or `thin`.
  final String kind;
  final String name;
  final String platform;
  final String appVersion;
  final Uint8List publicKey;

  /// `pending`, `active` or `revoked`.
  final String status;
  final String? approvedBy;
  final String? approvalSig;
  final Map<String, dynamic> capabilities;
  final bool online;
  final String? lastSeenAt;

  String get publicKeyB64u => b64uEncode(publicKey);
  bool get isEngine => kind == 'engine';

  /// Malformed entries return null and are never trusted.
  static DirectoryNode? tryParse(Object? raw) {
    if (raw is! Map) return null;
    try {
      final Object? id = raw['id'];
      final Object? key = raw['public_key'];
      if (id is! String || key is! String) return null;
      final Uint8List bytes = b64uDecode(key);
      if (bytes.length != 32) return null;
      final Object? approvedBy = raw['approved_by'];
      final Object? approvalSig = raw['approval_sig'];
      final Object? capabilities = raw['capabilities'];
      return DirectoryNode(
        id: id,
        kind: '${raw['kind'] ?? ''}',
        name: '${raw['name'] ?? ''}',
        platform: '${raw['platform'] ?? ''}',
        appVersion: '${raw['app_version'] ?? ''}',
        publicKey: bytes,
        status: '${raw['status'] ?? ''}',
        approvedBy: approvedBy is String ? approvedBy : null,
        approvalSig: approvalSig is String ? approvalSig : null,
        capabilities: capabilities is Map
            ? capabilities.cast<String, dynamic>()
            : const <String, dynamic>{},
        online: raw['online'] == true,
        lastSeenAt: raw['last_seen_at'] as String?,
      );
    } on Object {
      return null;
    }
  }
}

/// Persistence for pinned keys and trust roots (secure storage in the app).
abstract interface class PinStore {
  Map<String, String> get keys;
  Set<String> get roots;
  Future<void> save();
}

final class MemoryPinStore implements PinStore {
  MemoryPinStore();
  @override
  final Map<String, String> keys = <String, String>{};
  @override
  final Set<String> roots = <String>{};
  @override
  Future<void> save() async {}
}

/// Verified view of the account's nodes: key pinning plus approval chains.
///
/// A node is trusted only when its id matches its key, its key matches any
/// earlier pin, and it is a trust root or carries an `approval_sig` from
/// another trusted node over `sc-approve-v1 | user_id | new_public_key`.
/// The server alone can therefore never add a member.
final class NodeDirectory {
  NodeDirectory({
    required this.userId,
    required this.localNodeId,
    PinStore? pins,
  }) : _pins = pins ?? MemoryPinStore();

  final String userId;
  final String localNodeId;
  final PinStore _pins;
  Map<String, DirectoryNode> _nodes = <String, DirectoryNode>{};
  Set<String> _trusted = <String>{};
  String? hiveId;

  List<DirectoryNode> get nodes => List<DirectoryNode>.unmodifiable(_nodes.values);
  DirectoryNode? get(String id) => _nodes[id];
  bool isTrusted(String id) => _trusted.contains(id);
  DirectoryNode? trustedNode(String id) =>
      _trusted.contains(id) ? _nodes[id] : null;

  Future<void> update(Iterable<Object?> rawNodes, {String? hiveId}) async {
    if (hiveId != null) this.hiveId = hiveId;
    final Map<String, DirectoryNode> parsed = <String, DirectoryNode>{};
    for (final Object? raw in rawNodes) {
      final DirectoryNode? node = DirectoryNode.tryParse(raw);
      if (node == null) continue;
      if (!nodeIdsEqual(node.id, await deriveNodeId(node.publicKey))) continue;
      final String? pinned = _pins.keys[node.id];
      if (pinned != null && pinned != node.publicKeyB64u) continue;
      parsed[node.id] = node;
    }
    _nodes = parsed;
    _trusted = await _computeTrusted();
    bool changed = false;
    for (final String id in _trusted) {
      final String key = _nodes[id]!.publicKeyB64u;
      if (_pins.keys[id] != key) {
        _pins.keys[id] = key;
        changed = true;
      }
    }
    if (changed) await _pins.save();
  }

  Future<Set<String>> _computeTrusted() async {
    final Set<String> roots = await _roots();
    final Set<String> trusted = <String>{};
    for (final String id in _nodes.keys) {
      if (await _chainOk(id, roots, <String>{}, 0)) trusted.add(id);
    }
    return trusted;
  }

  Future<Set<String>> _roots() async {
    final Set<String> roots = <String>{
      for (final String r in _pins.roots)
        if (_nodes.containsKey(r)) r,
    };
    final DirectoryNode? local = _nodes[localNodeId];
    if (local != null && local.status == 'active' && local.approvedBy == null) {
      roots.add(local.id);
    }
    if (roots.isEmpty) {
      // Trust on first use: exactly one active node without an approver.
      final List<DirectoryNode> candidates = <DirectoryNode>[
        for (final DirectoryNode n in _nodes.values)
          if (n.status == 'active' && n.approvedBy == null) n,
      ];
      if (candidates.length == 1) roots.add(candidates.single.id);
    }
    if (!_pins.roots.containsAll(roots)) {
      _pins.roots.addAll(roots);
      await _pins.save();
    }
    return roots;
  }

  Future<bool> _chainOk(
    String id,
    Set<String> roots,
    Set<String> seen,
    int depth,
  ) async {
    final DirectoryNode? node = _nodes[id];
    if (node == null || node.status != 'active' || depth > _maxChainDepth) {
      return false;
    }
    if (roots.contains(id)) return true;
    if (seen.contains(id) || node.approvedBy == null || node.approvalSig == null) {
      return false;
    }
    final DirectoryNode? approver = _nodes[node.approvedBy];
    if (approver == null || approver.id == node.id) return false;
    final bool valid = await verifySignature(
      publicKey: approver.publicKey,
      signature: node.approvalSig!,
      message: approvalMessage(userId, node.publicKeyB64u),
    );
    if (!valid) return false;
    return _chainOk(approver.id, roots, <String>{...seen, id}, depth + 1);
  }
}
