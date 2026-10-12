// Throwaway verification of the markdown tokenizer. Delete after use.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/editor/presentation/markdown/markdown_tokenizer.dart';

String names(int f) {
  final List<String> out = <String>[];
  final int h = f & MdFlag.headingMask;
  if (h != 0) out.add('h$h');
  if (f & MdFlag.bold != 0) out.add('b');
  if (f & MdFlag.italic != 0) out.add('i');
  if (f & MdFlag.strike != 0) out.add('s');
  if (f & MdFlag.code != 0) out.add('c');
  if (f & MdFlag.link != 0) out.add('l');
  if (f & MdFlag.marker != 0) out.add('m');
  if (f & MdFlag.quote != 0) out.add('q');
  if (f & MdFlag.codeBlock != 0) out.add('cb');
  if (f & MdFlag.listMarker != 0) out.add('li');
  if (f & MdFlag.rule != 0) out.add('hr');
  if (f & MdFlag.url != 0) out.add('u');
  if (f & MdFlag.tablePipe != 0) out.add('|');
  if (f & MdFlag.html != 0) out.add('html');
  return out.join('+');
}

List<String> seg(String text) {
  final List<MdRun> runs = tokenizeMarkdown(text);
  return <String>[
    for (final MdRun r in runs)
      '${text.substring(r.start, r.end).replaceAll('\n', '\\n').replaceAll('\r', '\\r')}|${names(r.flags)}',
  ];
}

void expectCover(String text) {
  final List<MdRun> runs = tokenizeMarkdown(text);
  int cursor = 0;
  for (final MdRun r in runs) {
    expect(r.start, cursor, reason: 'gap before $r in "$text"');
    expect(r.end, greaterThan(r.start), reason: 'empty run $r in "$text"');
    cursor = r.end;
  }
  expect(cursor, text.length, reason: 'not fully covered: "$text"');
}

void main() {
  test('headings', () {
    expect(seg('# Title'), <String>['# |h1+m', 'Title|h1']);
    expect(seg('### A *b*'), <String>['### |h3+m', 'A |h3', '*|h3+i+m', 'b|h3+i', '*|h3+i+m']);
    expect(seg('## Title ##'), <String>['## |h2+m', 'Title|h2', ' ##|h2+m']);
    expect(seg('#nospace'), <String>['#nospace|']);
    expect(seg('####### seven'), <String>['####### seven|']);
  });

  test('emphasis', () {
    expect(seg('**bold** x'), <String>['**|b+m', 'bold|b', '**|b+m', ' x|']);
    expect(seg('*it*'), <String>['*|i+m', 'it|i', '*|i+m']);
    expect(seg('~~gone~~'), <String>['~~|s+m', 'gone|s', '~~|s+m']);
    expect(seg('***both***'), <String>['*|i+m', '**|b+i+m', 'both|b+i', '**|b+i+m', '*|i+m']);
    expect(seg('**bold *nested* bold**'), <String>[
      '**|b+m', 'bold |b', '*|b+i+m', 'nested|b+i', '*|b+i+m', ' bold|b', '**|b+m',
    ]);
    expect(seg('snake_case_word'), <String>['snake_case_word|']);
    expect(seg('2 * 3 * 4'), <String>['2 * 3 * 4|']);
    expect(seg('**unterminated'), <String>['**unterminated|']);
    expect(seg(r'\*not\*'), <String>[r'\*not\*|']);
    expect(seg('_it_ and __bd__'), <String>['_|i+m', 'it|i', '_|i+m', ' and |', '__|b+m', 'bd|b', '__|b+m']);
  });

  test('code', () {
    expect(seg('a `code **x**` b'), <String>['a |', '`|c+m', 'code **x**|c', '`|c+m', ' b|']);
    expect(seg('``a ` b``'), <String>['``|c+m', 'a ` b|c', '``|c+m']);
    expect(seg('`open'), <String>['`open|']);
    expect(seg('```py\nx = 1 * 2\n```\nafter'), <String>[
      '```py|m+cb', '\\n|', 'x = 1 * 2|cb', '\\n|', '```|m+cb', '\\nafter|',
    ]);
    expect(seg('~~~\n# not heading\n~~~'), <String>['~~~|m+cb', '\\n|', '# not heading|cb', '\\n|', '~~~|m+cb']);
    // unterminated fence runs to the end
    expect(seg('```\ncode\nmore'), <String>['```|m+cb', '\\n|', 'code|cb', '\\n|', 'more|cb']);
  });

  test('links', () {
    expect(seg('[a](http://x.y/a_b_c)'), <String>['[|m', 'a|l', '](|m', 'http://x.y/a_b_c|u', ')|m']);
    expect(seg('![alt](i.png "t")'), <String>['![|m', 'alt|l', '](|m', 'i.png "t"|u', ')|m']);
    expect(seg('see https://example.com/x, ok'), <String>['see |', 'https://example.com/x|l', ', ok|']);
    expect(seg('<https://a.b>'), <String>['<|m', 'https://a.b|l', '>|m']);
    expect(seg('[**b**](u)'), <String>['[|m', '**|b+l+m', 'b|b+l', '**|b+l+m', '](|m', 'u|u', ')|m']);
    expect(seg('[broken](x'), <String>['[broken](x|']);
    expect(seg('<b>x</b>'), <String>['<b>|html', 'x|', '</b>|html']);
  });

  test('blocks', () {
    expect(seg('- item'), <String>['- |li', 'item|']);
    expect(seg('  * nested **b**'), <String>['  |', '* |li', 'nested |', '**|b+m', 'b|b', '**|b+m']);
    expect(seg('1. one'), <String>['1. |li', 'one|']);
    expect(seg('2) two'), <String>['2) |li', 'two|']);
    expect(seg('- [ ] todo'), <String>['- [ ] |li', 'todo|']);
    expect(seg('- [x] done'), <String>['- [x] |li', 'done|']);
    expect(seg('**not a list**'), <String>['**|b+m', 'not a list|b', '**|b+m']);
    expect(seg('> quote **b**'), <String>['> |m+q', 'quote |q', '**|b+m+q', 'b|b+q', '**|b+m+q']);
    expect(seg('> > deep'), <String>['> > |m+q', 'deep|q']);
    expect(seg('---'), <String>['---|m+hr']);
    expect(seg('* * *'), <String>['* * *|m+hr']);
    expect(seg('> ```\n> code\n> ```\nout'), <String>[
      '> |m+q', '```|m+q+cb', '\\n|', '> |m+q', 'code|cb', '\\n|', '> |m+q', '```|m+cb', '\\nout|',
    ]);
  });

  test('tables', () {
    final List<String> table = seg('| a | b |\n|---|:-:|\n| 1 | 2 |');
    // ignore: avoid_print
    print(table);
    expect(table.contains('|||'), isTrue);
    expect(table.contains('|---|:-:||m'), isTrue);
    // header row detected through the delimiter row below it, without leading pipe
    final List<String> noLead = seg('a | b\n--|--\nc | d');
    // ignore: avoid_print
    print(noLead);
    expect(noLead.contains('|||'), isTrue, reason: '$noLead');
    // a prose sentence with a single pipe is not a table
    expect(seg('a | b'), <String>['a | b|']);
  });

  test('crlf text is still covered', () {
    expectCover('# h\r\n- a\r\n\r\n```\r\nx\r\n```\r\n');
    expect(seg('# h\r\nx')[0], '# |h1+m');
  });

  test('fuzz: always contiguous, never throws', () {
    final Random random = Random(7);
    const String alphabet = '#*_~`[]()<>!\\-+|:>. \nabc12\t\r"\'x';
    for (int round = 0; round < 4000; round++) {
      final int length = random.nextInt(60);
      final String text = String.fromCharCodes(<int>[
        for (int i = 0; i < length; i++) alphabet.codeUnitAt(random.nextInt(alphabet.length)),
      ]);
      expectCover(text);
    }
  });

  test('large documents tokenize quickly', () {
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < 6000; i++) {
      buffer.writeln('## Section $i');
      buffer.writeln('Some **bold** and _italic_ text with `code` and a [link](http://example.com/$i).');
      buffer.writeln('- item one\n- [ ] item two\n');
    }
    final String text = buffer.toString();
    final Stopwatch watch = Stopwatch()..start();
    final List<MdRun> runs = tokenizeMarkdown(text);
    watch.stop();
    // ignore: avoid_print
    print('tokenized ${text.length} chars into ${runs.length} runs in ${watch.elapsedMilliseconds} ms');
    expectCover(text);
  });
}
