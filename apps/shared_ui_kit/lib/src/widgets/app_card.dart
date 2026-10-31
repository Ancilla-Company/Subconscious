import 'package:flutter/material.dart';
import '../tokens/app_radii.dart';

import '../forms/app_form_widgets.dart';

/// The kit's card: no border, 3px corners and the `surfaceContainerLowest`
/// fill (white in light mode), with a small vertical [margin] so stacked cards
/// are spaced apart. Shape and spacing match the expansion panels of the
/// models and tools settings. Tappable when [onTap] is set.
///
/// The browser extension mirrors this in `app.css` (`.account-card`,
/// `.probe`, `.summary`); change both together.
final class AppCard extends StatelessWidget {
  const AppCard({
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.margin = const EdgeInsets.symmetric(vertical: 5),
    this.onTap,
    this.selected = false,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Space around the card; the default separates stacked cards by 10dp.
  final EdgeInsetsGeometry margin;
  final VoidCallback? onTap;

  /// Fills the card with `secondaryContainer`.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Widget body = Padding(padding: padding, child: child);
    return Card(
      margin: margin,
      color: selected
          ? colors.secondaryContainer
          : colors.surfaceContainerLowest,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: AppRadii.standard,
      ),
      child: onTap == null ? body : InkWell(onTap: onTap, child: body),
    );
  }
}

/// A card with a header: a bold [title], an optional [subtitle] and
/// [trailing] widget, and a body.
///
/// With [expandable] the header toggles the body open and closed by itself.
/// For a controlled card (an accordion where the parent decides which section
/// is open) pass [expanded] and [onToggle] instead. [margin] replaces the
/// card theme's outer margin.
final class AppSectionCard extends StatefulWidget {
  const AppSectionCard({
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.expandable = false,
    this.initiallyExpanded = true,
    this.expanded,
    this.onToggle,
    this.margin,
    this.padding = const EdgeInsets.all(12),
    this.bordered,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;
  final bool expandable;
  final bool initiallyExpanded;

  /// Draws the `outlineVariant` border. Null follows the kit convention:
  /// plain section cards are bordered, expansion panels (expandable or
  /// controlled cards, as in the models and tools configuration) are
  /// borderless and sit on a soft `surfaceContainerLow` fill instead.
  final bool? bordered;

  /// Controlled open state; overrides the card's own when non-null.
  final bool? expanded;

  /// Called when the header is tapped; makes the card expandable.
  final VoidCallback? onToggle;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry padding;

  @override
  State<AppSectionCard> createState() => _AppSectionCardState();
}

final class _AppSectionCardState extends State<AppSectionCard> {
  late bool _expanded = widget.initiallyExpanded;

  bool get _isExpandable => widget.expandable || widget.onToggle != null;
  bool get _isOpen => widget.expanded ?? _expanded;

  void _toggle() {
    if (widget.onToggle != null) {
      widget.onToggle!();
    } else {
      setState(() => _expanded = !_expanded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool open = !_isExpandable || _isOpen;
    final double inset = _horizontal(widget.padding);
    final Widget titles = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AppSectionHeading(title: widget.title),
        if (widget.subtitle != null)
          Text(
            widget.subtitle!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
    final EdgeInsets inset4 = widget.padding.resolve(TextDirection.ltr);
    // The trailing widget (often a switch) keeps its own semantics and taps.
    final Widget row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: _isExpandable
              ? Semantics(
                  button: true,
                  expanded: _isOpen,
                  label: widget.title,
                  excludeSemantics: true,
                  onTap: _toggle,
                  // Taps fall through to the header's single button below.
                  child: IgnorePointer(
                    child: Padding(padding: widget.padding, child: titles),
                  ),
                )
              : Padding(padding: widget.padding, child: titles),
        ),
        if (widget.trailing != null)
          Padding(
            padding: EdgeInsets.symmetric(vertical: inset4.top),
            child: Center(child: widget.trailing),
          ),
        if (_isExpandable)
          // Only a sign of the state: the whole header is the button.
          ExcludeSemantics(
            child: IgnorePointer(
              child: Padding(
                padding: EdgeInsets.only(left: 8, right: inset4.right),
                child: Icon(
                  _isOpen ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                ),
              ),
            ),
          )
        else
          SizedBox(width: inset4.right),
      ],
    );
    final Widget header = _isExpandable
        ? Stack(
            children: <Widget>[
              Positioned.fill(
                child: ExcludeSemantics(child: InkWell(onTap: _toggle)),
              ),
              row,
            ],
          )
        : row;
    final bool bordered = widget.bordered ?? !_isExpandable;
    return Card(
      margin: widget.margin,
      clipBehavior: Clip.antiAlias,
      // An expansion panel has no outline; only the fill sets it apart.
      color: bordered ? null : theme.colorScheme.surfaceContainerLow,
      elevation: bordered ? null : 0,
      shape: bordered
          ? null
          : const RoundedRectangleBorder(
              borderRadius: AppRadii.standard,
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          header,

          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            alignment: Alignment.topCenter,
            child: open
                ? Padding(
                    padding: EdgeInsets.only(
                      left: inset,
                      right: inset,
                      bottom: inset,
                    ),
                    child: widget.child,
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  static double _horizontal(EdgeInsetsGeometry padding) =>
      padding.resolve(TextDirection.ltr).left;
}
