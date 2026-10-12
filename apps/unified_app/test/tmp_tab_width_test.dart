// Throwaway: tabs are drawn four columns wide wherever they sit in a line.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/editor/presentation/editor_text_controller.dart';
import 'package:unified_app/features/editor/presentation/indent_style.dart';
import 'package:unified_app/features/editor/presentation/tab_display.dart';
import 'package:unified_app/features/editor/presentation/workspace_code_controller.dart';

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

  const TextStyle mono = TextStyle(fontSize: 13, fontFamily: 'Consolas');

  double columnWidth() {
    final TextPainter p = TextPainter(
      text: const TextSpan(text: ' ', style: mono),
      textDirection: TextDirection.ltr,
    )..layout();
    final double w = p.width;
    p.dispose();
    return w;
  }

  /// The x of the left edge of the character at [offset], from the boxes.
  double boxLeft(TextSpan span, int offset) {
    final TextPainter p = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
    )..layout();
    final List<TextBox> boxes = p.getBoxesForSelection(
      TextSelection(baseOffset: offset, extentOffset: offset + 1),
    );
    p.dispose();
    return boxes.first.left;
  }

  double caretX(TextSpan span, int offset) {
    final TextPainter p = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
    )..layout();
    final double x = p.getOffsetForCaret(TextPosition(offset: offset), Rect.zero).dx;
    p.dispose();
    return x;
  }

  TextSpan wrap(TextSpan inner) => TextSpan(style: mono, children: <InlineSpan>[inner]);

  testWidgets('every tab is four columns wide', (WidgetTester tester) async {
    final double col = columnWidth();
    const double tolerance = 0.6;

    // leading tab, several tabs, a tab after text, and tabs on later lines
    const String text = '\tx\n\t\ty\nab\tz\n  \tw\n\t \tv';
    final TextSpan expanded = wrap(
      TabDisplay.expand(const TextSpan(text: text), mono),
    );
    expect(expanded.toPlainText(), text);

    // line 1: "\tx"            x at offset 1
    expect(boxLeft(expanded, 1), closeTo(4 * col, tolerance));
    // line 2: "\t\ty"          y at offset 5
    expect(boxLeft(expanded, 5), closeTo(8 * col, tolerance));
    // line 3: "ab\tz"          z at offset 10: two letters, then four columns
    expect(boxLeft(expanded, 10), closeTo(6 * col, tolerance));
    // line 4: "  \tw"          w at offset 15: two spaces, then four columns
    expect(boxLeft(expanded, 15), closeTo(6 * col, tolerance));
    // line 5: "\t \tv"         v at offset 20: four, one, four columns
    expect(boxLeft(expanded, 20), closeTo(9 * col, tolerance));

    // the caret agrees with the boxes after a leading tab
    expect(caretX(expanded, 1), closeTo(4 * col, tolerance));
    expect(caretX(expanded, 2), closeTo(5 * col, tolerance));
  });

  testWidgets('nested span trees keep track of line starts', (WidgetTester tester) async {
    final double col = columnWidth();
    // the shape a syntax highlighter produces: text split across children,
    // with the line break and the tab in different spans
    final TextSpan tree = TextSpan(children: <InlineSpan>[
      const TextSpan(text: 'if x:', style: TextStyle(color: Colors.red)),
      const TextSpan(text: '\n'),
      TextSpan(children: <InlineSpan>[
        const TextSpan(text: '\t'),
        const TextSpan(text: 'return', style: TextStyle(color: Colors.blue)),
        const TextSpan(text: '\n'),
      ]),
      const TextSpan(text: '\t'),
      const TextSpan(text: '\t'),
      const TextSpan(text: 'pass'),
    ]);
    final TextSpan expanded = wrap(TabDisplay.expand(tree, mono));
    final String plain = expanded.toPlainText();
    expect(plain, 'if x:\n\treturn\n\t\tpass');
    expect(boxLeft(expanded, plain.indexOf('return')), closeTo(4 * col, 0.6));
    expect(boxLeft(expanded, plain.indexOf('pass')), closeTo(8 * col, 0.6));
    // text with no tabs comes back untouched
    final TextSpan plainTree = TextSpan(children: <InlineSpan>[
      const TextSpan(text: 'abc'),
      const TextSpan(text: 'def'),
    ]);
    expect(identical(TabDisplay.expand(plainTree, mono), plainTree), isTrue);
  });

  testWidgets('the code and plain controllers use the same widths', (WidgetTester tester) async {
    final double col = columnWidth();
    const String text = 'def f():\n\tx = 1\n\t\ty = 2\nz\t= 3\n';
    final WorkspaceCodeController code = WorkspaceCodeController(
      text: text,
      language: null,
      indent: IndentStyle.detect(text),
    );
    final EditorTextController plain = EditorTextController(text: text);
    final Map<String, TextSpan> built = <String, TextSpan>{};
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (BuildContext context) {
        built['code'] = code.buildTextSpan(context: context, style: mono, withComposing: false);
        built['plain'] = plain.buildTextSpan(context: context, style: mono, withComposing: false);
        return const SizedBox();
      }),
    ));
    for (final MapEntry<String, TextSpan> entry in built.entries) {
      final TextSpan span = entry.value;
      expect(span.toPlainText(), text, reason: entry.key);
      final int x = text.indexOf('x');
      final int y = text.indexOf('y');
      final int eq = text.lastIndexOf('=');
      expect(boxLeft(span, x), closeTo(4 * col, 0.6), reason: '${entry.key} x');
      expect(boxLeft(span, y), closeTo(8 * col, 0.6), reason: '${entry.key} y');
      // "z" then a tab then "= 3": z is one column, the tab four more
      expect(boxLeft(span, eq), closeTo(5 * col, 0.6), reason: '${entry.key} =');
    }
  });
}
