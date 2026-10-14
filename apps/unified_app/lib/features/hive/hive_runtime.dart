import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'executor_selection.dart';
import 'secure_storage_stores.dart';
import 'webrtc_peer_transport.dart';

const String _serverUrl = String.fromEnvironment(
  'SUBCONSCIOUS_SERVER_URL',
  defaultValue: 'https://api.subconscious.chat',
);
const String _homeKey = 'subconscious.hive.home.v1';

enum HiveStatus { signedOut, busy, ready, error }

/// App-level owner of the thin-node stack: server session, identity, node
/// directory, signalling and peer links.
///
/// The Flutter web build runs this in reduced trust (webrtc.md 5.4): a browser
/// cannot hold a non-extractable Ed25519 key everywhere, so web nodes never
/// approve other nodes ([canApprove]).
final class HiveRuntime extends ChangeNotifier implements ExecutorDirectory {
  HiveRuntime({
    ServerAccountClient? account,
    HiveClient? hive,
    FlutterSecureStorage? storage,
    Uri? serverUri,
    ExecutorPreferenceStore? executorPreferences,
  }) : _storage = storage ?? defaultSecureStorage() {
    _executorPreferences =
        executorPreferences ?? SecureExecutorPreferenceStore(_storage);
    final ServerAccountClient accountClient =
        account ??
        ServerAccountClient(
          baseUri: serverUri ?? Uri.parse(_serverUrl),
          tokenStore: SecureRefreshTokenStore(_storage),
        );
    this.account = accountClient;
    this.hive =
        hive ??
        HiveClient(
          account: accountClient,
          seedStore: SecureIdentitySeedStore(_storage),
          pinStoreFactory: (String userId) =>
              SecurePinStore(userId, _storage).load(),
          transportFactory: const WebRtcPeerTransportFactory(),
          deviceName: _deviceName(),
          platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
          appVersion: '0.1.0',
        );
  }

  /// Shared instance used by the connection resolver and the devices screen.
  static final HiveRuntime shared = HiveRuntime();

  late final ServerAccountClient account;
  late final HiveClient hive;
  final FlutterSecureStorage _storage;
  late final ExecutorPreferenceStore _executorPreferences;
  StreamSubscription<List<NodeView>>? _viewSubscription;

  HiveStatus status = HiveStatus.signedOut;
  Object? error;
  List<NodeView> nodes = const <NodeView>[];
  bool _restored = false;

  bool get isSignedIn => account.user != null;
  String? get email => account.user?.email;

  /// Reduced trust on the web: never approves other nodes.
  bool get canApprove {
    if (kIsWeb) return false;
    final NodeIdentity? self = hive.identity;
    final NodeDirectory? dir = hive.directory;
    return self != null && dir != null && dir.isTrusted(self.nodeId);
  }

  NodeView? get localNode {
    for (final NodeView view in nodes) {
      if (view.isLocal) return view;
    }
    return null;
  }

  /// Online, verified full nodes (engines). The executor picker on the chat
  /// composer and the devices page list these; the chosen node id is sent as
  /// `executor` in `task.submit` (webrtc.md 7.4).
  List<NodeView> get executorCandidates => <NodeView>[
    for (final NodeView v in nodes)
      if (v.trusted && v.online && v.node.isEngine) v,
  ];

  /// Node id of the home engine this app is connected to, once resolved.
  String? homeEngineId;

  /// Executor choices: the connected engine (default) first, then every other
  /// candidate with its platform and connection tier.
  @override
  List<ExecutorOption> get options => <ExecutorOption>[
    ExecutorOption(
      nodeId: null,
      name: _homeName(),
      platform: _homeView()?.node.platform,
      tier: _homeView()?.tier,
    ),
    for (final NodeView v in executorCandidates)
      if (homeEngineId == null || !nodeIdsEqual(v.node.id, homeEngineId!))
        ExecutorOption(
          nodeId: v.node.id,
          name: v.node.name.isEmpty ? v.node.id : v.node.name,
          platform: v.node.platform,
          tier: v.tier,
        ),
  ];

  NodeView? _homeView() {
    final String? id = homeEngineId;
    if (id == null) return null;
    for (final NodeView v in nodes) {
      if (nodeIdsEqual(v.node.id, id)) return v;
    }
    return null;
  }

  String _homeName() {
    final NodeView? home = _homeView();
    if (home == null) return 'This engine';
    return home.node.name.isEmpty ? 'This engine' : '${home.node.name} (home)';
  }

  @override
  String? nameOf(String nodeId) {
    for (final NodeView v in nodes) {
      if (nodeIdsEqual(v.node.id, nodeId)) {
        return v.node.name.isEmpty ? v.node.id : v.node.name;
      }
    }
    return null;
  }

  @override
  Future<String?> loadSelection(String threadUuid) =>
      _executorPreferences.read(threadUuid);

  @override
  Future<void> saveSelection(String threadUuid, String? nodeId) =>
      _executorPreferences.write(threadUuid, nodeId);

  /// Restores a stored server session without UI. Safe to call repeatedly.
  Future<void> restore() async {
    if (_restored || isSignedIn) return;
    _restored = true;
    try {
      if (await account.restore()) await _startHive();
    } on Object catch (caught) {
      _fail(caught);
    }
  }

  Future<void> signIn({required String email, required String password}) async {
    _busy();
    try {
      await account.loginWithEmail(email: email, password: password);
      await _startHive();
    } on Object catch (caught) {
      _fail(caught);
    }
  }

  /// Starts the hive after [account] signed in elsewhere (for example from the
  /// account panel's sign-in or sign-up). Failures land in [error].
  Future<void> adoptSession() async {
    try {
      await _startHive();
    } on Object catch (caught) {
      _fail(caught);
    }
  }

  Future<void> signOut() async {
    await _viewSubscription?.cancel();
    _viewSubscription = null;
    await hive.stop();
    await account.logout();
    nodes = const <NodeView>[];
    error = null;
    status = HiveStatus.signedOut;
    _restored = false;
    notifyListeners();
  }

  Future<void> _startHive() async {
    _busy();
    await hive.start();
    await _viewSubscription?.cancel();
    _viewSubscription = hive.nodeViews.listen((List<NodeView> views) {
      nodes = views;
      notifyListeners();
    });
    nodes = hive.currentViews();
    error = null;
    status = HiveStatus.ready;
    notifyListeners();
  }

  Future<void> refresh() async {
    try {
      nodes = await hive.refreshDirectory();
      notifyListeners();
    } on Object catch (caught) {
      _fail(caught);
    }
  }

  /// Short authentication string between this device and [other].
  Future<String> codeFor(DirectoryNode other) => hive.sasFor(other);

  /// Signs the approval after the user confirmed the code on both devices.
  Future<void> approve(DirectoryNode pending) async {
    if (!canApprove) {
      throw StateError('This device cannot approve other devices.');
    }
    await hive.approve(pending);
  }

  Future<void> revoke(DirectoryNode node) => hive.revoke(node);

  Future<void> setHomeEngine(String nodeId) async {
    await _storage.write(key: _homeKey, value: nodeId);
    notifyListeners();
  }

  /// "No local engine reachable but signed in": builds a repository that talks
  /// to a home engine over WebRTC. Returns null when not signed in or when no
  /// verified engine is online.
  Future<EngineRepository?> resolveRepository() async {
    await restore();
    if (!isSignedIn || !hive.started) return null;
    await hive.refreshDirectory();
    final String? last = await _storage.read(key: _homeKey);
    final DirectoryNode? home = chooseHomeEngine(
      hive.currentViews(),
      lastUsedNodeId: last,
    );
    if (home == null) return null;
    await hive.connectTo(home.id); // fail fast with a clear error
    await _storage.write(key: _homeKey, value: home.id);
    homeEngineId = home.id;
    notifyListeners();
    Future<PeerLink> link() => hive.connectTo(home.id);
    return EngineRepository(
      rest: RestEngineClient(
        baseUri: Uri.parse('http://peer.invalid/api/v1/'),
        token: '',
        client: ReconnectingTunnelClient(link),
      ),
      socket: PeerEngineSocket(linkProvider: link),
    );
  }

  void _busy() {
    status = HiveStatus.busy;
    notifyListeners();
  }

  void _fail(Object caught) {
    error = caught;
    status = isSignedIn ? HiveStatus.ready : HiveStatus.error;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_viewSubscription?.cancel());
    unawaited(hive.dispose());
    super.dispose();
  }
}

String _deviceName() {
  if (kIsWeb) return 'Subconscious (web)';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Android device',
    TargetPlatform.iOS => 'iPhone or iPad',
    TargetPlatform.windows => 'Windows PC',
    TargetPlatform.macOS => 'Mac',
    TargetPlatform.linux => 'Linux PC',
    TargetPlatform.fuchsia => 'Fuchsia device',
  };
}

/// [http.BaseClient] that follows the home engine link across reconnects, so
/// a repository created once keeps working after the peer link is replaced.
final class ReconnectingTunnelClient extends http.BaseClient {
  ReconnectingTunnelClient(this._linkProvider);

  final Future<PeerLink> Function() _linkProvider;
  PeerLink? _link;
  DataChannelHttpClient? _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final PeerLink link = await _linkProvider();
    if (!identical(link, _link) || _inner == null) {
      _inner?.close();
      _inner = DataChannelHttpClient(link: link);
      _link = link;
    }
    return _inner!.send(request);
  }

  @override
  void close() {
    _inner?.close();
    _inner = null;
    _link = null;
  }
}
