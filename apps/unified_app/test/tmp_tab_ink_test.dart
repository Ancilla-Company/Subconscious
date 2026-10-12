// Throwaway: how do caret and boxes behave around a line-leading tab that is
// given reduced letter spacing to cancel Skia's per-line half-spacing shift.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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

  testWidgets('leading tab geometry', (WidgetTester tester) async {
    const TextStyle base = TextStyle(
      fontFamily: 'Consolas',
      fontSize: 13,
      color: Colors.black,
    );
    final StringBuffer out = StringBuffer();
    final TextPainter spacePainter = TextPainter(
      text: const TextSpan(text: ' ', style: base),
      textDirection: TextDirection.ltr,
    )..layout();
    final double s = spacePainter.width;
    final double target = 4 * s;
    final double mid = target - s; // natural tab is one column
    final double lead = mid / 1.5;
    out.writeln('space=$s target=$target mid=$mid lead=$lead');

    // "\tx\n\ty\nab\tz\n\t\tw"
    final TextSpan span = TextSpan(
      style: base,
      children: <InlineSpan>[
        TextSpan(text: '\t', style: TextStyle(letterSpacing: lead)),
        const TextSpan(text: 'x\n'),
        TextSpan(text: '\t', style: TextStyle(letterSpacing: lead)),
        const TextSpan(text: 'y\nab'),
        TextSpan(text: '\t', style: TextStyle(letterSpacing: mid)),
        const TextSpan(text: 'z\n'),
        TextSpan(text: '\t', style: TextStyle(letterSpacing: lead)),
        TextSpan(text: '\t', style: TextStyle(letterSpacing: mid)),
        const TextSpan(text: 'w'),
      ],
    );
    final String plain = span.toPlainText();
    out.writeln('text=${plain.replaceAll('\t', '<T>').replaceAll('\n', '<N>')}');
    final TextPainter p = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
    )..layout();
    for (int i = 0; i <= plain.length; i++) {
      final Offset caret = p.getOffsetForCaret(TextPosition(offset: i), Rect.zero);
      final String ch = i < plain.length
          ? plain[i].replaceAll('\t', '<T>').replaceAll('\n', '<N>')
          : '<end>';
      String boxText = '';
      if (i < plain.length) {
        final List<TextBox> boxes = p.getBoxesForSelection(
          TextSelection(baseOffset: i, extentOffset: i + 1),
        );
        boxText = boxes
            .map((TextBox b) => '[${b.left.toStringAsFixed(1)}..${b.right.toStringAsFixed(1)}]')
            .join(' ');
      }
      out.writeln(
        'i=$i before "$ch": caret=(${caret.dx.toStringAsFixed(1)}, ${caret.dy.toStringAsFixed(0)})  box $boxText',
      );
    }
    File('${Platform.environment['TEMP']}\\tab_ink_out.txt')
        .writeAsStringSync(out.toString());
  });
}
