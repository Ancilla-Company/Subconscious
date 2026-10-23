@Tags(<String>['live'])
library;

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/app_client.dart';
import 'package:unified_app/features/extension/extension_host.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';

import '../extension/fake_extension_host.dart';
import 'live_runtime_support.dart';

/// Live scenarios 1 and 3 (identity, presence) as the APP sees them: a real
/// [HiveRuntime] + [HiveClient] (relay only, no WebRTC in the test VM) against
/// the real server and the real engine of the stack.
///
/// Plain `test()`s on purpose (no TestWidgetsFlutterBinding), so real
/// `dart:io` HTTP and WebSocket work.
Future<void> main() async {
  final LiveStack? stack = await LiveStack.resolve();
  final String? skip = stack == null ? liveSkipReason : null;

  const String forcedClient = String.fromEnvironment('SUBCONSCIOUS_CLIENT');

  void liveTest(
    String name,
    Future<void> Function(LiveStack stack) body, {
    String? onlyWithoutForcedClient,
  }) {
    test(
      name,
      () async {
        FlutterSecureStorage.setMockInitialValues(<String, String>{});
        await body(stack!);
      },
      skip:
          skip ??
          (onlyWithoutForcedClient != null && forcedClient.isNotEmpty
              ? onlyWithoutForcedClient
              : null),
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  group('live: HiveRuntime registration and device list', () {
    liveTest(
      'the extension registers platform browser and its device name; '
      'a second page (slot 1) gets "#2" and its own identity',
      (LiveStack stack) async {
        // Bug class: the extension is registered as "web" or under a generic
        // name, or its second page reuses slot 0's identity (client-id
        // collision: one device row for two pages, or the engine rejecting the
        // second). Also: a closed transient device must vanish from the list.
        final FakeExtensionHost host = FakeExtensionHost(isExtension: true);
        useExtensionHost(host);
        expect(AppClient.kind, AppClientKind.browserExtension);
        expect(AppClient.platform, 'browser');
        const FlutterSecureStorage storage = FlutterSecureStorage();

        host
          ..instanceSlot = 0
          ..deviceName = 'Browser extension (Chrome)';
        final HiveRuntime first = await startRuntime(
          stack,
          stack.alice,
          storage: storage,
          slot: host.instanceSlot,
          deviceName: ExtensionHost.instance.deviceName,
          platform: AppClient.platform,
        );
        expect(first.deviceName, 'Browser extension (Chrome)');

        host
          ..instanceSlot = 1
          ..deviceName = 'Browser extension (Chrome) #2';
        final HiveRuntime second = await startRuntime(
          stack,
          stack.alice,
          storage: storage,
          slot: host.instanceSlot,
          deviceName: ExtensionHost.instance.deviceName,
          platform: AppClient.platform,
        );
        expect(second.deviceName, 'Browser extension (Chrome) #2');

        final String firstId = first.hive.identity!.nodeId;
        final String secondId = second.hive.identity!.nodeId;
        expect(firstId, isNot(secondId), reason: 'one identity per slot');
        expect(
          await storage.read(key: 'subconscious.node.identity.v1'),
          isNotNull,
        );
        expect(
          await storage.read(key: 'subconscious.node.identity.v1.slot1'),
          isNotNull,
        );

        final String token = first.account.accessToken!;
        final Map<String, Map<String, dynamic>> listed = await serverNodes(
          stack,
          token,
        );
        expect(
          <Object?>[listed[firstId]!['platform'], listed[firstId]!['name']],
          <Object?>['browser', 'Browser extension (Chrome)'],
        );
        expect(
          <Object?>[listed[secondId]!['platform'], listed[secondId]!['name']],
          <Object?>['browser', 'Browser extension (Chrome) #2'],
        );
        await serverNodeIs(
          stack,
          token,
          firstId,
          (Map<String, dynamic>? n) => n != null && n['online'] == true,
          what: 'page 1 online on the server',
        );
        await engineNodeIs(
          stack.engine,
          secondId,
          (Map<String, dynamic>? n) => n != null && n['online'] == true,
          what: 'page 2 online in the engine device list',
        );

        // The runtime's own device list shows the other page online and keeps it
        // visible; once that page closes it is hidden (transient platform).
        final NodeView online = await viewIs(
          second,
          firstId,
          (NodeView? v) => v != null && v.online,
          what: 'page 2 sees page 1 online',
        );
        expect(second.isShownDevice(online), isTrue);
        await first.hive.stop();
        final NodeView gone = await viewIs(
          second,
          firstId,
          (NodeView? v) => v != null && !v.online,
          what: 'page 2 sees page 1 go offline',
          timeout: const Duration(seconds: 15),
        );
        expect(
          second.isShownDevice(gone),
          isFalse,
          reason: 'an offline browser device disappears from the list',
        );
        // This device itself always stays.
        expect(second.isShownDevice(viewOf(second, secondId)!), isTrue);
      },
      onlyWithoutForcedClient:
          'needs the default client detection (no SUBCONSCIOUS_CLIENT define)',
    );

    liveTest('a web page registers platform web as "Subconscious (web)" and '
        'is hidden once offline', (LiveStack stack) async {
      // Bug class: the web page registers as a native device (a PC row that
      // never goes away) or without its name; an offline web page stays in
      // the list as a ghost.
      //
      // kIsWeb cannot be faked in the VM, so unless this run was started with
      // --dart-define=SUBCONSCIOUS_CLIENT=web the registration values are the
      // ones HiveRuntime uses in its web branch (platform web, name
      // "Subconscious (web)"), passed through the same HiveClient arguments.
      // Run with the define to also check AppClient and the runtime's own
      // device name.
      final FakeExtensionHost pageHost = FakeExtensionHost(isExtension: false);
      useExtensionHost(pageHost);
      final bool realWeb = AppClient.kind == AppClientKind.web;
      final String platform = realWeb ? AppClient.platform : 'web';
      expect(platform, 'web');
      const FlutterSecureStorage storage = FlutterSecureStorage();

      final HiveRuntime page = await startRuntime(
        stack,
        stack.alice,
        storage: storage,
        slot: pageHost.instanceSlot,
        deviceName: 'Subconscious (web)',
        platform: platform,
      );
      if (realWeb) expect(page.deviceName, 'Subconscious (web)');
      final String pageId = page.hive.identity!.nodeId;
      final Map<String, dynamic>? node = (await serverNodes(
        stack,
        page.account.accessToken!,
      ))[pageId];
      expect(
        <Object?>[node!['kind'], node['platform'], node['name']],
        <Object?>['thin', 'web', 'Subconscious (web)'],
      );

      // Observed from another device (a PC-like observer, slot 1).
      final HiveRuntime observer = await startRuntime(
        stack,
        stack.alice,
        storage: storage,
        slot: 1,
        deviceName: uniqueName('observer'),
        platform: 'browser',
      );
      final NodeView online = await viewIs(
        observer,
        pageId,
        (NodeView? v) => v != null && v.online,
        what: 'the observer sees the web page online',
      );
      expect(observer.isShownDevice(online), isTrue);
      await page.hive.stop();
      final NodeView gone = await viewIs(
        observer,
        pageId,
        (NodeView? v) => v != null && !v.online,
        what: 'the observer sees the web page go offline',
        timeout: const Duration(seconds: 15),
      );
      expect(observer.isShownDevice(gone), isFalse);
    });
  });
}
