import 'dart:async';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import 'directory.dart';
import 'presence_book.dart';
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
    this.parentId,
    this.clients = const <String>[],
    this.sas,
  });
  final DirectoryNode node;

  /// Engine node id this client is folded under, if any.
  final String? parentId;

  /// Names of the clients attached to this engine.
  final List<String> clients;

  /// Short authentication string for an engine row from the local engine.
  final String? sas;

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

/// Outcome of [chooseEngine].
enum EngineChoiceKind {
  /// Connect to [EngineChoice.node] now.
  connect,

  /// Several engines are online and none is preferred: the user picks.
  pick,

  /// No usable engine is online yet: keep watching.
  none,
}

final class EngineChoice {
  const EngineChoice(this.kind, [this.node]);
  final EngineChoiceKind kind;
  final DirectoryNode? node;
}

/// Picks the remote engine to connect to. Candidates are trusted, online,
/// non-local engines. An online [preferredId] wins; otherwise a single
/// candidate is chosen automatically; several candidates need the user.
EngineChoice chooseEngine(Iterable<NodeView> nodes, {String? preferredId}) {
  final List<NodeView> usable = <NodeView>[
    for (final NodeView v in nodes)
      if (v.trusted && v.online && v.node.isEngine && !v.isLocal) v,
  ];
  if (usable.isEmpty) return const EngineChoice(EngineChoiceKind.none);
  if (preferredId != null) {
    for (final NodeView v in usable) {
      if (nodeIdsEqual(v.node.id, preferredId)) {
        return EngineChoice(EngineChoiceKind.connect, v.node);
      }
    }
  }
  if (usable.length == 1) {
    return EngineChoice(EngineChoiceKind.connect, usable.first.node);
  }
  return const EngineChoice(EngineChoiceKind.pick);
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
    this.httpClient,
    this.apiRetryDelays,
  }) : _signalConnect = signalConnect;

  /// HTTP client for the `/nodes` API (a mock in tests; default when null).
  final http.Client? httpClient;

  /// Overrides the GET retry delays of the `/nodes` API (empty in tests).
  final List<Duration>? apiRetryDelays;

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
  final PresenceBook _book = PresenceBook();
  final StreamController<List<NodeView>> _views =
      StreamController<List<NodeView>>.broadcast();
  final StreamController<bool> _connectionChanges =
      StreamController<bool>.broadcast();
  StreamSubscription<SignalFrame>? _frameSubscription;
  StreamSubscription<bool>? _connectionSubscription;
  Timer? _unknownNodeTimer;
  bool _connectedOnce = false;

  Stream<List<NodeView>> get nodeViews => _views.stream;

  /// Signalling connect/disconnect events. Owned by this client, so it
  /// survives [stop] and [start] cycles.
  Stream<bool> get connectionChanges => _connectionChanges.stream;

  /// True while the signalling socket is authenticated.
  bool get signalConnected => signaling?.connected ?? false;
  bool get started => connector != null;

  HiveApi _newApi() => HiveApi(
    baseUri: account.baseUri,
    accessToken: () => account.accessToken,
    refreshAccessToken: account.forceRefresh,
    onUnauthorized: (String reason) => account.expireSession(reason),
    client: httpClient,
    retryDelays: apiRetryDelays ?? HiveApi.defaultRetryDelays,
  );

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
    final HiveApi hiveApi = _newApi();
    api = hiveApi;
    _connectedOnce = false;
    _book.clear();
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
            _book.applySnapshot(nodes);
            _emit();
          }
        case 'presence.update':
          _book.applyFrame(frame.data);
          _emit();
          _refreshIfUnknown(frame.data['node_id']);
        case 'node.changed':
          _refreshIfUnknown(frame.data['node_id'], force: true);
      }
    });
    _connectionSubscription = signals.connectionChanges.listen((bool up) {
      if (!_connectionChanges.isClosed) _connectionChanges.add(up);
      if (up && _connectedOnce) {
        // Anything may have changed while the socket was down.
        unawaited(_safeRefresh());
      }
      if (up) _connectedOnce = true;
    });
    signals.start();
  }

  /// One refresh, debounced by 1 s, when a frame names a node the directory
  /// does not know yet (a device that just signed in).
  void _refreshIfUnknown(Object? nodeId, {bool force = false}) {
    if (nodeId is! String) return;
    if (!force && directory?.get(nodeId) != null) return;
    _unknownNodeTimer?.cancel();
    _unknownNodeTimer = Timer(const Duration(seconds: 1), () {
      unawaited(_safeRefresh());
    });
  }

  Future<void> _safeRefresh() async {
    try {
      await refreshDirectory();
    } on Object catch (caught) {
      developer.log('Directory refresh failed: $caught', name: 'hive');
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
    final int startSequence = _book.beginRequest();
    final Map<String, dynamic> response = await hiveApi.listNodes();
    final Object? nodes = response['nodes'];
    final Object? hive = response['hive_id'];
    await dir.update(
      nodes is List ? nodes : const <Object?>[],
      hiveId: hive is String ? hive : null,
    );
    _book.mergeRest(startSequence, dir.nodes);
    final List<NodeView> views = currentViews();
    if (!_views.isClosed) _views.add(views);
    return views;
  }

  /// The Refresh button for a thin node: skips the signalling backoff, waits
  /// up to [wait] for the socket, then re-lists naming this node so the
  /// server checks it is online. Returns null when this device is online,
  /// otherwise the cause (also logged): signed in and talking to the server
  /// while shown offline is always a fault.
  Future<String?> forceRefresh({
    Duration wait = const Duration(seconds: 10),
  }) async {
    final SignalingClient? signals = signaling;
    final NodeIdentity? self = identity;
    final HiveApi? hiveApi = api;
    final NodeDirectory? dir = directory;
    if (signals == null || self == null || hiveApi == null || dir == null) {
      return 'This device has not joined the hive yet.';
    }
    if (!signals.connected) {
      signals.wake();
      try {
        await signals.waitConnected(wait);
      } on TimeoutException {
        // Reported below with the signalling cause.
      }
    }
    final int startSequence = _book.beginRequest();
    final Map<String, dynamic> response = await hiveApi.listNodes(
      callerNodeId: self.nodeId,
    );
    final Object? nodes = response['nodes'];
    final Object? hive = response['hive_id'];
    await dir.update(
      nodes is List ? nodes : const <Object?>[],
      hiveId: hive is String ? hive : null,
    );
    _book.mergeRest(startSequence, dir.nodes);
    if (!_views.isClosed) _views.add(currentViews());
    final String? problem = !signals.connected
        ? 'Signalling to the server is not connected '
              '(${signals.lastError ?? 'no response yet'}); '
              '${signals.failures} failed attempts.'
        : response['caller_online'] == false
        ? 'Signalling is connected, but the server still lists this device '
              'offline.'
        : null;
    if (problem != null) {
      developer.log('Refresh: this device is not online: $problem',
          name: 'hive', level: 900);
      // ignore: avoid_print
      print('hive: Refresh: this device is not online: $problem');
    }
    return problem;
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
          online: _book.onlineOf(n.id, n.online),
          isLocal: nodeIdsEqual(n.id, self.nodeId),
          tier: connector?.linkFor(n.id)?.tier,
          parentId: _book.parentOf(n.id, n.parentNodeId),
          clients: _book.clientsOf(n.id, n.clients),
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

  /// Folds this device's registered thin node under the local engine
  /// ([engineNodeId]) so it is not listed as a second device. Returns false
  /// when there is nothing to link or the server does not support it (404,
  /// 405, 422); other errors are rethrown.
  Future<bool> linkLegacyThinToEngine(String engineNodeId) async {
    final String? seed = await seedStore.read();
    if (seed == null || seed.isEmpty) return false;
    final NodeIdentity self = await NodeIdentity.fromSeed(b64uDecode(seed));
    if (nodeIdsEqual(self.nodeId, engineNodeId)) return false;
    final HiveApi linkApi = _newApi();
    try {
      await linkApi.setParent(self.nodeId, engineNodeId);
      return true;
    } on HiveApiException catch (caught) {
      if (caught.statusCode == 404 ||
          caught.statusCode == 405 ||
          caught.statusCode == 422) {
        developer.log(
          'Legacy device link skipped (${caught.statusCode}).',
          name: 'hive',
        );
        return false;
      }
      rethrow;
    } finally {
      await linkApi.close();
    }
  }

  Future<void> stop() async {
    _unknownNodeTimer?.cancel();
    _unknownNodeTimer = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
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
    await _connectionChanges.close();
  }
}
