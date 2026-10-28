// Throwaway verification of markdown commands. Delete after use.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/editor/presentation/markdown/markdown_commands.dart';

TextEditingValue v(String text, int a, [int? b]) => TextEditingValue(
  text: text,
  selection: TextSelection(baseOffset: a, extentOffset: b ?? a),
);

String show(TextEditingValue value) {
  final String t = value.text;
  final int s = value.selection.start;
  final int e = value.selection.end;
  if (s == e) return '${t.substring(0, s)}|${t.substring(s)}';
  return '${t.substring(0, s)}[${t.substring(s, e)}]${t.substring(e)}';
}

TextEditingValue enter(String before, [String after = '']) {
  final TextEditingValue old = TextEditingValue(
    text: '$before$after',
    selection: TextSelection.collapsed(offset: before.length),
  );
  final TextEditingValue next = TextEditingValue(
    text: '$before\n$after',
    selection: TextSelection.collapsed(offset: before.length + 1),
  );
  return const MarkdownEnterFormatter().formatEditUpdate(old, next);
}

void main() {
  test('inline toggles', () {
    expect(
      show(
        MarkdownCommands.toggleInline(v('hello world', 6, 11), InlineMark.bold),
      ),
      'hello **[world]**',
    );
    expect(
      show(
        MarkdownCommands.toggleInline(
          v('hello **world**', 8, 13),
          InlineMark.bold,
        ),
      ),
      'hello [world]',
    );
    expect(
      show(
        MarkdownCommands.toggleInline(
          v('hello **world**', 6, 15),
          InlineMark.bold,
        ),
      ),
      'hello [world]',
    );
    expect(
      show(MarkdownCommands.toggleInline(v('hello', 2), InlineMark.italic)),
      '*[hello]*',
    );
    expect(
      show(MarkdownCommands.toggleInline(v('*word*', 1, 5), InlineMark.bold)),
      '***[word]***',
    );
    expect(
      show(
        MarkdownCommands.toggleInline(v('***word***', 3, 7), InlineMark.italic),
      ),
      '**[word]**',
    );
    expect(
      show(
        MarkdownCommands.toggleInline(v('***word***', 3, 7), InlineMark.bold),
      ),
      '*[word]*',
    );
    expect(
      show(
        MarkdownCommands.toggleInline(v('**word**', 2, 6), InlineMark.italic),
      ),
      '***[word]***',
    );
    expect(
      show(MarkdownCommands.toggleInline(v('a  b', 2), InlineMark.bold)),
      'a **|** b',
    );
    expect(
      show(
        MarkdownCommands.toggleInline(v('x  word y', 2, 8), InlineMark.strike),
      ),
      'x  ~~[word]~~ y',
    );
    expect(
      show(
        MarkdownCommands.toggleInline(v('use foo now', 4, 7), InlineMark.code),
      ),
      'use `[foo]` now',
    );
    expect(
      show(
        MarkdownCommands.toggleInline(
          v('use `foo` now', 5, 8),
          InlineMark.code,
        ),
      ),
      'use [foo] now',
    );
  });

  test('headings', () {
    expect(show(MarkdownCommands.setHeading(v('Title', 5), 1)), '# Title|');
    expect(show(MarkdownCommands.setHeading(v('# Title', 7), 1)), 'Title|');
    expect(show(MarkdownCommands.setHeading(v('## Title', 8), 1)), '# Title|');
    expect(show(MarkdownCommands.setHeading(v('## Title', 8), 0)), 'Title|');
    expect(show(MarkdownCommands.setHeading(v('', 0), 2)), '## |');
    expect(
      show(MarkdownCommands.setHeading(v('a\n\nb', 0, 4), 3)),
      '[### a\n\n### b]',
    );
    expect(
      show(MarkdownCommands.setHeading(v('x\nTitle\ny', 4), 2)),
      'x\n## Ti|tle\ny',
    );
  });

  test('line prefixes', () {
    expect(
      show(
        MarkdownCommands.toggleLinePrefix(v('a\nb', 0, 3), LinePrefix.bullet),
      ),
      '[- a\n- b]',
    );
    expect(
      show(
        MarkdownCommands.toggleLinePrefix(
          v('- a\n- b', 0, 7),
          LinePrefix.bullet,
        ),
      ),
      '[a\nb]',
    );
    expect(
      show(
        MarkdownCommands.toggleLinePrefix(
          v('- a\n- b', 0, 7),
          LinePrefix.numbered,
        ),
      ),
      '[1. a\n2. b]',
    );
    expect(
      show(
        MarkdownCommands.toggleLinePrefix(
          v('a\n\nb', 0, 4),
          LinePrefix.numbered,
        ),
      ),
      '[1. a\n\n2. b]',
    );
    expect(
      show(MarkdownCommands.toggleLinePrefix(v('- a', 3), LinePrefix.task)),
      '- [ ] a|',
    );
    expect(
      show(MarkdownCommands.toggleLinePrefix(v('- [x] a', 7), LinePrefix.task)),
      'a|',
    );
    expect(
      show(MarkdownCommands.toggleLinePrefix(v('  a', 3), LinePrefix.bullet)),
      '  - a|',
    );
    expect(
      show(MarkdownCommands.toggleLinePrefix(v('quote', 5), LinePrefix.quote)),
      '> quote|',
    );
    expect(
      show(
        MarkdownCommands.toggleLinePrefix(v('> quote', 7), LinePrefix.quote),
      ),
      'quote|',
    );
    expect(
      show(
        MarkdownCommands.toggleLinePrefix(v('a\nb\nc', 2), LinePrefix.bullet),
      ),
      'a\n- |b\nc',
    );
    expect(
      show(
        MarkdownCommands.toggleLinePrefix(v('a\nb\nc', 3), LinePrefix.bullet),
      ),
      'a\n- b|\nc',
    );
  });

  test('code block and link', () {
    expect(show(MarkdownCommands.insertCodeBlock(v('', 0))), '```\n|\n```');
    expect(
      show(MarkdownCommands.insertCodeBlock(v('abc', 3))),
      'abc\n```\n|\n```',
    );
    expect(
      show(MarkdownCommands.insertCodeBlock(v('x\ny\nz', 2, 3))),
      'x\n```\n[y]\n```\nz',
    );
    expect(
      show(MarkdownCommands.insertLink(v('see text', 4, 8))),
      'see text'.replaceFirst('text', '[text]([url])'),
    );
    expect(
      show(MarkdownCommands.insertLink(v('go https://a.b', 3, 14))),
      'go [|](https://a.b)',
    );
    expect(show(MarkdownCommands.insertLink(v('', 0))), '[|](url)');
  });

  test('indentation', () {
    expect(
      show(MarkdownCommands.indent(v('- a', 3), outdent: false)!),
      '  - a|',
    );
    expect(
      show(MarkdownCommands.indent(v('  - a', 5), outdent: true)!),
      '- a|',
    );
    expect(
      show(MarkdownCommands.indent(v('1. a', 4), outdent: false)!),
      '   1. a|',
    );
    expect(
      show(MarkdownCommands.indent(v('plain', 5), outdent: false)!),
      'plain  |',
    );
    expect(
      show(MarkdownCommands.indent(v('a\nb', 0, 3), outdent: false)!),
      '[  a\n  b]',
    );
    expect(
      show(MarkdownCommands.indent(v('  a\n  b', 0, 7), outdent: true)!),
      '[a\nb]',
    );
  });

  test('enter continues and leaves lists', () {
    expect(show(enter('- a')), '- a\n- |');
    expect(show(enter('* a')), '* a\n* |');
    expect(show(enter('  - a')), '  - a\n  - |');
    expect(show(enter('1. a')), '1. a\n2. |');
    expect(show(enter('9) a')), '9) a\n10) |');
    expect(show(enter('- [x] done')), '- [x] done\n- [ ] |');
    expect(show(enter('- [ ] todo')), '- [ ] todo\n- [ ] |');
    expect(show(enter('> q')), '> q\n> |');
    expect(show(enter('> > deep')), '> > deep\n> > |');
    expect(show(enter('- ')), '|');
    expect(show(enter('a\n- ')), 'a\n|');
    expect(show(enter('1. ')), '|');
    expect(show(enter('> ')), '|');
    expect(show(enter('  code')), '  code\n  |');
    expect(show(enter('plain')), 'plain\n|');
    expect(show(enter('---')), '---\n|');
    expect(show(enter('```\n- a')), '```\n- a\n|');
    expect(show(enter('```\ncode\n```\n- a')), '```\ncode\n```\n- a\n- |');
    expect(show(enter('- a', 'tail')), '- a\n- |tail');
    expect(show(enter('**bold** text')), '**bold** text\n|');
  });

  test('enter ignores pastes and selections', () {
    const TextEditingValue old = TextEditingValue(
      text: '- a',
      selection: TextSelection.collapsed(offset: 3),
    );
    const TextEditingValue pasted = TextEditingValue(
      text: '- a\n\nmore',
      selection: TextSelection.collapsed(offset: 9),
    );
    expect(
      const MarkdownEnterFormatter().formatEditUpdate(old, pasted),
      pasted,
    );
  });

  test('pasted CRLF is normalised with the selection kept', () {
    const TextEditingValue old = TextEditingValue(
      text: 'ab',
      selection: TextSelection.collapsed(offset: 2),
    );
    const TextEditingValue next = TextEditingValue(
      text: 'ab\r\ncd\r\n',
      selection: TextSelection.collapsed(offset: 8),
    );
    final TextEditingValue out = const NormalizeNewlinesFormatter()
        .formatEditUpdate(old, next);
    expect(out.text, 'ab\ncd\n');
    expect(out.selection.baseOffset, 6);
    final TextEditingValue lone = const NormalizeNewlinesFormatter()
        .formatEditUpdate(
          old,
          const TextEditingValue(
            text: 'a\rb',
            selection: TextSelection.collapsed(offset: 3),
          ),
        );
    expect(lone.text, 'a\nb');
    expect(lone.selection.baseOffset, 3);
  });
}
