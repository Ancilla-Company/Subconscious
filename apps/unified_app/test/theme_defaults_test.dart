import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/settings/controller/settings_controller.dart';

DashboardSettingsController _controller(Map<String, String> settings) {
  final controller = DashboardSettingsController(
    repositoryProvider: () => null,
  );
  controller.generalSettings = settings;
  return controller;
}

void main() {
  test('defaults to light mode and Default colour theme when unset', () {
    final c = _controller(const {});
    expect(c.lightingMode, AppLightingMode.light);
    expect(c.modeValue, 'Light');
    expect(c.accentTheme, AppAccentTheme.neutral);
    expect(c.colourThemeValue, 'Default');
  });

  test('unrecognised values fall back to the new defaults', () {
    final c = _controller(const {'mode': 'banana', 'colour_theme': 'banana'});
    expect(c.lightingMode, AppLightingMode.light);
    expect(c.accentTheme, AppAccentTheme.neutral);
  });

  test('saved preferences are preserved', () {
    expect(
      _controller(const {'mode': 'Dark'}).lightingMode,
      AppLightingMode.dark,
    );
    expect(
      _controller(const {'mode': 'Device'}).lightingMode,
      AppLightingMode.device,
    );
    expect(
      _controller(const {'mode': 'Light'}).lightingMode,
      AppLightingMode.light,
    );
    expect(
      _controller(const {'colour_theme': 'Purple'}).accentTheme,
      AppAccentTheme.purple,
    );
    expect(
      _controller(const {'colour_theme': 'Device'}).accentTheme,
      AppAccentTheme.device,
    );
    expect(
      _controller(const {'colour_theme': 'Blue'}).accentTheme,
      AppAccentTheme.blue,
    );
    expect(
      _controller(const {'colour_theme': 'Default'}).accentTheme,
      AppAccentTheme.neutral,
    );
  });

  test('parsing is case-insensitive', () {
    expect(
      _controller(const {'mode': 'DARK'}).lightingMode,
      AppLightingMode.dark,
    );
    expect(
      _controller(const {'mode': 'dEvIcE'}).lightingMode,
      AppLightingMode.device,
    );
  });
}
