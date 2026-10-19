import 'dart:async';
import 'dart:typed_data';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'executor_selection.dart';
import 'reconcile_backoff.dart';
import 'secure_storage_stores.dart';
import 'webrtc_peer_transport.dart';

const String _serverUrl = String.fromEnvironment(
  'SUBCONSCIOUS_SERVER_URL',
  defaultValue: 'https://api.subconscious.chat',
);
const String _homeKey = 'subconscious.hive.home.v1';
const String _preferredKey = 'subconscious.hive.preferredEngine.v1';
const String _autoConnectKey = 'subconscious.hive.autoConnect.v1';

enum HiveStatus { signedOut, busy, ready, error }

/// State of this device's connection to a remote (home) engine.
enum EngineLinkState { disconnected, connecting, connected, failed }

/// Whether this device may approve others, and why not. The Approve button
/// and every approval notice read this one value, so they cannot disagree.
enum ApprovalAbility {
  /// This thin node is trusted and signs approvals itself.
  allowed,

  /// A trusted local engine approves on this device's behalf.
  viaLocalEngine,

  /// Not known yet (identity, directory or the engine row is missing).
  loading,

  /// Web builds run in reduced trust and never approve.
  webBlocked,

  /// This device is not approved on the account.
  notTrusted,

  /// The local engine itself is not approved (sign the engine in again).
  engineNotTrusted,
}

/// Default time a vanished engine is kept before the link is dropped.
const Duration defaultEngineOfflineGrace = Duration(seconds: 25);

/// Waits between probes while the local engine is starting (about 20 s).
const List<Duration> defaultLocalProbeDelays = <Duration>[
  Duration(milliseconds: 500),
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 4),
  Duration(seconds: 4),
  Duration(seconds: 4),
];

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
    this.engineOfflineGrace = defaultEngineOfflineGrace,
    this.localProbeDelays = defaultLocalProbeDelays,
    Future<void> Function(Duration)? probeSleep,
    ReconcileBackoff? reconcileBackoff,
  }) : _storage = storage ?? defaultSecureStorage(),
       _probeSleep = probeSleep ?? Future<void>.delayed,
       _backoff = reconcileBackoff ?? ReconcileBackoff() {
    _executorPreferences =
        executorPreferences ?? SecureExecutorPreferenceStore(_storage);
    final ServerAccountClient accountClient =
        account ??
        ServerAccountClient(
          baseUri: serverUri ?? Uri.parse(_serverUrl),
          tokenStore: SecureRefreshTokenStore(_storage),
        );
    this.account = accountClient;
    accountClient.onSessionExpired = _onSessionExpired;
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

  /// How long a vanished home engine is kept before the link is dropped and
  /// how long the card keeps saying "Reconnecting" after the last engine left.
  final Duration engineOfflineGrace;

  /// Probe schedule while the local engine is starting.
  final List<Duration> localProbeDelays;
  final Future<void> Function(Duration) _probeSleep;
  final ReconcileBackoff _backoff;

  HiveStatus status = HiveStatus.signedOut;
  Object? error;
  List<NodeView> nodes = const <NodeView>[];
  bool _restored = false;

  /// True after a 502/503/504 from the hive server: the list is kept, the UI
  /// shows "Server unavailable, retrying" and the reconcile loop keeps going.
  bool serverUnavailable = false;

  /// Mirrors the signalling socket (`hive.connectionChanges`). Push presence
  /// is only trusted while this is true.
  bool signalConnected = false;

  /// True when a live engine runs on this machine (found through its
  /// `runtime.json`). That engine is the full node and this GUI is only a
  /// client of it, so no thin device is registered and no approval is asked.
  /// Set through [markLocalEngineFound].
  bool hasLocalFullNode = false;

  /// True on platforms that run an engine next to the app (desktop). The thin
  /// node is then not registered until the local engine had its chance.
  bool expectsLocalEngine = false;

  /// True while waiting for the local engine to appear.
  bool linkingLocalEngine = false;

  /// The wait expired and no local engine was found.
  bool localEngineMissing = false;

  /// The user chose to use this PC as a remote client without a local engine.
  /// Not persisted.
  bool allowThinFallback = false;

  /// Answers whether the local engine is reachable (set in `main.dart`).
  Future<bool> Function()? probeLocalEngine;

  /// The local engine's hive `state` and `detail` (for the signed-out banner).
  String? engineHiveState;
  String? engineHiveDetail;

  /// Shown after Approve when the device is still pending.
  String? approvalNote;

  bool _localFoundHandled = false;
  bool _legacyLinkAttempted = false;
  bool _waitingForLocal = false;
  int _waitGeneration = 0;
  String? _clientId;

  /// The local engine's REST client. With [hasLocalFullNode] the device list
  /// comes from that engine (it holds the account's directory and the trust
  /// verdicts), since this GUI registers nothing itself.
  Future<RestEngineClient?> Function()? localEngineClient;

  /// How long a signed-in pending device waits for automatic approval before
  /// the screen falls back to manual guidance and the code.
  Duration approvalGrace = const Duration(seconds: 30);

  bool get isSignedIn => account.user != null;
  String? get email => account.user?.email;

  /// The single source of truth for approval (design 5.7 and 11.2).
  ///
  /// With a local engine, the engine approves for this GUI: a trusted engine
  /// row gives [ApprovalAbility.viaLocalEngine], an untrusted one
  /// [ApprovalAbility.engineNotTrusted]. Otherwise the web never approves
  /// (reduced trust) and a thin node approves only once it is trusted.
  ApprovalAbility get approvalAbility {
    final ApprovalAbility? forced = debugApprovalAbility;
    if (forced != null) return forced;
    if (hasLocalFullNode) {
      final NodeView? engine = localNode;
      if (engine == null) return ApprovalAbility.loading;
      return engine.trusted
          ? ApprovalAbility.viaLocalEngine
          : ApprovalAbility.engineNotTrusted;
    }
    if (debugIsWeb ?? kIsWeb) return ApprovalAbility.webBlocked;
    final NodeDirectory? dir = hive.directory;
    final NodeIdentity? self = hive.identity;
    if (dir == null || self == null || localNode == null) {
      return ApprovalAbility.loading;
    }
    return dir.isTrusted(self.nodeId)
        ? ApprovalAbility.allowed
        : ApprovalAbility.notTrusted;
  }

  /// Test seams: pretend to be a web build, or force a state for widget rows.
  @visibleForTesting
  bool? debugIsWeb;
  @visibleForTesting
  ApprovalAbility? debugApprovalAbility;

  bool get canApprove =>
      approvalAbility == ApprovalAbility.allowed ||
      approvalAbility == ApprovalAbility.viaLocalEngine;

  /// True when the "cannot approve" text applies: a pending non-local device
  /// exists and this device is blocked from approving. Never with a local
  /// engine (AC-28).
  bool get showCannotApprove {
    if (hasLocalFullNode) return false;
    final ApprovalAbility ability = approvalAbility;
    if (ability != ApprovalAbility.webBlocked &&
        ability != ApprovalAbility.notTrusted) {
      return false;
    }
    return nodes.any((NodeView v) => !v.isLocal && v.node.status == 'pending');
  }

  ApprovalAbility? _lastLoggedApproval;

  void _logApprovalChange() {
    final ApprovalAbility now = approvalAbility;
    if (now == _lastLoggedApproval) return;
    _lastLoggedApproval = now;
    final NodeDirectory? dir = hive.directory;
    final NodeIdentity? self = hive.identity;
    debugPrint(
      'approvalAbility=${now.name} identity=${self != null} '
      'directory=${dir != null} '
      'isTrusted=${self != null && dir != null && dir.isTrusted(self.nodeId)}',
    );
  }

  bool _disposed = false;

  /// Background work (probes, refreshes) can finish after [dispose]; those
  /// late notifications are dropped.
  @override
  void notifyListeners() {
    if (_disposed) return;
    _logApprovalChange();
    super.notifyListeners();
  }

  String? _lastEngineRows;

  /// One line per engine row each time the list changes while no engine is
  /// connected: the evidence for why a visible engine was not chosen.
  void _logEngineRows() {
    if (engineState == EngineLinkState.connected) return;
    final List<String> rows = <String>[
      for (final NodeView v in nodes)
        if (v.node.isEngine)
          'engine ${v.node.id} trusted=${v.trusted} online=${v.online} '
              'isLocal=${v.isLocal}',
    ];
    final String joined = rows.join('\n');
    if (joined == _lastEngineRows) return;
    _lastEngineRows = joined;
    for (final String row in rows) {
      debugPrint(row);
    }
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

  /// Engine the user explicitly chose; connected to whenever it is online.
  String? preferredEngineId;

  /// False after the user disconnects: no automatic connection until they
  /// reconnect or pick an engine.
  bool autoConnect = true;

  EngineLinkState engineState = EngineLinkState.disconnected;

  /// Re-runs the dashboard's connection resolver (set in `main.dart`).
  Future<void> Function()? onEngineAvailable;

  Timer? _reconcileTimer;
  Timer? _homeTimer;
  Timer? _hysteresisTimer;
  StreamSubscription<bool>? _connectionSubscription;
  DateTime? _homeOfflineSince;
  DateTime? _lastCandidateAt;
  bool _reconnecting = false;
  bool _prefsLoaded = false;

  /// True for the grace window after the last online engine disappeared. The
  /// card says "Reconnecting" instead of "No engine online" during it, so a
  /// short blip never flashes a dead end.
  bool get inEngineHysteresis {
    final DateTime? last = _lastCandidateAt;
    if (last == null) return false;
    return DateTime.now().difference(last) < engineOfflineGrace;
  }

  /// Records when a connectable engine was last seen and arms a timer that
  /// repaints once the grace window ends.
  void _noteCandidates() {
    if (connectableEngines.isNotEmpty ||
        (homeEngineId != null && _homeView()?.online == true)) {
      _lastCandidateAt = DateTime.now();
      _hysteresisTimer?.cancel();
      _hysteresisTimer = null;
      return;
    }
    final DateTime? last = _lastCandidateAt;
    if (last == null || _hysteresisTimer != null) return;
    final Duration left = engineOfflineGrace - DateTime.now().difference(last);
    if (left <= Duration.zero) return;
    _hysteresisTimer = Timer(left, () {
      _hysteresisTimer = null;
      notifyListeners();
    });
  }

  /// The safety reconcile runs only while push presence cannot be trusted:
  /// the socket is down, or the server answered 502/503/504.
  @visibleForTesting
  bool get shouldReconcile =>
      isSignedIn &&
      !hasLocalFullNode &&
      thinActive &&
      (!signalConnected || serverUnavailable);

  /// True while this device runs as a thin node (its hive client is started).
  @visibleForTesting
  bool thinActive = false;

  void _scheduleReconcile() {
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    if (!shouldReconcile) return;
    _reconcileTimer = Timer(_backoff.next(), () async {
      _reconcileTimer = null;
      await refresh();
      _scheduleReconcile();
    });
  }

  void _onSignalChanged(bool up) {
    signalConnected = up;
    if (up) _backoff.reset();
    _scheduleReconcile();
    notifyListeners();
  }

  /// What the picker should do right now for the current node list.
  EngineChoice get engineChoice =>
      chooseEngine(nodes, preferredId: preferredEngineId);

  /// Name of the connected engine, or null.
  String? get connectedEngineName {
    final String? id = homeEngineId;
    return id == null ? null : nameOf(id);
  }

  /// Candidate engines the user can connect to (online, trusted, not local).
  List<NodeView> get connectableEngines => <NodeView>[
    for (final NodeView v in nodes)
      if (v.trusted && v.online && v.node.isEngine && !v.isLocal) v,
  ];

  Future<void> _loadPreferences() async {
    if (_prefsLoaded) return;
    _prefsLoaded = true;
    try {
      preferredEngineId ??= await _storage.read(key: _preferredKey);
      autoConnect = await _storage.read(key: _autoConnectKey) != 'false';
    } on Object catch (caught) {
      debugPrint('Could not read engine preference: $caught');
    }
  }

  Future<void> _savePreferences() async {
    final String? preferred = preferredEngineId;
    if (preferred == null) {
      await _storage.delete(key: _preferredKey);
    } else {
      await _storage.write(key: _preferredKey, value: preferred);
    }
    await _storage.write(key: _autoConnectKey, value: '$autoConnect');
  }

  /// User picks [nodeId]: remember it and connect now.
  Future<void> selectEngine(String nodeId) async {
    await _loadPreferences();
    preferredEngineId = nodeId;
    autoConnect = true;
    await _savePreferences();
    notifyListeners();
    await _reconnect();
  }

  /// User disconnects: stop automatic connecting until they ask again.
  ///
  /// `autoConnect` and `engineState` change together in one notification, so
  /// `connected` with auto-connect off is unreachable.
  Future<void> disconnectEngine() async {
    await _loadPreferences();
    autoConnect = false;
    homeEngineId = null;
    engineState = EngineLinkState.disconnected;
    notifyListeners();
    await _savePreferences();
    await _reconnect();
  }

  /// User asks to connect again (re-enables automatic connecting).
  Future<void> reconnectEngine() async {
    await _loadPreferences();
    autoConnect = true;
    await _savePreferences();
    notifyListeners();
    try {
      await refresh();
    } finally {
      await _reconnect();
    }
  }

  Future<void> _reconnect() async {
    final Future<void> Function()? callback = onEngineAvailable;
    if (callback == null || _reconnecting) return;
    _reconnecting = true;
    try {
      await callback();
    } on Object catch (caught) {
      debugPrint('Engine reconnect failed: $caught');
    } finally {
      _reconnecting = false;
    }
  }

  /// Connects when an engine is (or becomes) available and nothing is
  /// connected yet, or when the preferred engine appears while connected to
  /// another one. Called on every node-list change and by the watch timer.
  @visibleForTesting
  Future<void> maybeAutoConnect() async {
    if (!isSignedIn || hasLocalFullNode || _reconnecting) return;
    await _loadPreferences();
    _logEngineRows();
    final String? home = homeEngineId;
    if (home != null) {
      final NodeView? current = _homeView();
      if (current != null && current.online) {
        _homeOfflineSince = null;
        _homeTimer?.cancel();
        _homeTimer = null;
      } else {
        // Keep the link through a short blip; drop it only if the engine is
        // still gone after the grace window.
        final DateTime since = _homeOfflineSince ??= DateTime.now();
        final Duration left =
            engineOfflineGrace - DateTime.now().difference(since);
        if (left > Duration.zero) {
          _homeTimer?.cancel();
          _homeTimer = Timer(left, () => unawaited(maybeAutoConnect()));
          return;
        }
        _homeOfflineSince = null;
        _homeTimer = null;
        homeEngineId = null;
        engineState = EngineLinkState.disconnected;
      }
    }
    _noteCandidates();
    notifyListeners();
    if (!autoConnect) return;
    final EngineChoice choice = engineChoice;
    if (choice.kind != EngineChoiceKind.connect) return;
    final String target = choice.node!.id;
    final String? connected = homeEngineId;
    if (connected == null || !nodeIdsEqual(connected, target)) {
      await _reconnect();
    }
  }

  void _stopTimers() {
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    _homeTimer?.cancel();
    _homeTimer = null;
    _hysteresisTimer?.cancel();
    _hysteresisTimer = null;
    _homeOfflineSince = null;
    _lastCandidateAt = null;
    thinActive = false;
    signalConnected = false;
    serverUnavailable = false;
    homeEngineId = null;
    engineState = EngineLinkState.disconnected;
  }

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
    await _loadPreferences();
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
    _stopTimers();
    _abortLocalWait();
    await _viewSubscription?.cancel();
    _viewSubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    await hive.stop();
    await account.logout();
    nodes = const <NodeView>[];
    error = null;
    status = HiveStatus.signedOut;
    _restored = false;
    notifyListeners();
  }

  Future<void> _startHive() async {
    if (hasLocalFullNode) {
      error = null;
      status = HiveStatus.ready;
      await _loadFromLocalEngine();
      notifyListeners();
      unawaited(_linkLegacyThin());
      return;
    }
    if (expectsLocalEngine && !allowThinFallback) {
      // The engine is this machine's full node and this GUI only its client.
      // Do not register a second device until the engine had its chance.
      unawaited(_waitForLocalEngine());
      return;
    }
    await _startThin();
  }

  Future<void> _startThin() async {
    _busy();
    await hive.start();
    thinActive = true;
    await _viewSubscription?.cancel();
    _viewSubscription = hive.nodeViews.listen((List<NodeView> views) {
      nodes = views;
      _noteCandidates();
      notifyListeners();
      unawaited(maybeAutoConnect());
    });
    await _connectionSubscription?.cancel();
    _connectionSubscription = hive.connectionChanges.listen(_onSignalChanged);
    signalConnected = hive.signalConnected;
    nodes = hive.currentViews();
    error = null;
    serverUnavailable = false;
    status = HiveStatus.ready;
    notifyListeners();
    _scheduleReconcile();
    unawaited(maybeAutoConnect());
  }

  void _abortLocalWait() {
    _waitGeneration++;
    _waitingForLocal = false;
    linkingLocalEngine = false;
  }

  /// Polls for the local engine (about 20 s) before falling back. While it
  /// runs, no thin node is registered (AC-6, AC-10).
  Future<void> _waitForLocalEngine() async {
    if (_waitingForLocal) return;
    _waitingForLocal = true;
    final int generation = ++_waitGeneration;
    linkingLocalEngine = true;
    localEngineMissing = false;
    status = HiveStatus.busy;
    notifyListeners();
    final Future<bool> Function()? probe = probeLocalEngine;
    bool aborted() => generation != _waitGeneration || !isSignedIn;
    try {
      for (int i = 0; i <= localProbeDelays.length; i++) {
        if (aborted()) return;
        bool found = false;
        try {
          found = probe != null && await probe();
        } on Object catch (caught) {
          debugPrint('Local engine probe failed: $caught');
        }
        if (aborted()) return;
        if (found) {
          status = HiveStatus.ready;
          markLocalEngineFound();
          await _reconnect();
          notifyListeners();
          return;
        }
        if (i < localProbeDelays.length) await _probeSleep(localProbeDelays[i]);
      }
      if (aborted()) return;
      linkingLocalEngine = false;
      localEngineMissing = true;
      status = HiveStatus.ready;
      notifyListeners();
    } finally {
      if (generation == _waitGeneration) {
        _waitingForLocal = false;
        if (linkingLocalEngine) linkingLocalEngine = false;
      }
    }
  }

  /// User gives up on the local engine: register this PC as a remote client.
  Future<void> useThisPcAsRemoteClient() async {
    allowThinFallback = true;
    localEngineMissing = false;
    _abortLocalWait();
    try {
      await _startHive();
    } on Object catch (caught) {
      _fail(caught);
    }
  }

  /// Retry button on the "engine did not start" card.
  Future<void> retryLocalEngineLink() async {
    localEngineMissing = false;
    _abortLocalWait();
    try {
      await _startHive();
    } on Object catch (caught) {
      _fail(caught);
    }
  }

  /// Called by the connection resolver when it found the local engine.
  /// Idempotent: only the first call runs [onLocalEngineFound].
  void markLocalEngineFound() {
    hasLocalFullNode = true;
    localEngineMissing = false;
    _abortLocalWait(); // also clears linkingLocalEngine
    if (isSignedIn && status == HiveStatus.busy) status = HiveStatus.ready;
    if (_localFoundHandled) return;
    _localFoundHandled = true;
    unawaited(onLocalEngineFound());
  }

  /// The local engine appeared: this device stops being a thin node, lists
  /// devices through the engine and folds its earlier thin registration (if
  /// any) under the engine. 404/405/422 from an old server are not fatal.
  @visibleForTesting
  Future<void> onLocalEngineFound() async {
    try {
      _stopTimers();
      await _viewSubscription?.cancel();
      _viewSubscription = null;
      await _connectionSubscription?.cancel();
      _connectionSubscription = null;
      await hive.stop();
      if (!isSignedIn) {
        notifyListeners();
        return;
      }
      await _awaitLocalClient();
      await _loadFromLocalEngine();
      notifyListeners();
      await _linkLegacyThin();
    } on Object catch (caught) {
      debugPrint('Linking to the local engine failed: $caught');
    }
  }

  Future<void> _awaitLocalClient() async {
    for (int i = 0; i < 10; i++) {
      if (await localEngineClient?.call() != null) return;
      await _probeSleep(const Duration(milliseconds: 300));
    }
  }

  /// Folds the thin node this device registered earlier (before the local
  /// engine existed) under the local engine, once per process.
  Future<void> _linkLegacyThin() async {
    if (_legacyLinkAttempted || !isSignedIn || !hasLocalFullNode) return;
    final NodeView? engine = localNode;
    if (engine == null) return;
    _legacyLinkAttempted = true;
    try {
      await hive.linkLegacyThinToEngine(engine.node.id);
    } on Object catch (caught) {
      debugPrint('Legacy device link failed: $caught');
    }
  }

  /// Lists the account's devices through the local engine. A failure leaves
  /// the list empty; it never turns the account sign-in into an error.
  Future<void> _loadFromLocalEngine() async {
    try {
      final RestEngineClient? client = await localEngineClient?.call();
      if (client == null) return;
      final Map<String, dynamic> snapshot = await client.getHiveSnapshot();
      engineHiveState = snapshot['state'] as String?;
      engineHiveDetail = snapshot['detail'] as String?;
      final Object? rows = snapshot['nodes'];
      nodes = <NodeView>[
        if (rows is List)
          for (final Object? row in rows)
            if (row is Map<String, dynamic>)
              if (_viewFromEngineRow(row) case final NodeView view) view,
      ];
    } on Object catch (caught) {
      debugPrint('Could not list devices from the local engine: $caught');
    }
  }

  Future<void> refresh() async {
    if (hasLocalFullNode) {
      await _loadFromLocalEngine();
      notifyListeners();
      return;
    }
    try {
      nodes = await hive.refreshDirectory();
      error = null;
      serverUnavailable = false;
      _backoff.reset();
      notifyListeners();
      unawaited(maybeAutoConnect());
    } on HiveApiException catch (caught) {
      if (caught.statusCode == 502 ||
          caught.statusCode == 503 ||
          caught.statusCode == 504) {
        // Keep the list and the link; the reconcile loop retries.
        serverUnavailable = true;
        notifyListeners();
        _scheduleReconcile();
      } else {
        _fail(caught);
      }
    } on Object catch (caught) {
      _fail(caught);
    }
  }

  /// This device's name as registered with the server.
  String get deviceName => _deviceName();

  /// Per-install id (32 hex characters), sent only to the local engine.
  Future<String> clientId() async =>
      _clientId ??= await SecureClientIdStore(_storage).readOrCreate();

  NodeView? _viewById(String id) {
    for (final NodeView v in nodes) {
      if (nodeIdsEqual(v.node.id, id)) return v;
    }
    return null;
  }

  /// Short authentication string between this device and [other]. With a
  /// local engine the engine computed it for the row.
  Future<String> codeFor(DirectoryNode other) async {
    if (hasLocalFullNode) return _viewById(other.id)?.sas ?? '';
    return hive.sasFor(other);
  }

  /// Signs the approval after the user confirmed the code on both devices.
  /// With a local engine the engine approves; otherwise this thin node does.
  Future<void> approve(DirectoryNode pending) async {
    if (!canApprove) {
      throw StateError('This device cannot approve other devices.');
    }
    approvalNote = null;
    if (hasLocalFullNode) {
      final RestEngineClient? client = await localEngineClient?.call();
      final String? sas = _viewById(pending.id)?.sas;
      if (client == null || sas == null) {
        throw StateError('The local engine cannot approve this device now.');
      }
      await client.approveHiveNode(pending.id, sas);
    } else {
      await hive.approve(pending);
    }
    await refresh();
    final NodeView? after = _viewById(pending.id);
    if (after != null && after.node.status == 'pending') {
      approvalNote =
          'Approval did not change this device. Remove it and sign in on '
          'that device again.';
    }
    notifyListeners();
  }

  Future<void> revoke(DirectoryNode node) async {
    if (hasLocalFullNode) {
      final RestEngineClient? client = await localEngineClient?.call();
      if (client == null) {
        throw StateError('The local engine cannot remove this device now.');
      }
      await client.revokeHiveNode(node.id);
      await refresh();
      return;
    }
    await hive.revoke(node);
  }

  /// Asks the local engine to back up and clear its local hive bookkeeping
  /// (the hive-mismatch recovery), then re-reads the engine snapshot.
  Future<void> resetLocalHive() async {
    final RestEngineClient? client = await localEngineClient?.call();
    if (client == null) {
      throw StateError('The local engine cannot reset its hive data now.');
    }
    await client.resetLocalHive();
    await refresh();
  }

  Future<void> setHomeEngine(String nodeId) => selectEngine(nodeId);

  /// "No local engine reachable but signed in": builds a repository that talks
  /// to a home engine over WebRTC. Returns null when not signed in or when no
  /// verified engine is online.
  Future<EngineRepository?> resolveRepository() async {
    await restore();
    await _loadPreferences();
    if (!isSignedIn || !hive.started) return null;
    if (!autoConnect) {
      homeEngineId = null;
      engineState = EngineLinkState.disconnected;
      notifyListeners();
      return null;
    }
    await hive.refreshDirectory();
    nodes = hive.currentViews();
    final EngineChoice choice = chooseEngine(
      nodes,
      preferredId: preferredEngineId,
    );
    final DirectoryNode? home = choice.node;
    if (choice.kind != EngineChoiceKind.connect || home == null) {
      homeEngineId = null;
      engineState = EngineLinkState.disconnected;
      notifyListeners();
      return null;
    }
    engineState = EngineLinkState.connecting;
    notifyListeners();
    try {
      await hive.connectTo(home.id); // fail fast with a clear error
    } on Object {
      homeEngineId = null;
      engineState = EngineLinkState.failed;
      notifyListeners();
      rethrow;
    }
    if (!autoConnect) {
      // The user paused while the link was being set up.
      homeEngineId = null;
      engineState = EngineLinkState.disconnected;
      notifyListeners();
      return null;
    }
    await _storage.write(key: _homeKey, value: home.id);
    homeEngineId = home.id;
    engineState = EngineLinkState.connected;
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

  /// The server rejected the session (401): drop it so the UI shows signed
  /// out with the cause in [error], instead of a dead session.
  void _onSessionExpired(HiveApiException caught) {
    _stopTimers();
    _abortLocalWait();
    unawaited(_viewSubscription?.cancel());
    _viewSubscription = null;
    unawaited(_connectionSubscription?.cancel());
    _connectionSubscription = null;
    unawaited(hive.stop());
    nodes = const <NodeView>[];
    error = caught;
    status = HiveStatus.signedOut;
    _restored = false;
    notifyListeners();
  }

  void _fail(Object caught) {
    error = caught;
    status = isSignedIn ? HiveStatus.ready : HiveStatus.error;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconcileTimer?.cancel();
    _homeTimer?.cancel();
    _hysteresisTimer?.cancel();
    _waitGeneration++;
    unawaited(_connectionSubscription?.cancel());
    unawaited(_viewSubscription?.cancel());
    unawaited(hive.dispose());
    super.dispose();
  }
}

/// Maps one `GET /hive/nodes` row from the local engine to a [NodeView]. The
/// engine already verified keys and approval chains, so `trusted` is its
/// verdict; the public key is not needed for display and is left zeroed.
NodeView? _viewFromEngineRow(Map<String, dynamic> row) {
  final Object? id = row['id'];
  if (id is! String) return null;
  final bool online = row['online'] == true;
  return NodeView(
    node: DirectoryNode(
      id: id,
      kind: row['kind'] as String? ?? 'thin',
      name: row['name'] as String? ?? '',
      platform: row['platform'] as String? ?? '',
      appVersion: '',
      publicKey: Uint8List(32),
      status: row['status'] as String? ?? 'active',
      online: online,
    ),
    trusted: row['trusted'] == true,
    online: online,
    isLocal: row['local'] == true,
    tier: row['tier'] as String?,
    parentId: row['parent_node_id'] is String
        ? row['parent_node_id'] as String
        : null,
    clients: <String>[
      if (row['clients'] is List)
        for (final Object? c in row['clients'] as List<Object?>)
          if (c is String) c,
    ],
    sas: row['sas'] is String ? row['sas'] as String : null,
  );
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
