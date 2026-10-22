import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';

import '../hive_runtime.dart';
import 'nodes_page.dart';

/// Shown on devices without a local engine when the user is signed in but no
/// home engine could be reached. Explains why and offers retry and devices.
final class HomeEnginePanel extends StatelessWidget {
  const HomeEnginePanel({
    required this.runtime,
    required this.onRetry,
    this.error,
    super.key,
  });

  final HiveRuntime runtime;
  final Future<void> Function() onRetry;
  final Object? error;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: runtime,
    builder: (BuildContext context, Widget? child) {
      final ThemeData theme = Theme.of(context);
      final NodeView? local = runtime.localNode;
      final bool pending = local != null && local.node.status == 'pending';
      final String title = pending
          ? 'Connecting to your account'
          : 'No engine reachable';
      final String body = pending
          ? 'Your account devices approve this one automatically. If it '
                'takes longer than a minute, open Account > Devices on a '
                'computer that is signed in to Subconscious.'
          : 'None of your engines is online. Start Subconscious on your '
                'computer, make sure it is signed in to the same account, '
                'then try again.';
      final Object? failure = runtime.error ?? error;
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Icon(
                  pending ? Icons.verified_user_outlined : Icons.computer,
                  size: 48,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(body, textAlign: TextAlign.center),
                if (failure != null && !pending) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    failure is HiveApiException ? failure.message : '$failure',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: onRetry,
                  child: const Text('Try again'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.devices_other_outlined),
                  label: const Text('Devices'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) =>
                          NodesPage(runtime: runtime),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
