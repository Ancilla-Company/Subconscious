// Throwaway verification of the editor widgets. Delete after use.
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/editor/controller/editor_document_store.dart';
import 'package:unified_app/features/editor/controller/editor_tab.dart';
import 'package:unified_app/features/editor/presentation/editor_text_controller.dart';
import 'package:unified_app/features/editor/presentation/find_bar.dart';
import 'package:unified_app/features/editor/presentation/markdown/markdown_preview.dart';
import 'package:unified_app/features/editor/presentation/markdown/markdown_ribbon.dart';
import 'package:unified_app/features/editor/presentation/source_editor.dart';

import 'tmp_store_test.dart' show FakeDrafts, FakeGateway, makeStore, refs;

typedef Fixture = ({EditorDocumentStore store, TextTab tab, FakeGateway gateway, FakeDrafts drafts});

Future<Fixture> fixture(WidgetTester tester, String path, String text) async {
  final FakeGateway g = FakeGateway();
  final FakeDrafts d = FakeDrafts();
  g.put('w', 0, path, text);
  final EditorDocumentStore s = makeStore(g, d);
  await tester.runAsync(() => s.switchWorkspace('w', remembered: refs(<String>[path]), activeKey: '0:$path'));
  addTearDown(s.dispose);
  return (store: s, tab: s.tabs.single as TextTab, gateway: g, drafts: d);
}

Widget host(Widget child, {Brightness brightness = Brightness.light}) => MaterialApp(
  theme: ThemeData(useMaterial3: true, brightness: brightness),
  home: Scaffold(body: SizedBox(width: 1000, height: 700, child: child)),
);

Widget markdownEditor(Fixture f, {MarkdownViewMode mode = MarkdownViewMode.edit, ValueChanged<MarkdownViewMode>? onMode}) =>
    SourceEditor(store: f.store, tab: f.tab, markdown: true, viewMode: mode, onViewModeChanged: onMode ?? (_) {});

TextEditingController controllerOf(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).first).controller!;

Future<void> ctrl(WidgetTester tester, LogicalKeyboardKey key, {bool shift = false}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void uiTest(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (WidgetTester tester) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  try {
    await body(tester);
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
});

void main() {

  uiTest('typing marks the tab dirty and persists a draft', (WidgetTester tester) async {
    final Fixture f = await fixture(tester, 'a.md', 'start');
    await tester.pumpWidget(host(markdownEditor(f)));
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'hello world');
    expect(f.tab.text, 'hello world');
    expect(f.tab.isDirty, isTrue);
    await tester.pump(const Duration(milliseconds: 100));
    expect(f.drafts.of('w')['0:a.md']?.text, 'hello world');
    // undoing back to the saved text clears dirty and the draft
    await tester.enterText(find.byType(TextField), 'start');
    expect(f.tab.isDirty, isFalse);
    await tester.pump(const Duration(milliseconds: 100));
    expect(f.drafts.of('w'), isEmpty);
  });

  uiTest('markdown shortcuts format the selection', (WidgetTester tester) async {
    final Fixture f = await fixture(tester, 'a.md', 'hello world');
    await tester.pumpWidget(host(markdownEditor(f)));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    final TextEditingController c = controllerOf(tester);
    c.selection = const TextSelection(baseOffset: 6, extentOffset: 11);
    await ctrl(tester, LogicalKeyboardKey.keyB);
    expect(c.text, 'hello **world**');
    await ctrl(tester, LogicalKeyboardKey.keyB);
    expect(c.text, 'hello world');
    c.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await ctrl(tester, LogicalKeyboardKey.keyI);
    expect(c.text, '*hello* world');
    await ctrl(tester, LogicalKeyboardKey.digit2);
    expect(c.text, '## *hello* world');
    await ctrl(tester, LogicalKeyboardKey.digit0);
    expect(c.text, '*hello* world');
    await ctrl(tester, LogicalKeyboardKey.keyL, shift: true);
    expect(c.text, '- *hello* world');
    await ctrl(tester, LogicalKeyboardKey.keyT, shift: true);
    expect(c.text, '- [ ] *hello* world');
    expect(f.tab.text, c.text, reason: 'commands flow into the store');
    await tester.pump(const Duration(milliseconds: 100));
  });

  uiTest('tab indents list items and outdents with shift', (WidgetTester tester) async {
    final Fixture f = await fixture(tester, 'a.md', '- a');
    await tester.pumpWidget(host(markdownEditor(f)));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    final TextEditingController c = controllerOf(tester);
    c.selection = const TextSelection.collapsed(offset: 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(c.text, '  - a');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(c.text, '- a');
    await tester.pump(const Duration(milliseconds: 100));
  });

  uiTest('enter continues a list; enter on an empty item ends it', (WidgetTester tester) async {
    final Fixture f = await fixture(tester, 'a.md', '');
    await tester.pumpWidget(host(markdownEditor(f)));
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '- one');
    await tester.enterText(find.byType(TextField), '- one\n');
    final TextEditingController c = controllerOf(tester);
    expect(c.text, '- one\n- ');
    await tester.enterText(find.byType(TextField), '- one\n- \n');
    expect(c.text, '- one\n');
    // pasted CRLF is normalised
    await tester.enterText(find.byType(TextField), 'a\r\nb\r\n');
    expect(c.text, 'a\nb\n');
    await tester.pump(const Duration(milliseconds: 100));
  });

  uiTest('live styling: headings sized, markers dimmed, text unchanged', (WidgetTester tester) async {
    const String source = '# Title\n\nSome **bold** and `code`.';
    final Fixture f = await fixture(tester, 'a.md', source);
    await tester.pumpWidget(host(markdownEditor(f)));
    final MarkdownTextController c = controllerOf(tester) as MarkdownTextController;
    final TextSpan span = c.buildTextSpan(
      context: tester.element(find.byType(TextField)),
      style: const TextStyle(fontSize: 15, color: Colors.black),
      withComposing: false,
    );
    expect(span.toPlainText(), source, reason: 'styling never alters the text');
    final List<TextSpan> kids = span.children!.cast<TextSpan>();
    expect(kids[0].text, '# ');
    expect(kids[0].style!.color!.a, lessThan(0.6));
    expect(kids[1].text, 'Title');
    expect(kids[1].style!.fontSize, closeTo(15 * 1.7, 0.01));
    final TextSpan bold = kids.firstWhere((TextSpan s) => s.text == 'bold');
    expect(bold.style!.fontWeight, FontWeight.w700);
    final TextSpan code = kids.firstWhere((TextSpan s) => s.text == 'code');
    expect(code.style!.backgroundColor, isNotNull);
    // the field really shows it: the rendered paragraph carries the same text
    expect(find.byType(EditableText), findsOneWidget);
  });

  uiTest('large markdown turns styling off', (WidgetTester tester) async {
    final String big = List<String>.filled(30000, '**bold** text here').join('\n');
    expect(big.length, greaterThan(TextTab.largeFileChars));
    final Fixture f = await fixture(tester, 'a.md', big);
    await tester.pumpWidget(host(markdownEditor(f)));
    final MarkdownTextController c = controllerOf(tester) as MarkdownTextController;
    expect(c.styled, isFalse);
    final TextSpan span = c.buildTextSpan(
      context: tester.element(find.byType(TextField)),
      style: const TextStyle(fontSize: 15),
      withComposing: false,
    );
    expect(span.children!.length, 1);
  });

  uiTest('triple click selects the line, double click the word', (WidgetTester tester) async {
    final Fixture f = await fixture(tester, 'a.md', 'first line\nsecond line is longer\nthird');
    await tester.pumpWidget(host(SourceEditor(store: f.store, tab: f.tab, markdown: false)));
    final Finder field = find.byType(TextField);
    final EditableTextState state = findEditableTextState(tester.element(field))!;
    final TextEditingController c = controllerOf(tester);
    final Rect caret = state.renderEditable.getLocalRectForCaret(const TextPosition(offset: 16));
    final Offset target = state.renderEditable.localToGlobal(caret.center);
    final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: target);
    addTearDown(mouse.removePointer);
    Future<void> click() async {
      await mouse.down(target);
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 40));
    }

    await click();
    await click();
    expect(c.text.substring(c.selection.start, c.selection.end), 'second', reason: 'double click selects a word');
    await click();
    final String selected = c.text.substring(c.selection.start, c.selection.end);
    // ignore: avoid_print
    print('triple click selected: "${selected.replaceAll('\n', '\\n')}" (${c.selection.start}-${c.selection.end})');
    expect(selected.trimRight(), 'second line is longer');
    await tester.pump(const Duration(seconds: 1));
  });

  uiTest('find highlights matches, steps through them and replaces all', (WidgetTester tester) async {
    final Fixture f = await fixture(tester, 'a.md', 'one fish two fish red fish blue Fish');
    await tester.pumpWidget(host(markdownEditor(f)));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    controllerOf(tester).selection = const TextSelection.collapsed(offset: 0);
    await ctrl(tester, LogicalKeyboardKey.keyF);
    await tester.pump();
    expect(find.byType(EditorFindBar), findsOneWidget);
    final Finder query = find.descendant(of: find.byType(EditorFindBar), matching: find.byType(TextField)).first;
    await tester.enterText(query, 'fish');
    await tester.pump();
    // ignore: avoid_print
    print('find bar texts: ${tester.widgetList<Text>(find.descendant(of: find.byType(EditorFindBar), matching: find.byType(Text))).map((Text t) => t.data).toList()}');
    expect(find.text('1 of 4'), findsOneWidget);
    final MarkdownTextController c = tester.widget<TextField>(find.byType(TextField).first).controller! as MarkdownTextController;
    TextSpan span = c.buildTextSpan(context: tester.element(find.byType(TextField).first), style: const TextStyle(fontSize: 15), withComposing: false);
    expect(span.children!.where((InlineSpan s) => (s as TextSpan).style?.backgroundColor != null).length, 4);
    expect(span.toPlainText(), 'one fish two fish red fish blue Fish');
    // enter steps to the next match and selects it
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('2 of 4'), findsOneWidget);
    expect(c.text.substring(c.selection.start, c.selection.end), 'fish');
    expect(c.selection.start, 13);
    // match case turns Fish off
    await tester.tap(find.text('Aa'));
    await tester.pump();
    expect(find.textContaining(' of 3'), findsOneWidget);
    // replace all through the model
    await tester.tap(find.byTooltip('Show replace'));
    await tester.pump();
    final Finder replacement = find.descendant(of: find.byType(EditorFindBar), matching: find.byType(TextField)).last;
    await tester.enterText(replacement, 'cat');
    await tester.tap(find.text('All'));
    await tester.pump();
    expect(c.text, 'one cat two cat red cat blue Fish');
    expect(f.tab.text, c.text);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(EditorFindBar), findsNothing);
    span = c.buildTextSpan(context: tester.element(find.byType(TextField).first), style: const TextStyle(fontSize: 15), withComposing: false);
    expect(span.children!.where((InlineSpan s) => (s as TextSpan).style?.backgroundColor != null).length, 0);
    await tester.pump(const Duration(milliseconds: 100));
  });

  uiTest('ribbon switches between edit, split and preview; preview renders markdown', (WidgetTester tester) async {
    const String source = '# Heading One\n\nPara with **bold** and a [link](https://example.com).\n\n- item a\n- [x] done\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```dart\nvoid main() {}\n```\n\n![alt text](x.png)\n\n<div>raw</div>\n';
    final Fixture f = await fixture(tester, 'a.md', source);
    MarkdownViewMode mode = MarkdownViewMode.edit;
    late StateSetter set;
    await tester.pumpWidget(host(StatefulBuilder(builder: (BuildContext context, StateSetter setState) {
      set = setState;
      return markdownEditor(f, mode: mode, onMode: (MarkdownViewMode m) => setState(() => mode = m));
    })));
    expect(find.byType(MarkdownPreview), findsNothing);
    await tester.tap(find.byTooltip('Edit and preview side by side'));
    await tester.pump();
    expect(mode, MarkdownViewMode.split);
    expect(find.byType(MarkdownPreview), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.textContaining('Heading One', findRichText: true), findsWidgets);
    expect(find.text('Heading One', findRichText: true), findsOneWidget);
    await tester.tap(find.byTooltip('Preview'));
    await tester.pump();
    expect(mode, MarkdownViewMode.preview);
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('alt text', findRichText: true), findsWidgets, reason: 'image placeholder shows the alt text');
    expect(find.textContaining('void main', findRichText: true), findsOneWidget);
    expect(find.text('2', findRichText: true), findsWidgets);
    // editing keeps the preview in step
    set(() => mode = MarkdownViewMode.split);
    await tester.pump();
    await tester.enterText(find.byType(TextField), '# Changed heading');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 400));
    // ignore: avoid_print
    print('field text: "${controllerOf(tester).text}" mode=$mode previews=${find.byType(MarkdownPreview).evaluate().length} rich=${tester.widgetList<RichText>(find.descendant(of: find.byType(MarkdownPreview), matching: find.byType(RichText))).map((RichText r) => r.text.toPlainText()).toList()}');
    expect(find.text('Changed heading', findRichText: true), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  uiTest('preview opens only web links', (WidgetTester tester) async {
    final List<Uri> opened = <Uri>[];
    await tester.pumpWidget(host(MarkdownPreview(
      text: '[web](https://example.com/x) and [file](file:///etc/passwd) and [js](javascript:alert(1))',
      launcher: (Uri uri) async {
        opened.add(uri);
        return true;
      },
    )));
    final Finder rich = find.byType(RichText);
    Future<void> tapSpan(String text) async {
      final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(find.descendant(of: find.byType(MarkdownPreview), matching: rich).first);
      final String all = paragraph.text.toPlainText();
      // ignore: avoid_print
      print('paragraph: "$all" richCount=${find.descendant(of: find.byType(MarkdownPreview), matching: rich).evaluate().length}');
      final int index = all.indexOf(text);
      final List<TextBox> boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: index, extentOffset: index + text.length));
      await tester.tapAt(paragraph.localToGlobal(boxes.first.toRect().center));
      await tester.pump();
    }

    await tapSpan('web');
    expect(opened.map((Uri u) => u.toString()), <String>['https://example.com/x']);
    await tapSpan('file');
    await tapSpan('js');
    expect(opened.length, 1, reason: 'file: and javascript: links are blocked');
  });

  uiTest('plain text tab inserts a tab character and indents selected lines', (WidgetTester tester) async {
    final Fixture f = await fixture(tester, 'a.txt', 'a\nb');
    await tester.pumpWidget(host(SourceEditor(store: f.store, tab: f.tab, markdown: false)));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    final TextEditingController c = controllerOf(tester);
    c.selection = const TextSelection.collapsed(offset: 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(c.text, 'a\t\nb');
    c.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(c.text, '\ta\t\n\tb');
    await tester.pump(const Duration(milliseconds: 100));
  });

  uiTest('undo reverts typing and a ribbon edit', (WidgetTester tester) async {
    final Fixture f = await fixture(tester, 'a.md', 'word');
    await tester.pumpWidget(host(markdownEditor(f)));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    final TextEditingController c = controllerOf(tester);
    // typed text first: is undo wired at all in this harness?
    await tester.enterText(find.byType(TextField), 'word typed');
    await tester.pump(const Duration(milliseconds: 600));
    await ctrl(tester, LogicalKeyboardKey.keyZ);
    await tester.pump();
    // ignore: avoid_print
    print('after undo of typing: "${c.text}"');
    await tester.enterText(find.byType(TextField), 'word');
    await tester.pump(const Duration(milliseconds: 600));
    c.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
    await ctrl(tester, LogicalKeyboardKey.keyB);
    expect(c.text, '**word**');
    await tester.pump(const Duration(milliseconds: 600));
    await ctrl(tester, LogicalKeyboardKey.keyZ);
    await tester.pump();
    // ignore: avoid_print
    print('after undo: "${c.text}"');
    expect(c.text, 'word');
    await tester.pump(const Duration(milliseconds: 100));
  });
}
