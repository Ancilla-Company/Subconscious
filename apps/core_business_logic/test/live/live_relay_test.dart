@Tags(<String>['live'])
library;

import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'live_hive.dart';
import 'live_stack.dart';

/// Live scenarios 2 (collision) and 5 (relay) of
/// `.agents/tasks/live-tests/contracts.md`: the Dart client reaches the real
/// engine through the signalling relay (the stack runs with `--no-webrtc`, and
/// the Dart client has no WebRTC at all).
Future<void> main() async {
  final LiveStack? stack = await LiveStack.resolve();
  final String? skip = stack == null ? liveSkipReason : null;

  void liveTest(String name, Future<void> Function(LiveStack stack) body) {
    test(
      name,
      () => body(stack!),
      skip: skip,
      timeout: const Timeout(Duration(minutes: 4)),
    );
  }

  group('live: relay to the real engine', () {
    liveTest('hello, a chat round trip and REST over the tunnel', (
      LiveStack stack,
    ) async {
      // Bug class: with WebRTC unavailable (extension, corporate network,
      // test VM) the Dart relay crypto/handshake silently disagrees with the
      // engine's: no hello ack, no chat stream, or a dead REST tunnel.
      final String workspace = await createWorkspace(
        stack.engine,
        'Dart relay',
      );
      final LiveThin thin = await LiveThin.start(
        stack,
        stack.alice,
        deviceName: uniqueName('dart-relay'),
      );
      addTearDown(thin.dispose);

      final PeerEngineSocket socket = thin.socket(stack.engine.nodeId);
      final FrameLog log = FrameLog(socket);
      addTearDown(socket.dispose);
      addTearDown(log.cancel);
      await socket.connect(); // client.hello acknowledged, or this throws
      await log.waitFor('client.hello.ack');
      expect(
        thin.hive.connector!.linkFor(stack.engine.nodeId)?.tier,
        'ws-relay',
      );

      final String echoed = await chatRoundTrip(
        socket,
        log,
        workspace,
        'hello through the dart relay',
      );
      expect(echoed, contains('hello through the dart relay'));

      final PeerLink link = await thin.link(stack.engine.nodeId);
      final DataChannelHttpClient tunnel = DataChannelHttpClient(link: link);
      addTearDown(tunnel.close);
      final RestEngineClient rest = RestEngineClient(
        baseUri: Uri.parse('http://peer.invalid/api/v1/'),
        token: '',
        client: tunnel,
      );
      final List<Workspace> workspaces = await rest.listWorkspaces();
      expect(workspaces.map((Workspace w) => w.uuid), contains(workspace));

      // Not on the thin-client allowlist: refused, not answered.
      final http.Response settings = await tunnel.get(
        Uri.parse('http://peer.invalid/api/v1/settings'),
      );
      expect(settings.statusCode, anyOf(400, 403));
    });

    liveTest('two Dart clients at once do not interfere', (
      LiveStack stack,
    ) async {
      // Bug class: relay sessions share state: one client's stream reaches the
      // other, or the second client kills the first.
      final String workspace = await createWorkspace(stack.engine, 'Dart two');
      final LiveThin first = await LiveThin.start(
        stack,
        stack.alice,
        deviceName: 'Browser extension (Chrome)',
      );
      addTearDown(first.dispose);
      final LiveThin second = await LiveThin.start(
        stack,
        stack.alice,
        deviceName: 'Browser extension (Chrome) #2',
        platform: 'web',
      );
      addTearDown(second.dispose);

      final PeerEngineSocket socketA = first.socket(stack.engine.nodeId);
      final PeerEngineSocket socketB = second.socket(stack.engine.nodeId);
      final FrameLog logA = FrameLog(socketA);
      final FrameLog logB = FrameLog(socketB);
      addTearDown(socketA.dispose);
      addTearDown(socketB.dispose);
      addTearDown(logA.cancel);
      addTearDown(logB.cancel);
      await Future.wait(<Future<void>>[socketA.connect(), socketB.connect()]);

      final List<String> texts = await Future.wait(<Future<String>>[
        chatRoundTrip(socketA, logA, workspace, 'message of the first client'),
        chatRoundTrip(socketB, logB, workspace, 'message of the second client'),
      ]);
      expect(texts[0], contains('message of the first client'));
      expect(texts[0], isNot(contains('second client')));
      expect(texts[1], contains('message of the second client'));
      expect(texts[1], isNot(contains('first client')));

      // Both links stay up and usable afterwards.
      final List<http.Response> health = await Future.wait(
        <Future<http.Response>>[
          for (final LiveThin thin in <LiveThin>[first, second])
            () async {
              final DataChannelHttpClient tunnel = DataChannelHttpClient(
                link: await thin.link(stack.engine.nodeId),
              );
              addTearDown(tunnel.close);
              return tunnel.get(Uri.parse('http://peer.invalid/api/v1/health'));
            }(),
        ],
      );
      expect(health.map((http.Response r) => r.statusCode), <int>[200, 200]);
    });

    liveTest('client.hello twice on one socket is acknowledged both times', (
      LiveStack stack,
    ) async {
      // Bug class: client-id collision: a second hello on the same session is
      // rejected as "Client_ID already in use".
      final LiveThin thin = await LiveThin.start(
        stack,
        stack.alice,
        deviceName: uniqueName('dart-hello'),
      );
      addTearDown(thin.dispose);
      final PeerEngineSocket socket = thin.socket(stack.engine.nodeId);
      final FrameLog log = FrameLog(socket);
      addTearDown(socket.dispose);
      addTearDown(log.cancel);
      await socket.connect();
      await log.waitFor('client.hello.ack');
      expect(log.of('client.hello.ack'), hasLength(1));

      socket.send(
        type: 'client.hello',
        data: const ClientIdentity(
          type: ClientType.browserExtension,
          name: 'live dart client',
        ).helloData(),
      );
      await log.waitFor('client.hello.ack', after: 1);
      expect(log.of('client.hello.reject'), isEmpty);
    });

    liveTest('ten rapid socket reconnect cycles all succeed', (
      LiveStack stack,
    ) async {
      // Bug class: a replaced/reconnected client is refused ("Client_ID already
      // in use" loop) or the engine keeps the stale registration.
      final LiveThin thin = await LiveThin.start(
        stack,
        stack.alice,
        deviceName: uniqueName('dart-cycles'),
      );
      addTearDown(thin.dispose);
      final PeerEngineSocket socket = thin.socket(stack.engine.nodeId);
      final FrameLog log = FrameLog(socket);
      addTearDown(socket.dispose);
      addTearDown(log.cancel);
      await socket.connect();
      for (int cycle = 1; cycle <= 10; cycle++) {
        await socket.close();
        await socket.connect().timeout(const Duration(seconds: 15));
        await log.waitFor('client.hello.ack', after: cycle);
        expect(log.of('client.hello.ack'), hasLength(cycle + 1));
      }
      expect(log.of('client.hello.reject'), isEmpty);
    });

    liveTest('a replaced relay link is accepted promptly, five times in a '
        'row', (LiveStack stack) async {
      // Bug class: after the link is torn down and re-established the engine
      // still holds the old session for this node and refuses or ignores the
      // new one.
      final String workspace = await createWorkspace(
        stack.engine,
        'Dart replace',
      );
      final LiveThin thin = await LiveThin.start(
        stack,
        stack.alice,
        deviceName: uniqueName('dart-replace'),
      );
      addTearDown(thin.dispose);
      for (int cycle = 1; cycle <= 5; cycle++) {
        await thin.hive.connector!.closePeer(stack.engine.nodeId);
        final PeerEngineSocket socket = thin.socket(stack.engine.nodeId);
        final FrameLog log = FrameLog(socket);
        addTearDown(socket.dispose);
        addTearDown(log.cancel);
        await socket.connect().timeout(const Duration(seconds: 20));
        expect(
          await chatRoundTrip(socket, log, workspace, 'cycle $cycle'),
          contains('cycle $cycle'),
        );
        await socket.close();
      }
    });

    liveTest("another account's client cannot link to this engine", (
      LiveStack stack,
    ) async {
      // Bug class: account isolation hole on the relay path: a stranger can
      // see, address or open a link to somebody else's engine.
      final LiveThin bob = await LiveThin.start(
        stack,
        stack.bob,
        deviceName: uniqueName('dart-bob'),
      );
      addTearDown(bob.dispose);
      expect(bob.who.userId, isNot(stack.alice.userId));
      expect(bob.hive.directory!.get(stack.engine.nodeId), isNull);
      await expectLater(
        bob.hive.connectTo(stack.engine.nodeId),
        throwsA(isA<PeerConnectException>()),
      );
      final PeerEngineSocket socket = bob.socket(stack.engine.nodeId);
      addTearDown(socket.dispose);
      await expectLater(
        socket.connect().timeout(const Duration(seconds: 20)),
        throwsA(anything),
      );
      // And the engine's device list never shows bob's node.
      expect(
        (await engineNodes(stack.engine)).containsKey(bob.nodeId),
        isFalse,
      );
    });
  });
}
