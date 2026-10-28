/// Closes the markdown a still-streaming reply has left open, so the part
/// that has arrived is drawn formatted instead of showing raw `**`, `` ` ``
/// or ```` ``` ```` until the closing marker arrives.
///
/// Only the text shown is changed; the stored message is never altered. Text
/// that is already balanced is returned as it is.
String completeStreamingMarkdown(String text) {
  if (text.isEmpty) return text;
  final String normalized = text.replaceAll('\r\n', '\n');
  final List<String> lines = normalized.split('\n');

  // An unclosed code fence: close it, and leave everything inside literal.
  String? fence;
  for (final String line in lines) {
    final Match? opener = _fence.firstMatch(line);
    if (opener == null) continue;
    final String marker = opener.group(2)!;
    if (fence == null) {
      fence = marker[0] * marker.length;
    } else if (marker[0] == fence[0] && marker.length >= fence.length) {
      fence = null;
    }
  }
  if (fence != null) return '$normalized\n$fence';

  // Inline markers only matter in the paragraph still being written.
  final int cut = normalized.lastIndexOf('\n\n');
  final String head = cut < 0 ? '' : normalized.substring(0, cut + 2);
  String tail = cut < 0 ? normalized : normalized.substring(cut + 2);

  // `[label](https://exa` or `[label` is not a link yet: show the label.
  tail = tail.replaceFirstMapped(
    RegExp(r'\[([^\]\n]*)(?:\]\([^)\n]*)?$'),
    (Match m) => m.group(1)!,
  );

  if (_countOf(tail, '`') % 2 == 1) {
    return '$head$tail`';
  }
  // Text inside inline code is literal: ignore it when counting emphasis.
  final String prose = tail.replaceAll(RegExp(r'`[^`]*`'), '');
  final StringBuffer closers = StringBuffer();
  if (_countOf(prose, '~~') % 2 == 1) closers.write('~~');
  final String withoutBold = prose.replaceAll('**', '');
  final String withoutBullets = withoutBold.replaceAll(
    RegExp(r'^[ \t]*[*+-][ \t]', multiLine: true),
    '',
  );
  // A lone `*` that is a multiplication sign or footnote mark is rare; a `*`
  // followed by a space is not an emphasis opener.
  final int singles = RegExp(r'\*(?=\S)|(?<=\S)\*')
      .allMatches(withoutBullets)
      .length;
  if (_countOf(prose, '**') % 2 == 1) closers.write('**');
  if (singles % 2 == 1) closers.write('*');
  return '$head$tail$closers';
}

final RegExp _fence = RegExp(r'^( {0,3})(`{3,}|~{3,})');

int _countOf(String text, String needle) {
  int count = 0;
  int index = text.indexOf(needle);
  while (index >= 0) {
    count++;
    index = text.indexOf(needle, index + needle.length);
  }
  return count;
}
