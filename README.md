# Subconscious Dart

Open-source Dart and Flutter workspace for desktop, mobile, web, and terminal clients.

## Workspace

- `apps/core_business_logic`: pure Dart models, API contracts, and repositories.
- `apps/shared_ui_kit`: Flutter design tokens, themes, and brand assets.
- `apps/unified_app`: adaptive Flutter app for Android, iOS, Linux, macOS, Web, and Windows.
- `apps/tui_app`: pure Dart terminal application built with `dart_tui`.

## Setup

Use Flutter 3.47.2 or newer with Dart 3.13.2 or newer.

```text
flutter pub get
flutter analyze
dart run apps/tui_app/bin/main.dart
flutter run -d <device> -t apps/unified_app/lib/main.dart
```

The repository contains no Visual Studio solution or MSBuild project. Flutter's official native Windows build pipeline still requires Microsoft's supported Windows compiler toolchain; use the Web target on Windows when a strictly open-source host toolchain is required.

## License

MIT. See `LICENSE`.
