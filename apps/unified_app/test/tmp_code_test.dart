// Throwaway verification of the code controller and tab display. Delete after use.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/editor/presentation/editor_text_controller.dart';
import 'package:unified_app/features/editor/presentation/indent_style.dart';
import 'package:unified_app/features/editor/presentation/language_modes.dart';
import 'package:unified_app/features/editor/presentation/tab_display.dart';
import 'package:unified_app/features/editor/presentation/workspace_code_controller.dart';

WorkspaceCodeController make(String text, {String path = 'a.py'}) =>
    WorkspaceCodeController(
      text: text,
      language: languageForPath(path),
      indent: IndentStyle.detect(text, path: path),
    );

/// Types [chars] at the caret one at a time, the way the text field reports
/// keystrokes to the controller.
void type(WorkspaceCodeController c, String chars) {
  for (final String ch in chars.split('')) {
    final int at = c.selection.start;
    c.value = TextEditingValue(
      text: c.text.replaceRange(at, c.selection.end, ch),
      selection: TextSelection.collapsed(offset: at + 1),
    );
  }
}

String show(WorkspaceCodeController c) {
  final String t = c.fullText;
  final int s = c.selection.start;
  final int e = c.selection.end;
  return s == e
      ? '${t.substring(0, s)}|${t.substring(s)}'
      : '${t.substring(0, s)}[${t.substring(s, e)}]${t.substring(e)}';
}

void main() {
  setUpAll(() async {
    final FontLoader loader = FontLoader('Consolas')
      ..addFont(
        Future<ByteData>.value(
          ByteData.sublistView(
            File(r'C:\Windows\Fonts\consola.ttf').readAsBytesSync(),
          ),
        ),
      );
    await loader.load();
  });

  test('indent detection', () {
    expect(
      IndentStyle.detect('def f():\n\treturn 1\n\tx = 2\n').useTabs,
      isTrue,
    );
    expect(
      IndentStyle.detect('def f():\n    return 1\n    x = 2\n').useTabs,
      isFalse,
    );
    expect(IndentStyle.detect('def f():\n    return 1\n    x = 2\n').width, 4);
    expect(IndentStyle.detect('a:\n  b: 1\n  c:\n    d: 2\n').width, 2);
    expect(IndentStyle.detect('nothing indented').useTabs, isFalse);
    expect(IndentStyle.detect('x', path: 'main.go').useTabs, isTrue);
    expect(
      IndentStyle.detect('func f() {\n    x\n}\n', path: 'main.go').useTabs,
      isFalse,
    );
  });

  test('files load byte for byte, including tabs and odd whitespace', () {
    const String source = 'a\t\tb  \n\t\tc\n   \nd\t\n';
    final WorkspaceCodeController c = make(source);
    expect(c.fullText, source);
    expect(c.text, source);
    final WorkspaceCodeController spaces = make('def f():\n    return 1\n');
    expect(spaces.fullText, 'def f():\n    return 1\n');
  });

  test(
    'tab key inserts a tab in tab-indented files and indents a selection',
    () {
      final WorkspaceCodeController c = make('def f():\n\tx = 1\n\ty = 2\n');
      c.selection = const TextSelection.collapsed(offset: 4);
      c.onTabKeyAction();
      expect(show(c), 'def \t|f():\n\tx = 1\n\ty = 2\n');
      c.selection = const TextSelection(baseOffset: 10, extentOffset: 22);
      final String before = c.fullText;
      c.onTabKeyAction();
      expect(
        c.fullText.length,
        before.length + 2,
        reason: 'two lines indented, nothing replaced',
      );
      expect(c.fullText, contains('\t\tx = 1\n\t\ty = 2'));
      c.outdentSelection();
      expect(c.fullText, before);
    },
  );

  test(
    'tab key on a selection never deletes it, in a space-indented file either',
    () {
      final WorkspaceCodeController c = make(
        'line one\nline two\nline three\n',
      );
      c.selection = const TextSelection(baseOffset: 0, extentOffset: 17);
      c.onTabKeyAction();
      expect(c.fullText, '    line one\n    line two\nline three\n');
      // a one-line selection is replaced by one indent step, like most editors
      final WorkspaceCodeController d = make('hello world\n');
      d.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      d.onTabKeyAction();
      expect(
        d.fullText,
        '    world\n'.replaceFirst(
          '    world',
          '    '
              ' world',
        ),
      );
    },
  );

  test(
    'enter keeps tab indentation and indents after an opening brace or colon',
    () {
      final WorkspaceCodeController c = make('if x:\n\ty = 1');
      c.selection = const TextSelection.collapsed(offset: 12);
      type(c, '\n');
      expect(show(c), 'if x:\n\ty = 1\n\t|');
      type(c, 'z:');
      type(c, '\n');
      expect(show(c), 'if x:\n\ty = 1\n\tz:\n\t\t|');

      final WorkspaceCodeController s = make('def f():\n    pass');
      s.selection = const TextSelection.collapsed(offset: 8);
      type(s, '\n');
      expect(
        show(s),
        'def f():\n    \n    pass'.replaceFirst(
          '    \n    pass',
          '    |\n    pass',
        ),
      );
    },
  );

  test('typing quotes and brackets inserts exactly what was typed', () {
    final WorkspaceCodeController c = make('');
    c.selection = const TextSelection.collapsed(offset: 0);
    type(c, 'print("hi") # don\'t');
    expect(c.fullText, 'print("hi") # don\'t');
    type(c, ' {[');
    expect(c.fullText, 'print("hi") # don\'t {[');
  });

  test('a closing brace is typed as is, and shift+tab steps a line back', () {
    final WorkspaceCodeController c = make('f() {\n    ');
    c.selection = const TextSelection.collapsed(offset: 10);
    type(c, '}');
    expect(show(c), 'f() {\n    }|');
    c.outdentSelection();
    expect(c.fullText, 'f() {\n}');
    final WorkspaceCodeController t = make('f() {\n\t}');
    t.selection = const TextSelection.collapsed(offset: 8);
    t.outdentSelection();
    expect(t.fullText, 'f() {\n}');
  });

  testWidgets('tabs are drawn wide without changing the text', (
    WidgetTester tester,
  ) async {
    const String source = 'def f():\n\tx = 1\n\t\ty = 2\n';
    final WorkspaceCodeController c = make(source);
    late TextSpan span;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            span = c.buildTextSpan(
              context: context,
              style: const TextStyle(fontSize: 13),
              withComposing: false,
            );
            return const SizedBox();
          },
        ),
      ),
    );
    expect(span.toPlainText(), source);
    int tabs = 0;
    void walk(InlineSpan s) {
      if (s is TextSpan) {
        if (s.text == '\t') {
          tabs++;
          expect(s.style!.letterSpacing, greaterThan(0));
        }
        s.children?.forEach(walk);
      }
    }

    walk(span);
    expect(tabs, 3);
  });
}
