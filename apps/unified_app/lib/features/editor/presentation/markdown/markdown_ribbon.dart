import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import 'markdown_commands.dart';

/// How a markdown file is shown.
enum MarkdownViewMode {
  /// The source, with live styling.
  edit,

  /// The source beside the rendered result.
  split,

  /// The rendered result only.
  preview,
}

/// Whether shortcuts use Cmd rather than Ctrl on this platform.
bool get usesCommandKey =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// The modifier name for tooltips, such as `Ctrl+`.
String get shortcutPrefix => usesCommandKey ? 'Cmd+' : 'Ctrl+';

/// The formatting ribbon above a markdown editor.
///
/// It only offers what the markdown source can express, and every command is
/// a plain edit of the source text. Its buttons share the sidebar's look:
/// 32 px tall, with a 4 px radius and 20 px icons.
final class MarkdownRibbon extends StatelessWidget {
  const MarkdownRibbon({
    required this.mode,
    required this.onModeChanged,
    required this.onInline,
    required this.onHeading,
    required this.onPrefix,
    required this.onCodeBlock,
    required this.onLink,
    required this.onFind,
    super.key,
  });

  final MarkdownViewMode mode;
  final ValueChanged<MarkdownViewMode> onModeChanged;
  final ValueChanged<InlineMark> onInline;
  final ValueChanged<int> onHeading;
  final ValueChanged<LinePrefix> onPrefix;
  final VoidCallback onCodeBlock;
  final VoidCallback onLink;
  final VoidCallback onFind;

  @override
  Widget build(BuildContext context) {
    final bool editable = mode != MarkdownViewMode.preview;
    final String mod = shortcutPrefix;

    Widget button({
      required IconData icon,
      required String tooltip,
      required VoidCallback onPressed,
      bool selected = false,
      bool enabled = true,
    }) => AppIconButton(
      icon: icon,
      tooltip: tooltip,
      selected: selected,
      onPressed: enabled ? onPressed : null,
    );

    return AppToolbar(
      children: <Widget>[
        button(
          icon: FluentIcons.text_bold_20_regular,
          tooltip: 'Bold (${mod}B)',
          enabled: editable,
          onPressed: () => onInline(InlineMark.bold),
        ),
        button(
          icon: FluentIcons.text_italic_20_regular,
          tooltip: 'Italic (${mod}I)',
          enabled: editable,
          onPressed: () => onInline(InlineMark.italic),
        ),
        button(
          icon: FluentIcons.text_strikethrough_20_regular,
          tooltip: 'Strikethrough (${mod}Shift+X)',
          enabled: editable,
          onPressed: () => onInline(InlineMark.strike),
        ),
        button(
          icon: FluentIcons.code_20_regular,
          tooltip: 'Inline code (${mod}E)',
          enabled: editable,
          onPressed: () => onInline(InlineMark.code),
        ),
        button(
          icon: FluentIcons.link_20_regular,
          tooltip: 'Link (${mod}K)',
          enabled: editable,
          onPressed: onLink,
        ),
        const AppToolbarDivider(),
        button(
          icon: FluentIcons.text_header_1_20_regular,
          tooltip: 'Heading 1 (${mod}1)',
          enabled: editable,
          onPressed: () => onHeading(1),
        ),
        button(
          icon: FluentIcons.text_header_2_20_regular,
          tooltip: 'Heading 2 (${mod}2)',
          enabled: editable,
          onPressed: () => onHeading(2),
        ),
        button(
          icon: FluentIcons.text_header_3_20_regular,
          tooltip: 'Heading 3 (${mod}3)',
          enabled: editable,
          onPressed: () => onHeading(3),
        ),
        const AppToolbarDivider(),
        button(
          icon: FluentIcons.text_bullet_list_20_regular,
          tooltip: 'Bulleted list (${mod}Shift+L)',
          enabled: editable,
          onPressed: () => onPrefix(LinePrefix.bullet),
        ),
        button(
          icon: FluentIcons.text_number_list_ltr_20_regular,
          tooltip: 'Numbered list (${mod}Shift+O)',
          enabled: editable,
          onPressed: () => onPrefix(LinePrefix.numbered),
        ),
        button(
          icon: FluentIcons.task_list_ltr_20_regular,
          tooltip: 'Task list (${mod}Shift+T)',
          enabled: editable,
          onPressed: () => onPrefix(LinePrefix.task),
        ),
        button(
          icon: FluentIcons.text_quote_20_regular,
          tooltip: 'Quote (${mod}Shift+Q)',
          enabled: editable,
          onPressed: () => onPrefix(LinePrefix.quote),
        ),
        button(
          icon: FluentIcons.code_block_20_regular,
          tooltip: 'Code block (${mod}Shift+K)',
          enabled: editable,
          onPressed: onCodeBlock,
        ),
        const AppToolbarDivider(),
        button(
          icon: FluentIcons.search_20_regular,
          tooltip: 'Find and replace (${mod}F)',
          enabled: editable,
          onPressed: onFind,
        ),
        const AppToolbarDivider(),
        button(
          icon: FluentIcons.edit_20_regular,
          tooltip: 'Edit',
          selected: mode == MarkdownViewMode.edit,
          onPressed: () => onModeChanged(MarkdownViewMode.edit),
        ),
        button(
          icon: FluentIcons.layout_column_two_20_regular,
          tooltip: 'Edit and preview side by side',
          selected: mode == MarkdownViewMode.split,
          onPressed: () => onModeChanged(MarkdownViewMode.split),
        ),
        button(
          icon: FluentIcons.eye_20_regular,
          tooltip: 'Preview',
          selected: mode == MarkdownViewMode.preview,
          onPressed: () => onModeChanged(MarkdownViewMode.preview),
        ),
      ],
    );
  }
}
