// Helpers shared by the unified_app live tests.
//
// The stack helpers are imported from core_business_logic's live folder by
// relative path: a package-crossing import of a test file is fine for the
// Dart/Flutter toolchains (only `lib` files are barred from it), and it keeps
// ONE implementation of the stack resolver. That file uses only `dart:*` and
// `package:http`, both available here.
import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/app_client.dart';
import 'package:unified_app/features/extension/extension_host.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';
import 'package:unified_app/features/hive/secure_storage_stores.dart';

import '../../../core_business_logic/test/live/live_hive.dart';
import '../../../core_business_logic/test/live/live_stack.dart';
import '../extension/fake_extension_host.dart';

export '../../../core_business_logic/test/live/live_hive.dart';
export '../../../core_business_logic/test/live/live_stack.dart';

/// Installs [host] as the process-wide extension host for one test and
/// restores the previous one afterwards.
void useExtensionHost(FakeExtensionHost host) {
  final ExtensionHost previous = ExtensionHost.instance;
  ExtensionHost.instance = host;
  addTearDown(() => ExtensionHost.instance = previous);
}

/// A real [HiveRuntime] (relay-only [HiveClient]) signed in to the real
/// server, built the way `HiveRuntime` builds its own client: identity seed
/// in a [SecureIdentitySeedStore] slot of the shared secure storage, device
/// name and platform from [AppClient] / the extension host.
///
/// [platform] and [deviceName] default to what the app itself would register
/// in the current [AppClient] mode.
Future<HiveRuntime> startRuntime(
  LiveStack stack,
  LiveAccount who, {
  required FlutterSecureStorage storage,
  required int slot,
  required String deviceName,
  required String platform,
}) async {
  final ServerAccountClient account = ServerAccountClient(
    baseUri: stack.serverUri,
    tokenStore: SecureRefreshTokenStore(storage),
  );
  final HiveClient hive = newHiveClient(
    account,
    seedStore: SecureIdentitySeedStore(storage, slot),
    deviceName: deviceName,
    platform: platform,
  );
  final HiveRuntime runtime = HiveRuntime(
    account: account,
    hive: hive,
    storage: storage,
    engineOfflineGrace: const Duration(seconds: 1),
  );
  addTearDown(() async {
    runtime.dispose();
    await hive.dispose();
    await account.close();
  });
  await runtime.signIn(email: who.email, password: who.password);
  expect(
    runtime.status,
    HiveStatus.ready,
    reason: 'the runtime signed in and started its hive: ${runtime.error}',
  );
  return runtime;
}

/// The device row for [nodeId] in [runtime]'s list, or null.
NodeView? viewOf(HiveRuntime runtime, String nodeId) {
  for (final NodeView view in runtime.nodes) {
    if (nodeIdsEqual(view.node.id, nodeId)) return view;
  }
  return null;
}

/// Waits until [runtime]'s device list holds [nodeId] and [accept] holds.
Future<NodeView> viewIs(
  HiveRuntime runtime,
  String nodeId,
  bool Function(NodeView? view) accept, {
  required String what,
  Duration timeout = const Duration(seconds: 20),
}) => eventually<NodeView>(
  () async {
    final NodeView? view = viewOf(runtime, nodeId);
    return view != null && accept(view) ? view : null;
  },
  what: what,
  timeout: timeout,
);
