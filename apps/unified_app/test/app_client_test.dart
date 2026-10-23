import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/app_client.dart';
import 'package:unified_app/features/extension/extension_host.dart';

import 'extension/fake_extension_host.dart';

void main() {
  late ExtensionHost original;
  setUp(() => original = ExtensionHost.instance);
  tearDown(() => ExtensionHost.instance = original);

  test('the extension knows it is a browser extension at start', () {
    ExtensionHost.instance = FakeExtensionHost();
    expect(AppClient.kind, AppClientKind.browserExtension);
    expect(AppClient.platform, 'browser');
    expect(AppClient.isTransient, isTrue);
  });

  test('a plain page is not the extension', () {
    ExtensionHost.instance = FakeExtensionHost(isExtension: false);
    // The test VM is neither web nor an extension: a native client.
    expect(AppClient.kind, AppClientKind.native);
    expect(AppClient.isTransient, isFalse);
    expect(AppClient.platform, isNot('web'));
    expect(AppClient.platform, isNot('browser'));
  });

  test('web and browser platforms are transient, devices are not', () {
    for (final String platform in <String>['web', 'browser', ' Browser ']) {
      expect(AppClient.isTransientPlatform(platform), isTrue, reason: platform);
    }
    for (final String platform in <String>['android', 'windows', 'macOS', '']) {
      expect(
        AppClient.isTransientPlatform(platform),
        isFalse,
        reason: platform,
      );
    }
  });
}
