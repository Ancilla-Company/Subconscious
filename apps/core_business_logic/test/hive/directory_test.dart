import 'package:core_business_logic/core_business_logic.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  const String user = 'user-1';

  Future<String> approval(NodeIdentity approver, NodeIdentity subject) =>
      approver.sign(approvalMessage(user, subject.publicKeyB64u));

  test('first node is a trust root; approved node chains to it', () async {
    final NodeIdentity root = await seededIdentity(1);
    final NodeIdentity phone = await seededIdentity(40);
    final NodeDirectory dir = NodeDirectory(userId: user, localNodeId: phone.nodeId);
    await dir.update(<Object?>[
      nodeJson(root),
      nodeJson(
        phone,
        kind: 'thin',
        approvedBy: root.nodeId,
        approvalSig: await approval(root, phone),
      ),
    ]);
    expect(dir.isTrusted(root.nodeId), isTrue);
    expect(dir.isTrusted(phone.nodeId), isTrue);
    expect(dir.trustedNode(root.nodeId)!.isEngine, isTrue);
  });

  test('server-forged approval is not trusted', () async {
    final NodeIdentity root = await seededIdentity(1);
    final NodeIdentity evil = await seededIdentity(80);
    final NodeIdentity stranger = await seededIdentity(120);
    final NodeDirectory dir = NodeDirectory(userId: user, localNodeId: root.nodeId);
    await dir.update(<Object?>[
      nodeJson(root),
      // Signed by a key that is not the claimed approver.
      nodeJson(
        evil,
        approvedBy: root.nodeId,
        approvalSig: await approval(stranger, evil),
      ),
      // Active but missing any approval.
      nodeJson(stranger),
    ]);
    expect(dir.isTrusted(root.nodeId), isTrue);
    expect(dir.isTrusted(evil.nodeId), isFalse);
    expect(dir.isTrusted(stranger.nodeId), isFalse);
  });

  test('pending and revoked nodes are never trusted', () async {
    final NodeIdentity root = await seededIdentity(1);
    final NodeIdentity pending = await seededIdentity(40);
    final NodeIdentity revoked = await seededIdentity(80);
    final NodeDirectory dir = NodeDirectory(userId: user, localNodeId: root.nodeId);
    await dir.update(<Object?>[
      nodeJson(root),
      nodeJson(pending, kind: 'thin', status: 'pending'),
      nodeJson(
        revoked,
        status: 'revoked',
        approvedBy: root.nodeId,
        approvalSig: await approval(root, revoked),
      ),
    ]);
    expect(dir.isTrusted(pending.nodeId), isFalse);
    expect(dir.isTrusted(revoked.nodeId), isFalse);
  });

  test('chains through an intermediate approver and rejects revoked links', () async {
    final NodeIdentity root = await seededIdentity(1);
    final NodeIdentity mid = await seededIdentity(40);
    final NodeIdentity leaf = await seededIdentity(80);
    Future<List<Object?>> build(String midStatus) async => <Object?>[
      nodeJson(root),
      nodeJson(mid, status: midStatus, approvedBy: root.nodeId, approvalSig: await approval(root, mid)),
      nodeJson(leaf, kind: 'thin', approvedBy: mid.nodeId, approvalSig: await approval(mid, leaf)),
    ];
    final NodeDirectory dir = NodeDirectory(userId: user, localNodeId: root.nodeId);
    await dir.update(await build('active'));
    expect(dir.isTrusted(leaf.nodeId), isTrue);
    await dir.update(await build('revoked'));
    expect(dir.isTrusted(leaf.nodeId), isFalse);
  });

  test('entries whose id does not match the key are dropped', () async {
    final NodeIdentity root = await seededIdentity(1);
    final NodeIdentity other = await seededIdentity(40);
    final Map<String, dynamic> lying = nodeJson(other)..['id'] = root.nodeId;
    final NodeDirectory dir = NodeDirectory(userId: user, localNodeId: other.nodeId);
    await dir.update(<Object?>[lying, 'garbage', <String, dynamic>{'id': 1}]);
    expect(dir.nodes, isEmpty);
  });

  test('a changed key for a pinned node is ignored', () async {
    final NodeIdentity root = await seededIdentity(1);
    final MemoryPinStore pins = MemoryPinStore();
    final NodeDirectory dir = NodeDirectory(userId: user, localNodeId: root.nodeId, pins: pins);
    await dir.update(<Object?>[nodeJson(root)]);
    expect(pins.keys[root.nodeId], root.publicKeyB64u);
    final NodeIdentity swapped = await seededIdentity(99);
    final Map<String, dynamic> swap = nodeJson(swapped)..['id'] = root.nodeId;
    await dir.update(<Object?>[swap]);
    expect(dir.isTrusted(root.nodeId), isFalse);
    expect(dir.get(root.nodeId), isNull);
  });

  test('trust on first use pins the sole unapproved active node', () async {
    final NodeIdentity engine = await seededIdentity(1);
    final NodeIdentity phone = await seededIdentity(40);
    final MemoryPinStore pins = MemoryPinStore();
    final NodeDirectory dir = NodeDirectory(userId: user, localNodeId: phone.nodeId, pins: pins);
    await dir.update(<Object?>[
      nodeJson(engine),
      nodeJson(phone, kind: 'thin', status: 'pending'),
    ]);
    expect(dir.isTrusted(engine.nodeId), isTrue);
    expect(pins.roots, contains(engine.nodeId));
  });

  test('chooseHomeEngine prefers last used, then any online trusted engine', () async {
    final NodeIdentity a = await seededIdentity(1);
    final NodeIdentity b = await seededIdentity(40);
    final NodeIdentity off = await seededIdentity(80);
    NodeView view(NodeIdentity i, {bool online = true, bool trusted = true}) => NodeView(
      node: DirectoryNode.tryParse(nodeJson(i))!,
      trusted: trusted,
      online: online,
      isLocal: false,
    );
    final List<NodeView> views = <NodeView>[
      view(off, online: false),
      view(a),
      view(b),
    ];
    expect(chooseHomeEngine(views)!.id, a.nodeId);
    expect(chooseHomeEngine(views, lastUsedNodeId: b.nodeId)!.id, b.nodeId);
    expect(chooseHomeEngine(views, lastUsedNodeId: off.nodeId)!.id, a.nodeId);
    expect(chooseHomeEngine(<NodeView>[view(a, trusted: false)]), isNull);
  });
}
