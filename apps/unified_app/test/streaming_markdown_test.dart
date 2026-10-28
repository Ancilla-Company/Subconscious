import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/editor/presentation/markdown/streaming_markdown.dart';

void main() {
  test('balanced text is unchanged', () {
    const String text = '# Title\n\nSome **bold** and `code`.\n\n- a\n- b';
    expect(completeStreamingMarkdown(text), text);
    expect(completeStreamingMarkdown(''), '');
  });

  test('an open code fence is closed', () {
    expect(
      completeStreamingMarkdown('Run:\n\n```dart\nvar x = 1;'),
      'Run:\n\n```dart\nvar x = 1;\n```',
    );
    const String closed = '```\na\n```\n\nafter';
    expect(completeStreamingMarkdown(closed), closed);
  });

  test('open emphasis and inline code are closed', () {
    expect(completeStreamingMarkdown('Some **bol'), 'Some **bol**');
    expect(completeStreamingMarkdown('Some *ital'), 'Some *ital*');
    expect(completeStreamingMarkdown('call `foo'), 'call `foo`');
    expect(completeStreamingMarkdown('~~old'), '~~old~~');
  });

  test('bullets and spaced stars are not emphasis', () {
    const String bullets = '* one\n* two';
    expect(completeStreamingMarkdown(bullets), bullets);
    expect(completeStreamingMarkdown('2 * 3 = 6'), '2 * 3 = 6');
  });

  test('an unfinished link shows its label', () {
    expect(
      completeStreamingMarkdown('See [the docs](https://exa'),
      'See the docs',
    );
    expect(completeStreamingMarkdown('See [the do'), 'See the do');
    const String done = 'See [the docs](https://example.com)';
    expect(completeStreamingMarkdown(done), done);
  });

  test('only the paragraph being written is touched', () {
    expect(
      completeStreamingMarkdown('stray * star\n\nnext **bo'),
      'stray * star\n\nnext **bo**',
    );
  });
}
