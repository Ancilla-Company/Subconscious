import 'package:flutter/material.dart';

/// The top of a navigation flyout: a brand [logo] followed by the [title],
/// centred, 48 dp high.
///
/// The logo is passed in because the kit does not depend on an SVG renderer;
/// the app supplies its own widget (for example `SvgPicture.asset(...)`). The
/// kit's own brand mark is declared as the package asset
/// `packages/shared_ui_kit/assets/branding/logo.svg`.
final class AppFlyoutHeader extends StatelessWidget {
  const AppFlyoutHeader({
    required this.title,
    this.logo,
    this.height = 48,
    super.key,
  });

  final String title;
  final Widget? logo;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (logo != null) ...<Widget>[
            SizedBox.square(dimension: 24, child: logo),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Semantics(
              header: true,
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
