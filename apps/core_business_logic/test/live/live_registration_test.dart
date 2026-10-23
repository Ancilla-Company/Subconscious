@Tags(<String>['live'])
library;

import 'package:core_business_logic/core_business_logic.dart';
import 'package:test/test.dart';

import 'live_hive.dart';
import 'live_stack.dart';

/// Live scenarios 1, 2 and 3 (presence) of
/// `.agents/tasks/live-tests/contracts.md`, driven by the real Dart
/// [HiveClient] against the real server and the real engine.
Future<void> main() async {
  final LiveStack? stack = await LiveStack.resolve();
  final String? skip = stack == null ? liveSkipReason : null;

  void liveTest(String name, Future<void> Function(LiveStack stack) body) {
    test(
      name,
      () => body(stack!),
      skip: skip,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  group('live: registration and presence', () {
    liveTest('a thin node registers with exactly the platform and name given, '
        'and deleting it removes a transient node', (LiveStack stack) async {
      // Bug class: the client registers a different platform/name than the app
      // asked for (so the device list mislabels the extension as "web" or a
      // phone), or removing a browser/web device only revokes it and leaves a
      // ghost row behind.
      final LiveAccount alice = stack.alice;

      // Sign in the way an installed client restarts: a refresh token in the
      // store. (A fresh token from a password login: the seeded one is single
      // use and stays untouched for other attachers.)
      final MemoryRefreshTokenStore store = MemoryRefreshTokenStore();
      final ServerAccountClient first = await signIn(
        stack,
        alice,
        tokenStore: store,
      );
      final String? refresh = await store.read();
      expect(refresh, isNotNull, reason: 'login stores a refresh token');
      await first.close();

      final MemoryRefreshTokenStore restoredStore = MemoryRefreshTokenStore();
      await restoredStore.write(refresh!);
      final ServerAccountClient restored = ServerAccountClient(
        baseUri: stack.serverUri,
        tokenStore: restoredStore,
      );
      addTearDown(restored.close);
      expect(await restored.restore(), isTrue, reason: 'refresh-token sign-in');
      expect(restored.user?.email, alice.email);

      final String browserName = uniqueName('Browser extension (Chrome)');
      final String webName = uniqueName('Subconscious (web)');
      final HiveClient browser = newHiveClient(
        restored,
        deviceName: browserName,
        platform: 'browser',
      );
      final HiveClient web = newHiveClient(
        restored,
        deviceName: webName,
        platform: 'web',
      );
      addTearDown(browser.dispose);
      addTearDown(web.dispose);
      await browser.start();
      await web.start();

      final String? token = restored.accessToken;
      expect(token, isNotNull);
      final Map<String, Map<String, dynamic>> listed = await serverNodes(
        stack,
        token!,
      );
      final Map<String, dynamic>? browserNode =
          listed[browser.identity!.nodeId];
      final Map<String, dynamic>? webNode = listed[web.identity!.nodeId];
      expect(browserNode, isNotNull);
      expect(webNode, isNotNull);
      expect(
        <Object?>[
          browserNode!['kind'],
          browserNode['platform'],
          browserNode['name'],
        ],
        <Object?>['thin', 'browser', browserName],
      );
      expect(
        <Object?>[webNode!['kind'], webNode['platform'], webNode['name']],
        <Object?>['thin', 'web', webName],
      );

      // DELETE /nodes/{id} (HiveApi.revoke) removes a transient node outright.
      for (final HiveClient client in <HiveClient>[browser, web]) {
        await client.api!.revoke(client.identity!.nodeId);
      }
      final Map<String, Map<String, dynamic>> after = await serverNodes(
        stack,
        token,
      );
      expect(after.containsKey(browser.identity!.nodeId), isFalse);
      expect(after.containsKey(web.identity!.nodeId), isFalse);
    });

    liveTest('two clients with different identity seeds both come online and '
        'the engine lists them', (LiveStack stack) async {
      // Bug class: client-id / identity collision: the second extension page
      // (slot 1) reuses slot 0's identity, so the server and engine see one
      // device (or reject the second), and one page's presence hides the other.
      final LiveThin slot0 = await LiveThin.start(
        stack,
        stack.alice,
        deviceName: 'Browser extension (Chrome)',
        seedStore: MemoryIdentitySeedStore(),
      );
      addTearDown(slot0.dispose);
      final LiveThin slot1 = await LiveThin.start(
        stack,
        stack.alice,
        deviceName: 'Browser extension (Chrome) #2',
        seedStore: MemoryIdentitySeedStore(),
      );
      addTearDown(slot1.dispose);
      expect(slot0.nodeId, isNot(slot1.nodeId));

      for (final LiveThin thin in <LiveThin>[slot0, slot1]) {
        final Map<String, dynamic> node = await serverNodeIs(
          stack,
          thin.account.accessToken!,
          thin.nodeId,
          (Map<String, dynamic>? n) => n != null && n['online'] == true,
          what: 'the server to show ${thin.nodeId} online',
        );
        expect(node['platform'], 'browser');
        await engineNodeIs(
          stack.engine,
          thin.nodeId,
          (Map<String, dynamic>? n) => n != null && n['online'] == true,
          what: 'the engine device list to show ${thin.nodeId} online',
        );
      }
      final Map<String, Map<String, dynamic>> names = await serverNodes(
        stack,
        slot0.account.accessToken!,
      );
      expect(names[slot0.nodeId]!['name'], 'Browser extension (Chrome)');
      expect(names[slot1.nodeId]!['name'], 'Browser extension (Chrome) #2');
    });

    liveTest('closing the hive client makes its node go offline', (
      LiveStack stack,
    ) async {
      // Bug class: presence sticks: a closed page/extension stays "online"
      // forever (or a connected one never shows online).
      final LiveThin thin = await LiveThin.start(
        stack,
        stack.alice,
        deviceName: uniqueName('presence'),
      );
      addTearDown(thin.dispose);
      final String token = thin.account.accessToken!;
      await serverNodeIs(
        stack,
        token,
        thin.nodeId,
        (Map<String, dynamic>? n) => n != null && n['online'] == true,
        what: 'the node online while its socket is open',
      );

      await thin.hive.dispose();
      // presence_offline_grace_seconds is 1 in the live settings. A transient
      // node may also be cleaned up entirely a little later, which is "not
      // online" as well.
      await serverNodeIs(
        stack,
        token,
        thin.nodeId,
        (Map<String, dynamic>? n) => n == null || n['online'] != true,
        what: 'the node offline after the hive client closed',
        timeout: const Duration(seconds: 12),
      );
      await engineNodeIs(
        stack.engine,
        thin.nodeId,
        (Map<String, dynamic>? n) => n == null || n['online'] != true,
        what: 'the engine device list to follow',
      );
    });
  });
}
