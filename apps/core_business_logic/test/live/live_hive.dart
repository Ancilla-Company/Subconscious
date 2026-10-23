// Real hive clients for the Dart live tests (see live_stack.dart).
//
// WebRTC (flutter_webrtc) does not exist in the test VM. The clients built
// here get a [PeerTransportFactory] that always fails, so the connector falls
// back to the signalling RELAY: the real relay crypto and handshake in Dart,
// against the real server and the real engine.
import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';

import 'live_stack.dart';

/// A transport factory for a platform without WebRTC: every direct attempt
/// fails at once, which sends the connector down the relay path.
final class RelayOnlyTransportFactory implements PeerTransportFactory {
  const RelayOnlyTransportFactory();

  @override
  Future<PeerTransport> create({
    required List<Map<String, dynamic>> iceServers,
  }) => throw const PeerConnectException(
    'WebRTC is not available in the test VM (relay only).',
  );
}

/// Signs [who] in against the real server with the account's password. (The
/// seeded refresh token is single use, so it is not spent here.)
Future<ServerAccountClient> signIn(
  LiveStack stack,
  LiveAccount who, {
  RefreshTokenStore? tokenStore,
}) async {
  final ServerAccountClient account = ServerAccountClient(
    baseUri: stack.serverUri,
    tokenStore: tokenStore ?? MemoryRefreshTokenStore(),
  );
  await account.loginWithEmail(email: who.email, password: who.password);
  return account;
}

/// A [HiveClient] with the relay-only transport and in-memory stores.
HiveClient newHiveClient(
  ServerAccountClient account, {
  IdentitySeedStore? seedStore,
  required String deviceName,
  required String platform,
}) => HiveClient(
  account: account,
  seedStore: seedStore ?? MemoryIdentitySeedStore(),
  pinStoreFactory: (String _) async => MemoryPinStore(),
  transportFactory: const RelayOnlyTransportFactory(),
  deviceName: deviceName,
  platform: platform,
  appVersion: 'live-test',
  directTimeout: const Duration(seconds: 2),
);

/// A signed-in, started thin node and everything to clean it up.
final class LiveThin {
  LiveThin._(this.account, this.hive, this.who);

  final ServerAccountClient account;
  final HiveClient hive;
  final LiveAccount who;

  String get nodeId => hive.identity!.nodeId;

  /// Signs in, registers the node with exactly [platform] and [deviceName] and
  /// starts signalling.
  static Future<LiveThin> start(
    LiveStack stack,
    LiveAccount who, {
    required String deviceName,
    String platform = 'browser',
    IdentitySeedStore? seedStore,
  }) async {
    final ServerAccountClient account = await signIn(stack, who);
    final HiveClient hive = newHiveClient(
      account,
      seedStore: seedStore,
      deviceName: deviceName,
      platform: platform,
    );
    final LiveThin thin = LiveThin._(account, hive, who);
    try {
      await hive.start();
      await eventually<bool>(
        () async => hive.signalConnected ? true : null,
        what: 'the signalling socket of "$deviceName" to connect',
      );
    } on Object {
      await thin.dispose();
      rethrow;
    }
    return thin;
  }

  /// Opens a relay link to [engineNodeId]. The engine learns about a brand new
  /// node through presence, so a first attempt can be refused; retry briefly
  /// (as a real client's reconcile loop does).
  Future<PeerLink> link(
    String engineNodeId, {
    Duration timeout = const Duration(seconds: 40),
  }) async {
    Object? last;
    try {
      return await eventually<PeerLink>(
        () async {
          try {
            return await hive.connectTo(engineNodeId);
          } on Object catch (error) {
            last = error;
            await hive.refreshDirectory();
            return null;
          }
        },
        what: 'a relay link to $engineNodeId',
        timeout: timeout,
      );
    } on TimeoutException catch (error) {
      throw TimeoutException('${error.message}; last error: $last');
    }
  }

  /// A [PeerEngineSocket] that has not connected yet.
  PeerEngineSocket socket(
    String engineNodeId, {
    String clientType = ClientType.browserExtension,
    String? name,
  }) => PeerEngineSocket(
    linkProvider: () => link(engineNodeId),
    identity: ClientIdentity(
      type: clientType,
      name: name ?? 'live dart client',
    ),
  );

  Future<void> dispose() async {
    try {
      await hive.dispose();
    } on Object {
      // Already closed.
    }
    await account.close();
  }
}

/// Records every frame of a socket so a test can wait for a reply.
final class FrameLog {
  FrameLog(EngineSocket socket) {
    _subscription = socket.frames.listen(frames.add, onError: errors.add);
  }

  final List<WireFrame> frames = <WireFrame>[];
  final List<Object> errors = <Object>[];
  late final StreamSubscription<WireFrame> _subscription;

  List<WireFrame> of(String type, [String? id]) => <WireFrame>[
    for (final WireFrame f in frames)
      if (f.type == type && (id == null || f.id == id)) f,
  ];

  Future<WireFrame> waitFor(
    String type, {
    String? id,
    int after = 0,
    Duration timeout = const Duration(seconds: 30),
  }) => eventually<WireFrame>(
    () async => of(type, id).length > after ? of(type, id).last : null,
    what: 'a "$type" frame${id == null ? '' : ' for $id'}',
    timeout: timeout,
    step: const Duration(milliseconds: 40),
  );

  /// The streamed text of one chat turn.
  String text(String turnId) => <String>[
    for (final WireFrame f in of('chat.delta', turnId))
      (f.data?['delta'] as String?) ?? '',
  ].join();

  Future<void> cancel() => _subscription.cancel();
}

/// One `chat.send` round trip on the echo model; returns the streamed text.
Future<String> chatRoundTrip(
  EngineSocket socket,
  FrameLog log,
  String workspaceUuid,
  String text,
) async {
  final String turnId = socket.sendChat(
    content: text,
    workspaceUuid: workspaceUuid,
  );
  await log.waitFor('chat.done', id: turnId);
  return log.text(turnId);
}
