import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Static guard: forms are built from the shared_ui_kit form widgets
/// (`AppTextField`, `AppDropdown`, `AppSwitchTile`, `AppFormError`, ...), never
/// from raw Material inputs styled locally. This is what keeps every field and
/// button identical on mobile, web and desktop.
///
/// A file may only use a raw input if it is listed here with the reason. Do
/// not add a form to this list: add the missing variant to
/// apps/shared_ui_kit/lib/src/forms instead.
const Map<String, String> _bespokeInputs = <String, String>{
  'features/chat/presentation/engine_chat_panel.dart':
      'the chat composer is a bespoke chat control, not a form field',
  'features/editor/presentation/find_bar.dart':
      'editor find/replace bar, an editor control',
  'features/editor/presentation/source_editor.dart':
      'the document editor surface',
};

final RegExp _rawInput = RegExp(
  r'\b(TextField|TextFormField|DropdownButtonFormField|DropdownButton|SwitchListTile)\s*[<(]|\bInputDecoration\s*\(',
);

void main() {
  test('feature code uses the shared form widgets, not raw inputs', () {
    final Directory lib = Directory('lib');
    final List<String> problems = <String>[];
    for (final FileSystemEntity entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String relative = entity.path
          .replaceAll(r'\', '/')
          .replaceFirst('lib/', '');
      if (_bespokeInputs.containsKey(relative)) continue;
      final List<String> lines = entity.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i].trimLeft();
        if (line.startsWith('//')) continue;
        if (_rawInput.hasMatch(line)) {
          problems.add('$relative:${i + 1}: ${line.trim()}');
        }
      }
    }
    expect(
      problems,
      isEmpty,
      reason:
          'Use AppTextField / AppDropdown / AppSwitchTile from '
          'package:shared_ui_kit/shared_ui_kit.dart instead of raw inputs.\n'
          '${problems.join('\n')}',
    );
  });

  test('every allowlisted file still exists and still needs its exception', () {
    for (final String relative in _bespokeInputs.keys) {
      final File file = File('lib/$relative');
      expect(file.existsSync(), isTrue, reason: '$relative was removed');
      expect(
        _rawInput.hasMatch(file.readAsStringSync()),
        isTrue,
        reason: '$relative no longer uses a raw input; remove it from the list',
      );
    }
  });

  group('feature code uses kit widgets, not raw Material surfaces', () {
    for (final _Ban ban in _bans) {
      test('${ban.name}: no new use outside the allowlist', () {
        final List<String> problems = <String>[];
        for (final (String relative, List<String> lines) in _featureFiles()) {
          if (ban.allowed.containsKey(relative)) continue;
          for (int i = 0; i < lines.length; i++) {
            final String line = lines[i].trimLeft();
            if (line.startsWith('//')) continue;
            if (ban.pattern.hasMatch(line)) {
              problems.add('$relative:${i + 1}: ${line.trim()}');
            }
          }
        }
        expect(problems, isEmpty, reason: '${ban.fix}\n${problems.join('\n')}');
      });

      test('${ban.name}: every allowlisted file still needs its exception', () {
        for (final MapEntry<String, String> entry in ban.allowed.entries) {
          final File file = File('lib/${entry.key}');
          expect(file.existsSync(), isTrue, reason: '${entry.key} was removed');
          final bool stillUses = file
              .readAsLinesSync()
              .where((String line) => !line.trimLeft().startsWith('//'))
              .any(ban.pattern.hasMatch);
          expect(
            stillUses,
            isTrue,
            reason:
                '${entry.key} no longer uses ${ban.name}; remove it from the '
                'allowlist so it stays migrated',
          );
        }
      });
    }
  });
}

/// Every Dart file under `lib/` as (path relative to lib, lines).
Iterable<(String, List<String>)> _featureFiles() sync* {
  for (final FileSystemEntity entity in Directory(
    'lib',
  ).listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    yield (
      entity.path.replaceAll(r'\', '/').replaceFirst('lib/', ''),
      entity.readAsLinesSync(),
    );
  }
}

/// A Material construct that feature code must replace with its kit widget.
///
/// [allowed] is a ratchet: it lists the files that have NOT been migrated yet.
/// Never add a file to it. Migrate the file to the kit (or add the missing
/// variant to apps/shared_ui_kit) and delete its entry; the second test per
/// ban fails once an entry is no longer needed.
final class _Ban {
  const _Ban(this.name, this.pattern, this.fix, this.allowed);

  final String name;
  final RegExp pattern;
  final String fix;
  final Map<String, String> allowed;
}

final List<_Ban> _bans = <_Ban>[
  _Ban(
    'ListTile',
    RegExp(r'(?<![A-Za-z])ListTile\s*[(<]|(?<![A-Za-z])ListTile\.'),
    'Use AppListRow (or AppSwitchTile) from shared_ui_kit.',
    const <String, String>{},
  ),
  _Ban(
    'Card',
    RegExp(r'(?<![A-Za-z])Card\s*\('),
    'Use AppCard / AppSectionCard from shared_ui_kit.',
    const <String, String>{},
  ),
  _Ban(
    'ExpansionTile',
    RegExp(r'\bExpansionTile\s*\('),
    'Use AppSectionCard(expandable: true) from shared_ui_kit.',
    const <String, String>{},
  ),
  _Ban(
    'AlertDialog',
    RegExp(r'\bAlertDialog\s*\('),
    'Use AppDialog with showAppDialog from shared_ui_kit.',
    const <String, String>{},
  ),
  _Ban(
    'showDialog',
    RegExp(r'\bshowDialog\s*[<(]'),
    'Use showAppDialog from shared_ui_kit.',
    const <String, String>{},
  ),
  _Ban(
    'showModalBottomSheet',
    RegExp(r'\bshowModalBottomSheet\s*[<(]'),
    'Use showAppBottomSheet from shared_ui_kit.',
    const <String, String>{},
  ),
  _Ban(
    'PopupMenuButton',
    RegExp(r'\bPopupMenuButton\s*[<(]'),
    'Use AppPopupMenu from shared_ui_kit.',
    const <String, String>{},
  ),
  _Ban(
    'MenuAnchor',
    RegExp(r'\bMenuAnchor\s*\('),
    'Use AppPopupMenu from shared_ui_kit.',
    const <String, String>{},
  ),
  _Ban(
    'SnackBar',
    RegExp(r'(?<![A-Za-z])SnackBar\s*\(|\.showSnackBar\s*\('),
    'Use showAppSnack from shared_ui_kit.',
    const <String, String>{},
  ),
  _Ban(
    'Chip',
    RegExp(r'(?<![A-Za-z])(?:Action|Choice|Filter|Input)?Chip\s*\('),
    'Use AppBadge (or AppSegmentedControl) from shared_ui_kit.',
    const <String, String>{},
  ),
  _Ban(
    'SegmentedButton',
    RegExp(r'\bSegmentedButton\s*[<(]'),
    'Use AppSegmentedControl from shared_ui_kit.',
    const <String, String>{},
  ),
  _Ban(
    'ElevatedButton',
    RegExp(r'\bElevatedButton(?:\.\w+)?\s*[<(]'),
    'Use FilledButton / OutlinedButton / TextButton (themed by appFormTheme).',
    const <String, String>{},
  ),
  _Ban(
    'hard-coded status colour',
    RegExp(r'\bColors\.(?:green|red|amber|orange)(?:Accent)?\b'),
    'Use AppStatusDot / AppColors.status* / AppColors.highlight* or a '
        'ColorScheme role.',
    const <String, String>{},
  ),
  _Ban(
    'local ThemeData(...)',
    RegExp(r'\bThemeData\s*\('),
    'Extend appFormTheme in shared_ui_kit instead of building a theme locally.',
    const <String, String>{},
  ),
  _Ban(
    'IconButton',
    RegExp(r'(?<![A-Za-z])IconButton\s*\(|\bIconButton\.styleFrom\b'),
    'Use AppIconButton (or SidebarButton) from shared_ui_kit.',
    const <String, String>{},
  ),
  _Ban(
    'BorderRadius.circular',
    RegExp(r'\bBorderRadius\.circular\s*\('),
    'Use AppRadii.xs / sm / md / lg (or AppRadii.surfaceFor) from shared_ui_kit.',
    const <String, String>{},
  ),
];
