import 'dart:typed_data';

import 'encoding.dart';
import 'identity.dart';


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
    this.parentNodeId,
    this.clients = const <String>[],
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

  /// Engine this client folds under (`parent_node_id`), if any.
  final String? parentNodeId;

  /// Names of the clients attached to this engine.
  final List<String> clients;

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
      final Object? parent = raw['parent_node_id'];
      final Object? clients = raw['clients'];
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
        parentNodeId: parent is String && parent.isNotEmpty ? parent : null,
        clients: clients is List
            ? <String>[
                for (final Object? c in clients)
                  if (c is String) c,
              ]
            : const <String>[],
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

/// Verified view of the account's nodes: key pinning for active members.
///
/// A node is a member when the signed-in account lists it as active, its id
/// matches its key and its key matches any earlier pin. There is no trust root
/// or approval chain.
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

  /// No trust root: every node the signed-in account lists as active is a
  /// member, and this node itself once it is listed (not revoked). Id/key
  /// consistency and pinning were already checked in [update].
  Future<Set<String>> _computeTrusted() async => <String>{
    for (final DirectoryNode n in _nodes.values)
      if (n.status == 'active' || (n.id == localNodeId && n.status != 'revoked'))
        n.id,
  };
}
