import 'package:flutter/material.dart';

import '../tokens/app_spacing.dart';

/// The header row of a panel or a panel's sub-section: 48 dp tall (the chat
/// panel header's own height) with 8 dp of vertical breathing room around its
/// 32 dp content. The title uses the style shared by account, workspace and
/// thread-settings headers (`titleMedium` at 18 px, bold).
///
/// Used for the context panel's section headers, the main panel's section
/// headers (Account, Edit/New workspace) and the chat panel's sub-panel
/// headers (Threads), so every header in the app reads at the same size and
/// sits in the same amount of vertical space.
///
/// [actions] sit after the title, separated from one another by the shared
/// 4 dp [AppSpacing.headerGap].
final class AppPanelHeader extends StatelessWidget {
  const AppPanelHeader({
    required this.title,
    this.actions = const <Widget>[],
    this.leading,
    this.titleWidget,
    this.horizontalPadding = 8,
    super.key,
  });

  final String title;

  /// Trailing controls, typically [AppIconButton]s.
  final List<Widget> actions;

  /// A control before the title (a back button, a workspace picker's icon).
  final Widget? leading;

  /// An optional custom title control. When omitted, [title] is rendered as
  /// the standard bold header text.
  final Widget? titleWidget;

  /// Left/right inset. The chat panel's own header uses 8 (the default); a
  /// host panel with a different gutter passes its own value so this header
  /// lines up with the panel's other edges.
  final double horizontalPadding;

  /// The title text style every panel header shares.
  static TextStyle? titleStyle(BuildContext context) =>
      Theme.of(context).textTheme.titleMedium
          ?.copyWith(fontSize: 18, fontWeight: FontWeight.bold);

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Padding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, 8, horizontalPadding, 8),
      child: Row(
        children: <Widget>[
          if (leading != null) ...<Widget>[leading!, AppSpacing.controlGap],
          Expanded(
            child:
                titleWidget ??
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle(context),
                ),
          ),
          if (actions.isNotEmpty) ...<Widget>[
            AppSpacing.headerGap,
            for (int index = 0; index < actions.length; index++) ...<Widget>[
              if (index > 0) AppSpacing.headerGap,
              actions[index],
            ],
          ],
        ],
      ),
    ),
  );
}
