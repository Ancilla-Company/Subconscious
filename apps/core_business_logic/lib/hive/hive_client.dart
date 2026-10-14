import 'dart:async';

import 'directory.dart';
import 'encoding.dart';
import 'hive_api.dart';
import 'identity.dart';
import 'peer_connector.dart';
import 'peer_link.dart';
import 'relay.dart';
import 'server_account_client.dart';
import 'signaling_client.dart';

/// Persists the Ed25519 seed (flutter_secure_storage in the app), base64url.
abstract interface class IdentitySeedStore {
  Future<String?> read();
  Future<void> write(String seed);
  Future<void> delete();
}

final class MemoryIdentitySeedStore implements IdentitySeedStore {
  String? _value;
  @override
  Future<String?> read() async => _value;
  @override
  Future<void> write(String seed) async => _value = seed;
  @override
  Future<void> delete() async => _value = null;
}

Future<NodeIdentity> loadOrCreateIdentity(IdentitySeedStore store) async {
  final String? seed = await store.read();
  if (seed != null && seed.isNotEmpty) {
    return NodeIdentity.fromSeed(b64uDecode(seed));
  }
  final NodeIdentity identity = await NodeIdentity.generate();
  await store.write(b64uEncode(await identity.seed()));
  return identity;
}

/// What the node list shows for one node.
final class NodeView {
  const NodeView({
    required this.node,
    required this.trusted,
    required this.online,
    required this.isLocal,
    this.tier,
  });
  final DirectoryNode node;

  /// Approval chain verified locally (not merely "active" on the server).
  final bool trusted;
  final bool online;
  final bool isLocal;

  /// Connection tier of an open link (`direct`, `ws-relay`, ...) or null.
  final String? tier;
}

/// Home engine: last used if still usable, else the first online trusted
/// engine (webrtc.md 7.5; latency ranking is a later refinement).
DirectoryNode? chooseHomeEngine(
  Iterable<NodeView> nodes, {
  String? lastUsedNodeId,
}) {
  final List<NodeView> usable = <NodeView>[
    for (final NodeView v in nodes)
      if (v.trusted && v.online && v.node.isEngine && !v.isLocal) v,
  ];
  if (usable.isEmpty) return null;
  for (final NodeView v in usable) {
    if (lastUsedNodeId != null && nodeIdsEqual(v.node.id, lastUsedNodeId)) {
      return v.node;
    }
  }
  return usable.first.node;
}

/// Orchestrates identity, registration, directory, signalling and peers for a
/// thin node.
final class HiveClient {
  HiveClient({
    required this.account,
    required this.seedStore,
    required this.pinStoreFactory,
    required this.transportFactory,
    required this.deviceName,
    required this.platform,
    required this.appVersion,
    SignalConnect? signalConnect,
    this.directTimeout = const Duration(seconds: 8),
  }) : _signalConnect = signalConnect;

  /// How long a direct WebRTC attempt runs before the socket relay is tried.
  final Duration directTimeout;
  bool _wsRelayEnabled = false;

  final ServerAccountClient account;
  final IdentitySeedStore seedStore;

  /// Creates the pin store for a user id (secure storage backed in the app).
  final Future<PinStore> Function(String userId) pinStoreFactory;
  final PeerTransportFactory transportFactory;
  final String deviceName;
  final String platform;
  final String appVersion;
  final SignalConnect? _signalConnect;

  NodeIdentity? identity;
  NodeDirectory? directory;
  HiveApi? api;
  SignalingClient? signaling;
  PeerConnector? connector;
  final Map<String, bool> _presence = <String, bool>{};
  final StreamController<List<NodeView>> _views =
      StreamController<List<NodeView>>.broadcast();
  StreamSubscription<SignalFrame>? _frameSubscription;

  Stream<List<NodeView>> get nodeViews => _views.stream;
  bool get started => connector != null;

  /// Registers this device, loads the directory and starts signalling.
  /// Requires a signed-in [account].
  Future<void> start() async {
    if (started) return;
    if (account.user == null && !await account.restore()) {
      throw const HiveApiException('Sign in to use the hive.', 401);
    }
    if (await account.ensureAccessToken() == null) {
      throw const HiveApiException('Sign in to use the hive.', 401);
    }
    final String? userId = account.user?.id;
    if (userId == null) {
      throw const HiveApiException('Sign in again to use the hive.', 401);
    }
    final NodeIdentity self = await loadOrCreateIdentity(seedStore);
    identity = self;
    final HiveApi hiveApi = HiveApi(
      baseUri: account.baseUri,
      accessToken: () => account.accessToken,
      refreshAccessToken: account.forceRefresh,
    );
    api = hiveApi;
    await _register(hiveApi, self, userId);
    final NodeDirectory dir = NodeDirectory(
      userId: userId,
      localNodeId: self.nodeId,
      pins: await pinStoreFactory(userId),
    );
    directory = dir;
    await refreshDirectory();
    final SignalingClient signals = SignalingClient(
      api: hiveApi,
      identity: self,
      connect: _signalConnect,
    );
    signaling = signals;
    final PeerConnector peers = PeerConnector(
      identity: self,
      directory: dir,
      signaler: signals,
      transportFactory: transportFactory,
      directTimeout: directTimeout,
      relay: RelayManager(identity: self, directory: dir, sender: signals),
      relayEnabled: () async => _wsRelayEnabled,
      iceProvider: () async {
        final Map<String, dynamic> config = await hiveApi.iceConfig(self.nodeId);
        _wsRelayEnabled = config['ws_relay_enabled'] == true;
        final Object? servers = config['ice_servers'];
        return <Map<String, dynamic>>[
          if (servers is List)
            for (final Object? s in servers)
              if (s is Map) s.cast<String, dynamic>(),
        ];
      },
    );
    connector = peers;
    _frameSubscription = signals.frames.listen((SignalFrame frame) {
      switch (frame.type) {
        case 'signal':
          unawaited(peers.handleSignal(frame.data));
        case 'relay':
          unawaited(peers.handleRelay(frame.data));
        case 'presence.snapshot':
          final Object? nodes = frame.data['nodes'];
          if (nodes is List) {
            _presence.clear();
            for (final Object? n in nodes) {
              _applyPresence(n);
            }
            _emit();
          }
        case 'presence.update':
          _applyPresence(frame.data);
          _emit();
      }
    });
    signals.start();
  }

  void _applyPresence(Object? raw) {
    if (raw is Map && raw['node_id'] is String) {
      _presence[raw['node_id'] as String] = raw['online'] == true;
    }
  }

  Future<void> _register(HiveApi hiveApi, NodeIdentity self, String userId) async {
    await hiveApi.register(<String, dynamic>{
      'public_key': self.publicKeyB64u,
      'kind': 'thin',
      'name': deviceName,
      'platform': platform,
      'app_version': appVersion,
      'protocol_version': 1,
      'proof': await self.sign(registerMessage(userId, self.publicKeyB64u)),
    });
  }

  Future<List<NodeView>> refreshDirectory() async {
    final HiveApi? hiveApi = api;
    final NodeDirectory? dir = directory;
    if (hiveApi == null || dir == null) return const <NodeView>[];
    final Map<String, dynamic> response = await hiveApi.listNodes();
    final Object? nodes = response['nodes'];
    final Object? hive = response['hive_id'];
    await dir.update(
      nodes is List ? nodes : const <Object?>[],
      hiveId: hive is String ? hive : null,
    );
    final List<NodeView> views = currentViews();
    if (!_views.isClosed) _views.add(views);
    return views;
  }

  List<NodeView> currentViews() {
    final NodeDirectory? dir = directory;
    final NodeIdentity? self = identity;
    if (dir == null || self == null) return const <NodeView>[];
    return <NodeView>[
      for (final DirectoryNode n in dir.nodes)
        NodeView(
          node: n,
          trusted: dir.isTrusted(n.id),
          online: _presence[n.id] ?? n.online,
          isLocal: nodeIdsEqual(n.id, self.nodeId),
          tier: connector?.linkFor(n.id)?.tier,
        ),
    ];
  }

  void _emit() {
    if (!_views.isClosed) _views.add(currentViews());
  }

  /// Short authentication string shown on both devices during enrolment.
  Future<String> sasFor(DirectoryNode other) async {
    final NodeIdentity? self = identity;
    if (self == null) throw StateError('The hive client is not started.');
    return shortAuthenticationString(self.publicKey, other.publicKey);
  }

  /// Approves a pending node after the user confirmed the SAS. Only a trusted
  /// active node may approve; the signature is what peers will verify.
  Future<void> approve(DirectoryNode pending) async {
    final NodeIdentity? self = identity;
    final NodeDirectory? dir = directory;
    final HiveApi? hiveApi = api;
    if (self == null || dir == null || hiveApi == null) {
      throw StateError('The hive client is not started.');
    }
    if (!dir.isTrusted(self.nodeId)) {
      throw const HiveApiException(
        'This device is not approved yet, so it cannot approve others.',
        403,
      );
    }
    final String sig = await self.sign(
      approvalMessage(dir.userId, pending.publicKeyB64u),
    );
    await hiveApi.approve(
      nodeId: pending.id,
      approverNodeId: self.nodeId,
      approvalSig: sig,
    );
    await refreshDirectory();
  }

  Future<void> revoke(DirectoryNode node) async {
    await api?.revoke(node.id);
    await connector?.closePeer(node.id);
    await refreshDirectory();
  }

  /// Opens (or reuses) a verified link to [nodeId].
  Future<PeerLink> connectTo(String nodeId) {
    final PeerConnector? peers = connector;
    if (peers == null) throw StateError('The hive client is not started.');
    return peers.connect(nodeId);
  }

  Future<void> stop() async {
    await _frameSubscription?.cancel();
    _frameSubscription = null;
    await signaling?.dispose();
    await connector?.close();
    await api?.close();
    signaling = null;
    connector = null;
    api = null;
    directory = null;
  }

  Future<void> dispose() async {
    await stop();
    await _views.close();
  }
}
