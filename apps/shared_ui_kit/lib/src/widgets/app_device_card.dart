import 'package:flutter/material.dart';

import 'app_card.dart';
import '../forms/app_form_widgets.dart';

/// One device, or one client of a device, in the account's device list: the
/// [title] (its name), a [subtitle] line (online state, kind, platform), an
/// optional [detail] line under it, a [badge] at the end of the title row, and
/// [actions] (Approve, Connect, Remove) in a button row below.
///
/// A [nested] tile is a client inside its device's card: indented and tighter.
/// Put tiles in an [AppDeviceCard]; it nests the clients for you.
final class AppDeviceTile extends StatelessWidget {
  const AppDeviceTile({
    required this.title,
    required this.subtitle,
    this.detail,
    this.badge,
    this.actions = const <Widget>[],
    this.nested = false,
    super.key,
  });

  final String title;
  final String subtitle;
  final String? detail;

  /// A small status pill, such as an `AppBadge`.
  final Widget? badge;

  /// Plain `FilledButton`, `OutlinedButton` and `TextButton` children.
  final List<Widget> actions;
  final bool nested;

  /// This tile as a client row inside a device card.
  AppDeviceTile asClient() => AppDeviceTile(
    key: key,
    title: title,
    subtitle: subtitle,
    detail: detail,
    badge: badge,
    actions: actions,
    nested: true,
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: nested
          ? const EdgeInsetsDirectional.only(
              start: 36,
              end: 16,
              top: 8,
              bottom: 8,
            )
          : const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 2),
                    Text(subtitle, style: muted),
                    if (detail != null) Text(detail!, style: muted),
                  ],
                ),
              ),
              if (badge != null) ...<Widget>[const SizedBox(width: 8), badge!],
            ],
          ),
          if (actions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            AppButtonRow(children: actions),
          ],
        ],
      ),
    );
  }
}

/// The card of a device in the account's device list: the [device] first, then
/// its [clients] as indented rows inside the same card, separated by hairlines.
final class AppDeviceCard extends StatelessWidget {
  const AppDeviceCard({
    required this.device,
    this.clients = const <AppDeviceTile>[],
    super.key,
  });

  final AppDeviceTile device;
  final List<AppDeviceTile> clients;

  @override
  Widget build(BuildContext context) => AppCard(
    padding: EdgeInsets.zero,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        device,
        for (final AppDeviceTile client in clients) ...<Widget>[
          const Divider(height: 1),
          client.asClient(),
        ],
      ],
    ),
  );
}
