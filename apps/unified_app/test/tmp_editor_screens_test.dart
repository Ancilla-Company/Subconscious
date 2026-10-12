// Throwaway: whole-editor behaviour and screenshots with fake file access.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/editor/controller/editor_document_store.dart';
import 'package:unified_app/features/editor/controller/editor_tab.dart';
import 'package:unified_app/features/editor/presentation/workspace_file_editor.dart';

import 'tmp_store_test.dart' show FakeDrafts, FakeGateway, makeStore, refs;

final String shotDir = '${Platform.environment['TEMP']}\\subc-shots';

Future<void> loadFonts() async {
  Future<void> register(String family, List<String> paths) async {
    final FontLoader loader = FontLoader(family);
    for (final String path in paths) {
      loader.addFont(Future<ByteData>.value(ByteData.sublistView(File(path).readAsBytesSync())));
    }
    await loader.load();
  }

  const String sdk = r'C:\Users\brian\flutter\3.41.4\bin\cache\artifacts\material_fonts';
  final String fluent = '${Platform.environment['LOCALAPPDATA']}\\Pub\\Cache\\hosted\\pub.dev\\fluentui_system_icons-1.1.273\\lib\\fonts';
  await register('Roboto', <String>[
    '$sdk\\Roboto-Regular.ttf',
    '$sdk\\Roboto-Bold.ttf',
    '$sdk\\Roboto-Italic.ttf',
    '$sdk\\Roboto-BoldItalic.ttf',
    '$sdk\\Roboto-Medium.ttf',
  ]);
  await register('MaterialIcons', <String>['$sdk\\MaterialIcons-Regular.otf']);
  await register('packages/fluentui_system_icons/FluentSystemIcons-Regular', <String>['$fluent\\FluentSystemIcons-Regular.ttf']);
  await register('packages/fluentui_system_icons/FluentSystemIcons-Filled', <String>['$fluent\\FluentSystemIcons-Filled.ttf']);
  await register('Consolas', <String>[
    r'C:\Windows\Fonts\consola.ttf',
    r'C:\Windows\Fonts\consolab.ttf',
    r'C:\Windows\Fonts\consolai.ttf',
    r'C:\Windows\Fonts\consolaz.ttf',
  ]);
}

const String markdownSample = '''# Project notes

A short intro with **bold**, _italic_, ~~struck~~ and `inline code`, plus a [link](https://example.com/docs).

## Todo

- [x] Write the editor
- [ ] Review the *draft*
- A plain bullet
  - nested bullet

1. First step
2. Second step

> A quoted remark that
> spans two lines.

| Name | Value |
|------|-------|
| one  | 1     |

```dart
void main() {
  print('hello');
}
```

---
Final paragraph with an ![image alt](x.png) and https://example.com/bare.
''';

const String pythonSample = '''import os

def greet(name):
\tprint(f"Hello, {name}")  # tab indented
\treturn len(name)

class Box:
    size = 3
''';

typedef Setup = ({EditorDocumentStore store, FakeGateway gateway, FakeDrafts drafts});

Future<Setup> setup(WidgetTester tester, {Map<String, String>? files, List<String>? tabs, String? active}) async {
  final FakeGateway g = FakeGateway();
  final FakeDrafts d = FakeDrafts();
  final Map<String, String> content = files ?? <String, String>{'notes.md': markdownSample, 'todo.txt': 'buy milk\nwrite tests\n', 'app.py': pythonSample};
  content.forEach((String path, String text) => g.put('w', 0, path, text));
  final EditorDocumentStore s = makeStore(g, d);
  await tester.runAsync(() => s.switchWorkspace('w', remembered: refs(tabs ?? content.keys.toList()), activeKey: '0:${active ?? (tabs ?? content.keys.toList()).first}'));
  addTearDown(s.dispose);
  return (store: s, gateway: g, drafts: d);
}

final GlobalKey boundaryKey = GlobalKey();

Widget app(Setup s, {Brightness brightness = Brightness.light, Listenable? refresh}) => RepaintBoundary(
  key: boundaryKey,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, brightness: brightness, colorSchemeSeed: const Color(0xFF0067C0), fontFamily: 'Roboto'),
    home: Scaffold(body: WorkspaceFileEditor.forStore(store: s.store, refresh: refresh)),
  ),
);

Future<void> shot(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final RenderRepaintBoundary boundary = boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage();
    final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(shotDir).createSync(recursive: true);
    File('$shotDir\\$name.png').writeAsBytesSync(data!.buffer.asUint8List());
  });
}

void uiTest(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (WidgetTester tester) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  // Tests draw elevation as a solid black outline unless this is off.
  debugDisableShadows = false;
  tester.view.physicalSize = const Size(1100, 760);
  tester.view.devicePixelRatio = 1.0;
  try {
    await body(tester);
  } finally {
    debugDefaultTargetPlatformOverride = null;
    debugDisableShadows = true;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
});

Future<void> ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

TextTab tab(Setup s, String path) => s.store.tabs.firstWhere((EditorTab t) => t.path == path) as TextTab;

Finder saveButton() => find.widgetWithText(FilledButton, 'Save');

bool saveEnabled(WidgetTester tester) => tester.widget<FilledButton>(saveButton()).onPressed != null;

void main() {
  setUpAll(() async {
    await loadFonts();
  });

  uiTest('screenshots: markdown light, split, dark, find', (WidgetTester tester) async {
    final Setup s = await setup(tester);
    await tester.pumpWidget(app(s));
    await tester.pump();
    s.store.edited(tab(s, 'notes.md'), '${markdownSample}\nAn unsaved line.', const TextSelection.collapsed(offset: 40));
    await tester.pump(const Duration(milliseconds: 50));
    await shot(tester, '1_markdown_light');

    await tester.tap(find.byTooltip('Edit and preview side by side'));
    await tester.pump(const Duration(milliseconds: 200));
    await shot(tester, '2_markdown_split');

    await tester.tap(find.byTooltip('Preview'));
    await tester.pump(const Duration(milliseconds: 200));
    await shot(tester, '3_markdown_preview');

    await tester.tap(find.byTooltip('Edit'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await ctrl(tester, LogicalKeyboardKey.keyF);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField).last, 'the');
    await tester.pump(const Duration(milliseconds: 100));
    await shot(tester, '4_markdown_find');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);

    await tester.pumpWidget(app(s, brightness: Brightness.dark));
    await tester.pumpAndSettle();
    await shot(tester, '5_markdown_dark');
    await tester.pump(const Duration(milliseconds: 700));
  });

  uiTest('screenshots: code and plain text', (WidgetTester tester) async {
    final Setup s = await setup(tester, active: 'app.py');
    await tester.pumpWidget(app(s));
    await tester.pump(const Duration(milliseconds: 100));
    final CodeField field = tester.widget<CodeField>(find.byType(CodeField));
    expect(field.controller.fullText, pythonSample, reason: 'tabs and everything else load untouched');
    expect(field.controller.fullText.contains('\t'), isTrue);
    await shot(tester, '6_code');
    await tester.tap(find.text('todo.txt'));
    await tester.pump(const Duration(milliseconds: 200));
    await shot(tester, '7_plain');
  });

  uiTest('save button, ctrl+s, close prompt', (WidgetTester tester) async {
    final Setup s = await setup(tester, active: 'todo.txt');
    await tester.pumpWidget(app(s));
    await tester.pump(const Duration(milliseconds: 100));
    expect(saveButton(), findsOneWidget);
    expect(saveEnabled(tester), isFalse, reason: 'nothing to save yet');
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'buy milk\nwrite tests\nand more\n');
    await tester.pump();
    expect(saveEnabled(tester), isTrue);

    await ctrl(tester, LogicalKeyboardKey.keyS);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(s.gateway.files['w|0:todo.txt']!.text, 'buy milk\nwrite tests\nand more\n');
    expect(saveEnabled(tester), isFalse);

    // close with unsaved changes: cancel, then don't save, then the tab goes
    await tester.enterText(find.byType(TextField), 'changed again');
    await tester.pump();
    await tester.tap(find.byTooltip('Close todo.txt'));
    await tester.pumpAndSettle();
    expect(find.text('Save changes to todo.txt?'), findsOneWidget);
    await shot(tester, '8_close_prompt');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(s.store.tabs.length, 3);
    await tester.tap(find.byTooltip('Close todo.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Don't save"));
    await tester.pumpAndSettle();
    expect(s.store.tabs.map((EditorTab t) => t.path), <String>['notes.md', 'app.py']);
    expect(s.gateway.files['w|0:todo.txt']!.text, 'buy milk\nwrite tests\nand more\n', reason: 'discarded edit never reached disk');
    await tester.pump(const Duration(milliseconds: 200));
    expect(s.drafts.of('w').containsKey('0:todo.txt'), isFalse);

    // closing with Save writes first
    await tester.tap(find.text('app.py'));
    await tester.pump(const Duration(milliseconds: 100));
    final CodeField code = tester.widget<CodeField>(find.byType(CodeField));
    code.controller.fullText = '${code.controller.fullText}# end\n';
    await tester.pump(const Duration(milliseconds: 100));
    expect(tab(s, 'app.py').isDirty, isTrue);
    await tester.tap(find.byTooltip('Close app.py'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(s.gateway.files['w|0:app.py']!.text, endsWith('# end\n'));
    expect(s.gateway.files['w|0:app.py']!.text, contains('\tprint'), reason: 'tabs survive the save');
    expect(s.store.tabs.map((EditorTab t) => t.path), <String>['notes.md']);
  });

  uiTest('conflict, deleted and recovered banners', (WidgetTester tester) async {
    final Setup s = await setup(tester, active: 'todo.txt');
    await tester.pumpWidget(app(s));
    await tester.pump(const Duration(milliseconds: 100));
    final TextTab t = tab(s, 'todo.txt');
    s.store.edited(t, 'my version\n', const TextSelection.collapsed(offset: 0));
    s.gateway.files['w|0:todo.txt']!
      ..text = 'their version\n'
      ..version = 'ext-1';
    await tester.runAsync(() => s.store.checkExternalChanges());
    await tester.pump();
    expect(find.textContaining('changed on disk while you were editing'), findsOneWidget);
    await shot(tester, '9_conflict');
    await tester.tap(find.text('Overwrite with mine'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(s.gateway.files['w|0:todo.txt']!.text, 'my version\n');
    expect(find.textContaining('changed on disk'), findsNothing);

    // deleted
    s.gateway.files.remove('w|0:todo.txt');
    await tester.runAsync(() => s.store.checkExternalChanges());
    await tester.pump();
    expect(find.textContaining('deleted or moved'), findsOneWidget);
    await tester.tap(find.text('Save to recreate'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(s.gateway.files['w|0:todo.txt']!.text, 'my version\n');
    expect(find.textContaining('deleted or moved'), findsNothing);

    // load from disk replaces the editor text
    s.store.edited(t, 'mine again\n', const TextSelection.collapsed(offset: 0));
    s.gateway.files['w|0:todo.txt']!
      ..text = 'external two\n'
      ..version = 'ext-2';
    await tester.runAsync(() => s.store.checkExternalChanges());
    await tester.pump();
    await tester.tap(find.text('Load from disk'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'external two\n');
    await tester.pump(const Duration(milliseconds: 700));
  });

  uiTest('recovered draft banner and save error banner', (WidgetTester tester) async {
    final FakeGateway g = FakeGateway();
    final FakeDrafts d = FakeDrafts();
    g.put('w', 0, 'a.txt', 'saved text');
    // a draft left by a previous run
    final EditorDocumentStore first = makeStore(g, d);
    await tester.runAsync(() async {
      await first.switchWorkspace('w', remembered: refs(<String>['a.txt']), activeKey: '0:a.txt');
      first.edited(first.tabs.single as TextTab, 'unsaved text', const TextSelection.collapsed(offset: 5));
      await first.flushDrafts();
    });
    first.dispose();
    final EditorDocumentStore second = makeStore(g, d);
    addTearDown(second.dispose);
    await tester.runAsync(() => second.switchWorkspace('w', remembered: refs(<String>['a.txt']), activeKey: '0:a.txt'));
    final Setup s = (store: second, gateway: g, drafts: d);
    final ValueNotifier<int> connection = ValueNotifier<int>(0);
    addTearDown(connection.dispose);
    await tester.pumpWidget(app(s, refresh: connection));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Restored your unsaved changes from last time.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'unsaved text');
    await shot(tester, '10_recovered');
    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(find.text('Restored your unsaved changes from last time.'), findsNothing);

    // a failing engine shows the reason and keeps the text
    expect(saveEnabled(tester), isTrue);
    g.available = false;
    connection.value++;
    await tester.pump();
    expect(saveEnabled(tester), isFalse, reason: 'save is off while disconnected');
    g.available = true;
    connection.value++;
    await tester.pump();
    expect(saveEnabled(tester), isTrue);
    await tester.pump(const Duration(milliseconds: 700));
  });
}
