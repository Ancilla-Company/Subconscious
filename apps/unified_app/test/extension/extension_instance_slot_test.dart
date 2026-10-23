import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/extension/extension_host.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';
import 'package:unified_app/features/hive/secure_storage_stores.dart';

import 'fake_extension_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('hive identity per extension page', () {
    late FlutterSecureStorage storage;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      storage = const FlutterSecureStorage();
    });

    test('slot 0 keeps the original key, other slots are separate', () async {
      await SecureIdentitySeedStore(storage).write('seed-zero');
      await SecureIdentitySeedStore(storage, 1).write('seed-one');
      await SecureIdentitySeedStore(storage, 2).write('seed-two');

      expect(await SecureIdentitySeedStore(storage).read(), 'seed-zero');
      expect(await SecureIdentitySeedStore(storage, 1).read(), 'seed-one');
      expect(await SecureIdentitySeedStore(storage, 2).read(), 'seed-two');
      expect(
        await storage.read(key: 'subconscious.node.identity.v1'),
        'seed-zero',
        reason: 'existing installs keep their identity',
      );
    });

    test('deleting one slot leaves the others', () async {
      await SecureIdentitySeedStore(storage).write('a');
      await SecureIdentitySeedStore(storage, 1).write('b');
      await SecureIdentitySeedStore(storage, 1).delete();
      expect(await SecureIdentitySeedStore(storage).read(), 'a');
      expect(await SecureIdentitySeedStore(storage, 1).read(), isNull);
    });
  });

  group('the extension registers as a browser, not as the web app', () {
    late ExtensionHost original;
    setUp(() => original = ExtensionHost.instance);
    tearDown(() => ExtensionHost.instance = original);

    test('the device name comes from the host', () {
      ExtensionHost.instance = FakeExtensionHost()
        ..deviceName = 'Browser extension (Edge) #2';
      final HiveRuntime runtime = HiveRuntime();
      addTearDown(runtime.dispose);
      expect(runtime.deviceName, 'Browser extension (Edge) #2');
      expect(runtime.deviceName, isNot(contains('web')));
    });
  });
}
