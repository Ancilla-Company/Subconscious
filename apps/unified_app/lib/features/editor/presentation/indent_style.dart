/// How a source file is indented, so that Tab and Enter follow the file's own
/// habit instead of imposing one.
final class IndentStyle {
  const IndentStyle({required this.useTabs, required this.width});

  /// Whether one indent level is a tab character.
  final bool useTabs;

  /// Columns in one indent level when spaces are used.
  final int width;

  /// The text of one indent level.
  String get unit => useTabs ? '\t' : ' ' * width;

  /// Reads the indentation habit of [text].
  ///
  /// Whichever of tab-indented or space-indented lines is more common decides
  /// whether Tab inserts a tab. For spaces, a file in which many indented lines
  /// sit at 2, 6, 10... columns is taken to use two-space levels, otherwise
  /// four. Go files default to tabs when there is no evidence either way.
  static IndentStyle detect(String text, {String path = ''}) {
    int tabLines = 0;
    int spaceLines = 0;
    int twoSpaceLines = 0;
    int cursor = 0;
    int scanned = 0;
    final int length = text.length;
    while (cursor < length && scanned < 4000) {
      scanned++;
      final int first = text.codeUnitAt(cursor);
      if (first == 0x09) {
        tabLines++;
      } else if (first == 0x20) {
        int spaces = 0;
        while (cursor + spaces < length &&
            text.codeUnitAt(cursor + spaces) == 0x20) {
          spaces++;
        }
        final int after = cursor + spaces;
        final bool blank =
            after >= length ||
            text.codeUnitAt(after) == 0x0A ||
            text.codeUnitAt(after) == 0x0D;
        if (!blank && spaces >= 2) {
          spaceLines++;
          if (spaces % 4 == 2) twoSpaceLines++;
        }
      }
      final int newline = text.indexOf('\n', cursor);
      if (newline < 0) break;
      cursor = newline + 1;
    }
    final bool goFile = path.toLowerCase().endsWith('.go');
    final bool useTabs =
        tabLines > spaceLines || (tabLines == spaceLines && goFile);
    final int width = twoSpaceLines > 0 && twoSpaceLines * 5 >= spaceLines
        ? 2
        : 4;
    return IndentStyle(useTabs: useTabs, width: width);
  }
}
