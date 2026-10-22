/// Line-break handling for text files that are edited in a text field.
///
/// A text field works best with `\n` only. A file whose breaks are all CRLF is
/// shown with `\n` and gets its `\r\n` back when it is written, so the bytes of
/// untouched lines never change. A file that mixes styles, or that contains a
/// lone `\r`, is left exactly as it is on disk: rewriting it to one style would
/// change lines the user never touched.
final class LineEndings {
  const LineEndings._({required this.text, required this.crlf});

  /// The text as the editor shows it.
  final String text;

  /// Whether every line break on disk was `\r\n` and has to be restored.
  final bool crlf;

  /// Reads [disk] text, the content exactly as stored in the file.
  factory LineEndings.fromDisk(String disk) {
    if (!disk.contains('\r')) return LineEndings._(text: disk, crlf: false);
    int carriageReturns = 0;
    int crlfPairs = 0;
    int lineFeeds = 0;
    for (int index = 0; index < disk.length; index++) {
      final int unit = disk.codeUnitAt(index);
      if (unit == 0x0D) {
        carriageReturns++;
        if (index + 1 < disk.length && disk.codeUnitAt(index + 1) == 0x0A) {
          crlfPairs++;
        }
      } else if (unit == 0x0A) {
        lineFeeds++;
      }
    }
    final bool uniformCrlf =
        crlfPairs > 0 && carriageReturns == crlfPairs && lineFeeds == crlfPairs;
    return uniformCrlf
        ? LineEndings._(text: disk.replaceAll('\r\n', '\n'), crlf: true)
        : LineEndings._(text: disk, crlf: false);
  }

  /// Rebuilds the on-disk form of [editorText].
  ///
  /// Pasted text can carry its own `\r\n`, so breaks are normalised before the
  /// original style is restored; otherwise a pasted `\r\n` would become
  /// `\r\r\n`. A file that was not uniformly CRLF is written back untouched.
  static String toDisk(String editorText, {required bool crlf}) {
    if (!crlf) return editorText;
    return normalizeBreaks(editorText).replaceAll('\n', '\r\n');
  }

  /// Collapses `\r\n` and lone `\r` breaks in [text] to `\n`.
  static String normalizeBreaks(String text) =>
      text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}
