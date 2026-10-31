import 'dart:async';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:shared_ui_kit/shared_ui_kit.dart';
import 'package:url_launcher/url_launcher.dart';

import '../editor_fonts.dart';

/// Opens a link outside the app. Returns whether it was opened.
typedef LinkLauncher = Future<bool> Function(Uri uri);

Future<bool> _defaultLauncher(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// A read-only rendering of markdown, drawn from the real parser's tree.
///
/// Nothing here reaches the network: images appear as labelled placeholders,
/// raw HTML is shown as dimmed text instead of being interpreted, and only web
/// and email links can be opened. That keeps opening a file from ever fetching
/// remote content or running markup.
final class MarkdownPreview extends StatefulWidget {
  const MarkdownPreview({
    required this.text,
    this.debounce = const Duration(milliseconds: 150),
    this.launcher = _defaultLauncher,
    this.embedded = false,
    super.key,
  });

  /// Documents longer than this are not rendered, because parsing and laying
  /// them out would stall the editor.
  static const int maxChars = 600000;

  final String text;
  final Duration debounce;
  final LinkLauncher launcher;

  /// Lays the content out at its natural height with no padding or scrolling,
  /// so it can sit inside another widget such as a chat message. A zero
  /// [debounce] re-parses immediately, which suits streamed text.
  final bool embedded;

  @override
  State<MarkdownPreview> createState() => _MarkdownPreviewState();
}

final class _MarkdownPreviewState extends State<MarkdownPreview> {
  List<md.Node> _nodes = const <md.Node>[];
  bool _tooLarge = false;
  Timer? _timer;
  final Map<md.Element, TapGestureRecognizer> _links =
      Map<md.Element, TapGestureRecognizer>.identity();

  @override
  void initState() {
    super.initState();
    _parse(widget.text);
  }

  @override
  void didUpdateWidget(covariant MarkdownPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text == oldWidget.text) return;
    _timer?.cancel();
    if (widget.debounce == Duration.zero) {
      _parse(widget.text);
      return;
    }
    _timer = Timer(widget.debounce, () {
      if (!mounted) return;
      setState(() => _parse(widget.text));
    });
  }

  void _parse(String text) {
    _disposeLinks();
    if (text.length > MarkdownPreview.maxChars) {
      _tooLarge = true;
      _nodes = const <md.Node>[];
      return;
    }
    _tooLarge = false;
    final md.Document document = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    );
    _nodes = document.parseLines(
      text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n'),
    );
  }

  void _disposeLinks() {
    for (final TapGestureRecognizer recognizer in _links.values) {
      recognizer.dispose();
    }
    _links.clear();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _disposeLinks();
    super.dispose();
  }

  TapGestureRecognizer _recognizerFor(md.Element link) {
    return _links.putIfAbsent(
      link,
      () => TapGestureRecognizer()..onTap = () => unawaited(_open(link)),
    );
  }

  Future<void> _open(md.Element link) async {
    final String? href = link.attributes['href']?.trim();
    final Uri? uri = href == null ? null : Uri.tryParse(href);
    if (uri == null ||
        !(uri.scheme == 'http' ||
            uri.scheme == 'https' ||
            uri.scheme == 'mailto')) {
      showAppSnack(
        context,
        'Only web and email links open from the preview.',
        duration: const Duration(seconds: 3),
      );
      return;
    }
    try {
      await widget.launcher(uri);
    } on Object {
      if (!mounted) return;
      showAppSnack(
        context,
        "Couldn't open that link.",
        isError: true,
        duration: const Duration(seconds: 3),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (_tooLarge && widget.embedded) return Text(widget.text);
    if (_tooLarge) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'This file is too large to preview. Edit it as text instead.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final _Styles styles = _Styles.of(theme);
    final _Renderer renderer = _Renderer(styles, _recognizerFor);
    final List<Widget> blocks = renderer.blocks(_nodes);
    if (widget.embedded) {
      // The host provides the SelectionArea so selection can span messages.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: blocks,
      );
    }
    return SelectionArea(
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        itemCount: blocks.length,
        itemBuilder: (BuildContext context, int index) => blocks[index],
      ),
    );
  }
}

/// The text styles and colours the preview draws with.
final class _Styles {
  const _Styles({
    required this.body,
    required this.mono,
    required this.dim,
    required this.link,
    required this.colors,
    required this.headings,
  });

  factory _Styles.of(ThemeData theme) {
    final ColorScheme colors = theme.colorScheme;
    final TextStyle body = (theme.textTheme.bodyMedium ?? const TextStyle())
        .copyWith(color: colors.onSurface, height: 1.55);
    final double size = body.fontSize ?? 14;
    final TextStyle mono = body.copyWith(
      fontFamily: editorMonospaceFamily,
      fontFamilyFallback: editorMonospaceFallback,
      fontSize: size * 0.93,
      height: 1.45,
    );
    const List<double> scale = <double>[1, 2.0, 1.6, 1.35, 1.15, 1.0, 0.9];
    final List<TextStyle> headings = <TextStyle>[
      for (int level = 0; level <= 6; level++)
        body.copyWith(
          fontSize: size * scale[level],
          fontWeight: level <= 4 ? FontWeight.w700 : FontWeight.w600,
          height: 1.3,
        ),
    ];
    return _Styles(
      body: body,
      mono: mono,
      dim: body.copyWith(color: colors.onSurface.withValues(alpha: 0.5)),
      link: body.copyWith(
        color: colors.primary,
        decoration: TextDecoration.underline,
      ),
      colors: colors,
      headings: headings,
    );
  }

  final TextStyle body;
  final TextStyle mono;
  final TextStyle dim;
  final TextStyle link;
  final ColorScheme colors;
  final List<TextStyle> headings;
}

const Set<String> _inlineTags = <String>{
  'em',
  'i',
  'strong',
  'b',
  'del',
  's',
  'strike',
  'code',
  'a',
  'img',
  'br',
  'input',
  'sup',
  'sub',
  'span',
  'kbd',
  'mark',
  'u',
};

bool _isInline(md.Node node) =>
    node is md.Text || (node is md.Element && _inlineTags.contains(node.tag));

final RegExp _rawTag = RegExp(r'(<[A-Za-z/!][^>\n]*>)');

final class _Renderer {
  _Renderer(this.styles, this.recognizerFor);

  final _Styles styles;
  final TapGestureRecognizer Function(md.Element link) recognizerFor;

  /// Turns a sequence of sibling nodes into block widgets, wrapping runs of
  /// inline nodes into paragraphs.
  List<Widget> blocks(List<md.Node>? nodes, {bool tight = false}) {
    final List<Widget> out = <Widget>[];
    final List<md.Node> inlineRun = <md.Node>[];

    void flush() {
      if (inlineRun.isEmpty) return;
      final List<InlineSpan> spans = inline(inlineRun, styles.body);
      inlineRun.clear();
      if (spans.isEmpty) return;
      out.add(
        Padding(
          padding: EdgeInsets.only(bottom: tight ? 4 : 12),
          child: Text.rich(TextSpan(children: spans)),
        ),
      );
    }

    for (final md.Node node in nodes ?? const <md.Node>[]) {
      if (_isInline(node)) {
        if (node is md.Text && node.text.trim().isEmpty && inlineRun.isEmpty) {
          continue;
        }
        inlineRun.add(node);
        continue;
      }
      flush();
      out.add(_block(node as md.Element, tight: tight));
    }
    flush();
    return out;
  }

  Widget _block(md.Element element, {required bool tight}) {
    switch (element.tag) {
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final int level = int.parse(element.tag.substring(1));
        final TextStyle style = styles.headings[level];
        return Padding(
          padding: EdgeInsets.only(top: level <= 2 ? 12 : 8, bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text.rich(
                TextSpan(
                  children: inline(element.children, style),
                  style: style,
                ),
              ),
              if (level <= 2)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Divider(
                    height: 1,
                    color: styles.colors.outlineVariant,
                  ),
                ),
            ],
          ),
        );
      case 'p':
        return Padding(
          padding: EdgeInsets.only(bottom: tight ? 4 : 12),
          child: Text.rich(
            TextSpan(children: inline(element.children, styles.body)),
          ),
        );
      case 'blockquote':
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.only(left: 14),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: styles.colors.outline, width: 3),
            ),
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: styles.colors.onSurfaceVariant),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: blocks(element.children),
            ),
          ),
        );
      case 'pre':
        return _codeBlock(element);
      case 'ul':
      case 'ol':
        return _list(element, 0);
      case 'hr':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Divider(height: 1, color: styles.colors.outlineVariant),
        );
      case 'table':
        return _table(element);
      default:
        // Containers such as sections and divs, including footnote blocks.
        final List<Widget> children = blocks(element.children, tight: tight);
        if (children.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        );
    }
  }

  Widget _codeBlock(md.Element pre) {
    md.Element? code;
    for (final md.Node child in pre.children ?? const <md.Node>[]) {
      if (child is md.Element && child.tag == 'code') {
        code = child;
        break;
      }
    }
    String text = (code ?? pre).textContent;
    if (text.endsWith('\n')) text = text.substring(0, text.length - 1);
    final String? languageClass = code?.attributes['class'];
    final String language =
        languageClass != null && languageClass.startsWith('language-')
        ? languageClass.substring('language-'.length)
        : '';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: styles.colors.surfaceContainerLow,
        borderRadius: AppRadii.standard,
        border: Border.all(color: styles.colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (language.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                language,
                style: styles.dim.copyWith(
                  fontSize: (styles.body.fontSize ?? 14) * 0.8,
                ),
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(text, style: styles.mono),
          ),
        ],
      ),
    );
  }

  /// A bullet drawn as a shape rather than a glyph, so it looks the same in
  /// every font: a disc, then a ring, then a square for deeper levels.
  Widget _bullet(int depth) {
    const double size = 6;
    final Color color = styles.colors.onSurface;
    final double line =
        (styles.body.fontSize ?? 14) * (styles.body.height ?? 1.5);
    final Widget shape = switch (depth % 3) {
      0 => DecoratedBox(
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      1 => DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 1.2),
        ),
      ),
      _ => ColoredBox(color: color),
    };
    return SizedBox(
      width: 20,
      height: line,
      child: Center(
        child: SizedBox.square(dimension: size, child: shape),
      ),
    );
  }

  Widget _list(md.Element list, int depth) {
    final bool ordered = list.tag == 'ol';
    final int start = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    final List<Widget> items = <Widget>[];
    int index = 0;
    for (final md.Node child in list.children ?? const <md.Node>[]) {
      if (child is! md.Element || child.tag != 'li') continue;
      final List<md.Node> content = child.children ?? const <md.Node>[];
      final bool task =
          content.isNotEmpty &&
          content.first is md.Element &&
          (content.first as md.Element).tag == 'input';
      final Widget marker;
      if (task) {
        marker = const SizedBox(width: 0);
      } else if (ordered) {
        marker = SizedBox(
          width: 28,
          child: Text(
            '${start + index}.',
            textAlign: TextAlign.right,
            style: styles.body,
          ),
        );
      } else {
        marker = _bullet(depth);
      }
      final List<Widget> body = <Widget>[];
      final List<md.Node> pending = <md.Node>[];
      void flushPending() {
        if (pending.isEmpty) return;
        body.addAll(blocks(List<md.Node>.of(pending), tight: true));
        pending.clear();
      }

      for (final md.Node node in content) {
        if (node is md.Element && (node.tag == 'ul' || node.tag == 'ol')) {
          flushPending();
          body.add(_list(node, depth + 1));
        } else {
          pending.add(node);
        }
      }
      flushPending();
      items.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              marker,
              if (!task) const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: body,
                ),
              ),
            ],
          ),
        ),
      );
      index++;
    }
    return Padding(
      padding: EdgeInsets.only(
        left: depth == 0 ? 4 : 12,
        bottom: depth == 0 ? 12 : 4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: items,
      ),
    );
  }

  Widget _table(md.Element table) {
    final List<List<md.Element>> rows = <List<md.Element>>[];
    final List<bool> headerRow = <bool>[];
    void collect(md.Element section) {
      for (final md.Node child in section.children ?? const <md.Node>[]) {
        if (child is! md.Element) continue;
        if (child.tag == 'tr') {
          rows.add(<md.Element>[
            for (final md.Node cell in child.children ?? const <md.Node>[])
              if (cell is md.Element && (cell.tag == 'th' || cell.tag == 'td'))
                cell,
          ]);
          headerRow.add(
            rows.last.isNotEmpty &&
                rows.last.every((md.Element c) => c.tag == 'th'),
          );
        } else if (child.tag == 'thead' ||
            child.tag == 'tbody' ||
            child.tag == 'tfoot') {
          collect(child);
        }
      }
    }

    collect(table);
    if (rows.isEmpty) return const SizedBox.shrink();
    final int columns = rows.fold<int>(
      0,
      (int most, List<md.Element> row) => row.length > most ? row.length : most,
    );
    final List<TableRow> tableRows = <TableRow>[];
    for (int rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final List<md.Element> row = rows[rowIndex];
      final bool header = headerRow[rowIndex];
      tableRows.add(
        TableRow(
          decoration: header
              ? BoxDecoration(color: styles.colors.surfaceContainerLow)
              : null,
          children: <Widget>[
            for (int column = 0; column < columns; column++)
              if (column < row.length)
                _cell(row[column], header)
              else
                const SizedBox.shrink(),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.all(color: styles.colors.outlineVariant),
          children: tableRows,
        ),
      ),
    );
  }

  Widget _cell(md.Element cell, bool header) {
    final String style = cell.attributes['style'] ?? '';
    final String align = cell.attributes['align'] ?? '';
    final TextAlign textAlign = style.contains('right') || align == 'right'
        ? TextAlign.right
        : style.contains('center') || align == 'center'
        ? TextAlign.center
        : TextAlign.left;
    final TextStyle base = header
        ? styles.body.copyWith(fontWeight: FontWeight.w700)
        : styles.body;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Text.rich(
        TextSpan(children: inline(cell.children, base), style: base),
        textAlign: textAlign,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Inline content
  // ---------------------------------------------------------------------------

  /// Builds the spans for [nodes].
  ///
  /// A tap is only delivered to the recognizer of the innermost span under the
  /// pointer, never to an enclosing one, so inside a link every piece of text
  /// has to carry the link's [link] recognizer itself.
  List<InlineSpan> inline(
    List<md.Node>? nodes,
    TextStyle base, {
    TapGestureRecognizer? link,
  }) {
    final List<InlineSpan> spans = <InlineSpan>[];
    for (final md.Node node in nodes ?? const <md.Node>[]) {
      if (node is md.Text) {
        spans.addAll(_text(node.text, base, link));
        continue;
      }
      if (node is! md.Element) continue;
      switch (node.tag) {
        case 'em':
        case 'i':
          spans.add(
            TextSpan(
              style: const TextStyle(fontStyle: FontStyle.italic),
              children: inline(node.children, base, link: link),
            ),
          );
        case 'strong':
        case 'b':
          spans.add(
            TextSpan(
              style: const TextStyle(fontWeight: FontWeight.w700),
              children: inline(node.children, base, link: link),
            ),
          );
        case 'del':
        case 's':
        case 'strike':
          spans.add(
            TextSpan(
              style: const TextStyle(decoration: TextDecoration.lineThrough),
              children: inline(node.children, base, link: link),
            ),
          );
        case 'u':
          spans.add(
            TextSpan(
              style: const TextStyle(decoration: TextDecoration.underline),
              children: inline(node.children, base, link: link),
            ),
          );
        case 'code':
        case 'kbd':
          spans.add(
            TextSpan(
              text: node.textContent,
              recognizer: link,
              mouseCursor: link == null ? null : SystemMouseCursors.click,
              style: TextStyle(
                fontFamily: editorMonospaceFamily,
                fontFamilyFallback: editorMonospaceFallback,
                fontSize: (base.fontSize ?? 14) * 0.93,
                backgroundColor: styles.colors.surfaceContainerHighest
                    .withValues(alpha: 0.7),
              ),
            ),
          );
        case 'mark':
          spans.add(
            TextSpan(
              style: TextStyle(backgroundColor: AppColors.highlightFind),
              children: inline(node.children, base, link: link),
            ),
          );
        case 'sup':
        case 'sub':
          spans.add(
            TextSpan(
              style: TextStyle(fontSize: (base.fontSize ?? 14) * 0.75),
              children: inline(node.children, base, link: link),
            ),
          );
        case 'a':
          final String? href = node.attributes['href'];
          spans.add(
            TextSpan(
              style: href == null
                  ? null
                  : TextStyle(
                      color: styles.colors.primary,
                      decoration: TextDecoration.underline,
                      decorationColor: styles.colors.primary,
                    ),
              children: inline(
                node.children,
                base,
                link: href == null ? link : recognizerFor(node),
              ),
            ),
          );
        case 'br':
          spans.add(const TextSpan(text: '\n'));
        case 'img':
          spans.add(_imagePlaceholder(node));
        case 'input':
          final bool checked = node.attributes.containsKey('checked');
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  checked
                      ? FluentIcons.checkbox_checked_20_filled
                      : FluentIcons.checkbox_unchecked_20_regular,
                  size: 18,
                  color: checked
                      ? styles.colors.primary
                      : styles.colors.onSurfaceVariant,
                ),
              ),
            ),
          );
        default:
          spans.addAll(inline(node.children, base, link: link));
      }
    }
    return spans;
  }

  /// Text with soft line breaks folded to spaces and raw HTML tags dimmed.
  List<InlineSpan> _text(
    String text,
    TextStyle base,
    TapGestureRecognizer? link,
  ) {
    final String folded = text.replaceAll('\n', ' ');
    final MouseCursor? cursor = link == null ? null : SystemMouseCursors.click;
    TextSpan plain(String value) =>
        TextSpan(text: value, recognizer: link, mouseCursor: cursor);
    if (!folded.contains('<')) return <InlineSpan>[plain(folded)];
    final List<InlineSpan> spans = <InlineSpan>[];
    int position = 0;
    for (final RegExpMatch match in _rawTag.allMatches(folded)) {
      if (match.start > position) {
        spans.add(plain(folded.substring(position, match.start)));
      }
      spans.add(TextSpan(text: match.group(0), style: styles.dim));
      position = match.end;
    }
    if (position < folded.length) spans.add(plain(folded.substring(position)));
    return spans;
  }

  InlineSpan _imagePlaceholder(md.Element image) {
    final String alt = image.attributes['alt'] ?? '';
    final String source = image.attributes['src'] ?? '';
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Tooltip(
        message: source.isEmpty ? 'Image' : source,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: styles.colors.surfaceContainerHighest,
            borderRadius: AppRadii.standard,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                FluentIcons.image_20_regular,
                size: 16,
                color: styles.colors.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  alt.isEmpty ? (source.isEmpty ? 'Image' : source) : alt,
                  overflow: TextOverflow.ellipsis,
                  style: styles.dim,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
