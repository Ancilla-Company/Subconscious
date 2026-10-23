import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import '../../account/account_controller.dart';
import '../device_tree.dart';
import '../engine_card_view.dart';
import '../executor_selection.dart';
import '../hive_runtime.dart';

/// Node list (name, kind, online, tier) plus enrol/approve flows. Signing in
/// happens only on the Account page.
final class NodesPage extends StatefulWidget {
  const NodesPage({required this.runtime, super.key});

  final HiveRuntime runtime;

  @override
  State<NodesPage> createState() => _NodesPageState();
}

final class _NodesPageState extends State<NodesPage> {
  @override
  void initState() {
    super.initState();
    widget.runtime.restore();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.runtime,
    builder: (BuildContext context, Widget? child) {
      final HiveRuntime runtime = widget.runtime;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Devices'),
          actions: <Widget>[
            if (runtime.isSignedIn) ...<Widget>[
              AppIconButton(
                tooltip: 'Refresh',
                icon: FluentIcons.arrow_clockwise_20_regular,
                onPressed: runtime.refreshing ? null : runtime.forceRefresh,
              ),
              TextButton(
                onPressed: runtime.signOut,
                child: const Text('Sign out'),
              ),
            ],
          ],
        ),
        body: runtime.isSignedIn
            ? _NodeList(runtime: runtime, embedded: false)
            : const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Sign in from the Account page to see your devices.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
      );
    },
  );
}

/// Device management without a Scaffold, for embedding in the Account page.
///
/// The account controller's server session is the only source of truth for
/// whether the user is signed in: nothing renders (and nothing is fetched)
/// unless it is signed in, and this widget never asks for credentials.
/// Failures render as a short message with Retry, never a raw error.
final class DevicesSection extends StatelessWidget {
  const DevicesSection({required this.account, super.key});

  final AccountController account;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[account, account.session]),
    builder: (BuildContext context, Widget? child) {
      final HiveRuntime runtime = account.session;
      if (!account.isAuthenticated) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (runtime.status == HiveStatus.busy)
            const LinearProgressIndicator(),
          _NodeList(runtime: runtime, embedded: true),
        ],
      );
    },
  );
}

/// Refresh for the Account page's Devices heading. Reconnects this device (or
/// the local engine) to the server now and re-reads the list; if this device
/// is still offline afterwards the cause is shown under the heading. Styled by
/// the surrounding settings form theme, like the other settings Reload buttons.
final class DevicesRefreshButton extends StatelessWidget {
  const DevicesRefreshButton({required this.account, super.key});

  final AccountController account;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[account, account.session]),
    builder: (BuildContext context, Widget? child) {
      final HiveRuntime runtime = account.session;
      if (!account.isAuthenticated) return const SizedBox.shrink();
      final bool busy = runtime.refreshing;
      return OutlinedButton.icon(
        key: const ValueKey<String>('devices-refresh'),
        onPressed: busy ? null : () => unawaited(runtime.forceRefresh()),
        icon: busy
            ? const SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(FluentIcons.arrow_clockwise_20_regular, size: 16),
        label: Text(busy ? 'Refreshing' : 'Refresh'),
      );
    },
  );
}

/// Why this device is offline while signed in. Shown until it is online.
final class _OfflineProblemNotice extends StatelessWidget {
  const _OfflineProblemNotice({required this.problem});
  final String problem;

  @override
  Widget build(BuildContext context) => AppBanner(
    key: const ValueKey<String>('devices-offline-problem'),
    tone: AppBannerTone.error,
    message: 'This device is offline. $problem',
  );
}

final class _NodeList extends StatelessWidget {
  const _NodeList({required this.runtime, required this.embedded});
  final HiveRuntime runtime;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final List<NodeView> nodes = runtime.nodes;
    final NodeView? local = runtime.localNode;
    final ThemeData theme = Theme.of(context);
    final Object? error = runtime.error;
    final bool errorIsUnavailable =
        error != null && _isServerUnavailable(error);
    final bool showEngineCard =
        !runtime.hasLocalFullNode &&
        !runtime.linkingLocalEngine &&
        !runtime.localEngineMissing;
    return ListView(
      shrinkWrap: embedded,
      physics: embedded ? const NeverScrollableScrollPhysics() : null,
      padding: embedded
          ? const EdgeInsets.only(top: 12)
          : const EdgeInsets.all(16),
      children: <Widget>[
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    devicesLoadFailedMessage(
                      error,
                      runtime.account.lastAuthError,
                    ),
                    style: errorIsUnavailable
                        ? null
                        : TextStyle(color: theme.colorScheme.error),
                  ),
                ),
                TextButton(
                  onPressed: () => runtime.hive.started
                      ? runtime.refresh()
                      : runtime.adoptSession(),
                  child: const Text('Retry'),
                ),
              ],
            ),
          )
        else if (runtime.serverUnavailable)
          const Padding(
            key: ValueKey<String>('server-unavailable'),
            padding: EdgeInsets.only(bottom: 12),
            child: Text(serverUnavailableMessage),
          ),
        if (runtime.offlineProblem case final String problem)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _OfflineProblemNotice(problem: problem),
          ),
        if (runtime.hasLocalFullNode && runtime.engineHiveState == 'signed_out')
          AppBanner(
            key: const ValueKey<String>('engine-signed-out-banner'),
            tone: AppBannerTone.error,
            message: 'Engine is not signed in. Sign out and sign in again to link it.',
          ),
        if (runtime.hasLocalFullNode &&
            runtime.engineHiveState == 'hive_mismatch')
          AppBanner(
            key: const ValueKey<String>('engine-hive-mismatch'),
            tone: AppBannerTone.error,
            message: runtime.engineHiveDetail ?? hiveMismatchMessage,
            actions: <Widget>[
              OutlinedButton(
                key: const ValueKey<String>('engine-reset-local-hive'),
                onPressed: () => _confirmResetLocalHive(context, runtime),
                child: const Text('Reset local hive data'),
              ),
            ],
          ),
        if (runtime.linkingLocalEngine) const _LinkingCard(),
        if (runtime.localEngineMissing) _EngineMissingCard(runtime: runtime),
        if (showEngineCard) _EngineCard(runtime: runtime),
        if (local != null && local.node.status == 'pending')
          _PendingBanner(runtime: runtime, nodes: nodes),
        if (runtime.approvalAbility == ApprovalAbility.engineNotTrusted)
          const Padding(
            key: ValueKey<String>('engine-not-trusted-notice'),
            padding: EdgeInsets.only(bottom: 12),
            child: Text(engineNotTrustedMessage),
          ),
        if (runtime.showCannotApprove)
          Padding(
            key: const ValueKey<String>('cannot-approve-notice'),
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              runtime.approvalAbility == ApprovalAbility.webBlocked
                  ? webCannotApproveMessage
                  : notTrustedMessage,
            ),
          ),
        if (runtime.approvalNote case final String note)
          Padding(
            key: const ValueKey<String>('approval-note'),
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(note),
          ),
        if (nodes.isEmpty && error == null) const Text('No devices yet.'),
        for (final DeviceGroup group in buildDeviceTree(
          nodes.where(runtime.isShownDevice).toList(),
        ))
          _DeviceGroupCard(runtime: runtime, group: group),
        if (runtime.executorCandidates.isNotEmpty)
          _ExecutorSection(runtime: runtime),
      ],
    );
  }
}

Future<void> _confirmResetLocalHive(
  BuildContext context,
  HiveRuntime runtime,
) async {
  final bool? confirmed = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext dialog) => AppDialog(
      key: const ValueKey<String>('engine-reset-local-hive-dialog'),
      title: 'Reset local hive data?',
      content: const Text(
        'The engine backs up its database, then clears its local hive '
        'bookkeeping. Your threads and files are kept. You will need to sign '
        'in again.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey<String>('engine-reset-local-hive-confirm'),
          onPressed: () => Navigator.of(dialog).pop(true),
          child: const Text('Reset'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  try {
    await runtime.resetLocalHive();
  } on Object catch (error) {
    if (!context.mounted) return;
    showAppSnack(context, 'Could not reset local hive data: $error');
  }
}

const String hiveMismatchMessage =
    "This data directory belongs to a different hive. Use 'Reset local hive data' to back up and clear the local hive bookkeeping (your threads and files are kept), then sign in again.";
const String serverUnavailableMessage = 'Server unavailable, retrying';
const String engineNotTrustedMessage =
    'The local engine is not approved. Sign the engine in again.';
const String webCannotApproveMessage =
    'Approve new devices from the Subconscious desktop app.';
const String notTrustedMessage =
    'This device is not approved yet. Approve it from another signed-in '
    'device.';

bool _isServerUnavailable(Object error) =>
    error is HiveApiException &&
    (error.statusCode == 502 ||
        error.statusCode == 503 ||
        error.statusCode == 504);

/// Shown on desktop while the local engine is still starting. No thin device
/// is registered meanwhile.
final class _LinkingCard extends StatelessWidget {
  const _LinkingCard();

  @override
  Widget build(BuildContext context) => const AppCard(
    key: ValueKey<String>('linking-card'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Linking to the engine on this computer...'),
        SizedBox(height: 8),
        LinearProgressIndicator(),
      ],
    ),
  );
}

/// The wait for the local engine expired.
final class _EngineMissingCard extends StatelessWidget {
  const _EngineMissingCard({required this.runtime});
  final HiveRuntime runtime;

  @override
  Widget build(BuildContext context) => AppCard(
    key: const ValueKey<String>('engine-missing-card'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text('Engine did not start. Retry, or check the engine log.'),
        const SizedBox(height: 8),
        AppButtonRow(
          children: <Widget>[
            FilledButton(
              onPressed: runtime.retryLocalEngineLink,
              child: const Text('Retry'),
            ),
            TextButton(
              onPressed: runtime.useThisPcAsRemoteClient,
              child: const Text('Use this PC as a remote client'),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Where tasks can run: the connected engine plus other online full nodes.
/// The choice itself is made per conversation in the chat composer.
final class _ExecutorSection extends StatelessWidget {
  const _ExecutorSection({required this.runtime});
  final HiveRuntime runtime;

  @override
  Widget build(BuildContext context) {
    final List<ExecutorOption> options = runtime.options;
    return Padding(
      key: const ValueKey<String>('executor-section'),
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Run tasks on', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Pick a device for a conversation with the run-on control next to '
            'the send button. The default is the engine this device is '
            'connected to.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (!runtime.hasDefaultEngine)
            Padding(
              key: const ValueKey<String>('executor-no-engine'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Not connected to an engine.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          for (final ExecutorOption option in options)
            if (!option.isHome || runtime.hasDefaultEngine)
              AppListRow(
                dense: true,
                leading: Icon(
                  option.isHome
                      ? FluentIcons.laptop_20_regular
                      : FluentIcons.phone_laptop_20_regular,
                ),
                title: option.name,
                subtitle: option.subtitle.isEmpty ? null : option.subtitle,
                trailing: option.isHome ? const AppBadge('Default') : null,
                onTap: null,
              ),
        ],
      ),
    );
  }
}

/// One device and the clients folded under it, always drawn the same way: a
/// single card with the device first and its clients as indented rows inside it
/// (wherever the group sits in the list).
final class _DeviceGroupCard extends StatelessWidget {
  const _DeviceGroupCard({required this.runtime, required this.group});
  final HiveRuntime runtime;
  final DeviceGroup group;

  @override
  Widget build(BuildContext context) => AppCard(
    padding: EdgeInsets.zero,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _NodeTile(runtime: runtime, view: group.root),
        for (final NodeView child in group.children) ...<Widget>[
          const Divider(height: 1),
          _NodeTile(runtime: runtime, view: child, nested: true),
        ],
      ],
    ),
  );
}

final class _NodeTile extends StatelessWidget {
  const _NodeTile({
    required this.runtime,
    required this.view,
    this.nested = false,
  });
  final HiveRuntime runtime;
  final NodeView view;

  /// A client row inside its device's card: indented, with no card of its own.
  final bool nested;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DirectoryNode node = view.node;
    final String? home = runtime.homeEngineId;
    final String? preferred = runtime.preferredEngineId;
    final bool isHome = home != null && nodeIdsEqual(node.id, home);
    final bool isPreferred =
        preferred != null && nodeIdsEqual(node.id, preferred);
    final bool canApprove =
        runtime.canApprove && node.status == 'pending' && !view.isLocal;
    final bool online = view.online || runtime.isOwnClientRow(view);
    final List<String> details = <String>[
      node.isEngine ? 'Full node' : 'Client',
      node.platform,
      if (node.status != 'active') node.status,
      if (online && view.tier != null) view.tier!,
    ].where((String s) => s.isNotEmpty).toList();
    final String subtitle = <String>[
      online ? 'Online' : 'Offline',
      ...details,
    ].join(', ');
    // Any device that is not this one and is not running right now can be
    // removed: a pending request, or an old install that went offline. An
    // online device can only be removed from the device itself.
    final bool canRemove =
        !view.isLocal &&
        !runtime.isOwnClientRow(view) &&
        (node.status == 'pending' || !online);
    final bool isTrustedEngine = node.isEngine && view.trusted && !view.isLocal;
    final Widget? badge = canApprove || !isTrustedEngine
        ? null
        : _engineBadge(isHome, isPreferred);
    final Widget? approveButton = canApprove
        ? FilledButton.tonal(
            onPressed: () => _showApproval(context, runtime, node),
            child: const Text('Approve'),
          )
        : null;
    final Widget? connectButton = !canApprove && isTrustedEngine
        ? _engineAction(isHome, isPreferred)
        : null;
    final Widget? removeButton = canRemove
        ? TextButton(
            onPressed: () => _confirmRemove(context, runtime, node),
            child: const Text('Remove'),
          )
        : null;
    final List<Widget> actions = <Widget>[
      if (approveButton != null) approveButton,
      if (connectButton != null) connectButton,
      if (removeButton != null) removeButton,
    ];
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
                    Text(
                      view.isLocal ? '${node.name} (this device)' : node.name,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (node.isEngine && view.clients.isNotEmpty)
                      Text(
                        'Clients: ${view.clients.join(', ')}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (badge != null) ...<Widget>[const SizedBox(width: 8), badge],
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

  Future<void> _confirmRemove(
    BuildContext context,
    HiveRuntime runtime,
    DirectoryNode node,
  ) async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => AppDialog(
        title: 'Remove ${node.name}?',
        content: Text(
          node.isEngine
              ? 'This engine is removed from your account. It can sign in '
                    'again.'
              : 'This device is removed from your account. It can sign in '
                    'again.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) await runtime.revoke(node);
  }

  /// The status pill for a trusted remote engine: Connected while this device
  /// is linked to it, Preferred for an offline preferred engine.
  Widget? _engineBadge(bool isHome, bool isPreferred) {
    if (isHome) return const AppBadge('Connected', tone: AppBadgeTone.accent);
    if (!view.online && isPreferred) return const AppBadge('Preferred');
    return null;
  }

  Widget? _engineAction(bool isHome, bool isPreferred) {
    if (isHome || !view.online) return null;
    // While the card says it is (re)connecting, no Connect is offered.
    if (engineCardViewFor(runtime).showProgress) return null;
    return TextButton(
      onPressed: () => runtime.selectEngine(view.node.id),
      child: Text(isPreferred ? 'Connect (preferred)' : 'Connect'),
    );
  }
}

/// Remote engine connection: status, Connect/Disconnect, and the choice of
/// engine (the tiles below) when several are online.
final class _EngineCard extends StatelessWidget {
  const _EngineCard({required this.runtime});
  final HiveRuntime runtime;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final EngineCardView view = engineCardViewFor(runtime);
    return AppCard(
      key: const ValueKey<String>('engine-card'),
      selected: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            liveRegion: true,
            child: Text(view.title, style: theme.textTheme.titleMedium),
          ),
          const SizedBox(height: 4),
          Text(view.detail),
          if (view.showProgress) ...<Widget>[
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: 8),
          AppButtonRow(
            children: <Widget>[
              for (final CardAction action in view.actions) _cardButton(action),
            ],
          ),
          if (view.caption case final String caption) ...<Widget>[
            const SizedBox(height: 4),
            Text(caption, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  /// Primary actions are filled, except Disconnect and Cancel which are
  /// outlined; secondary actions (Pause) are text buttons. A disabled action
  /// has a null `onPressed`, so it renders in the disabled style.
  Widget _cardButton(CardAction action) {
    final VoidCallback? onPressed = action.enabled
        ? () => unawaited(switch (action.command) {
            CardCommand.connect ||
            CardCommand.retry => runtime.reconnectEngine(),
            CardCommand.disconnect ||
            CardCommand.cancel ||
            CardCommand.pause => runtime.disconnectEngine(),
          })
        : null;
    final Widget label = Text(action.label);
    if (action.kind == CardActionKind.secondary) {
      return TextButton(onPressed: onPressed, child: label);
    }
    return switch (action.command) {
      CardCommand.disconnect ||
      CardCommand.cancel => OutlinedButton(onPressed: onPressed, child: label),
      _ => FilledButton(onPressed: onPressed, child: label),
    };
  }
}

/// Signed in, this device is approved automatically by your account's devices,
/// so no code is shown. Only after [HiveRuntime.approvalGrace] without an
/// approval does it fall back to manual guidance and the code.
final class _PendingBanner extends StatefulWidget {
  const _PendingBanner({required this.runtime, required this.nodes});
  final HiveRuntime runtime;
  final List<NodeView> nodes;

  @override
  State<_PendingBanner> createState() => _PendingBannerState();
}

final class _PendingBannerState extends State<_PendingBanner> {
  Timer? _timer;
  bool _fallback = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.runtime.approvalGrace, () {
      if (mounted) setState(() => _fallback = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final HiveRuntime runtime = widget.runtime;
    final List<NodeView> approvers = <NodeView>[
      for (final NodeView v in widget.nodes)
        if (!v.isLocal && v.trusted && v.node.status == 'active') v,
    ];
    return AppCard(
      selected: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _fallback ? 'Waiting for approval' : 'Connecting to your account',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            _fallback
                ? 'No signed-in device has approved this one yet. Open '
                      'Account > Devices on a signed-in computer. If asked, '
                      'both screens must show the same code.'
                : 'Your account devices approve this one automatically.',
          ),
          if (_fallback)
            for (final NodeView approver in approvers)
              _CodeRow(
                label: 'Code with ${approver.node.name}',
                code: runtime.codeFor(approver.node),
              ),
        ],
      ),
    );
  }
}

final class _CodeRow extends StatelessWidget {
  const _CodeRow({required this.label, required this.code});
  final String label;
  final Future<String> code;

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: code,
    builder: (BuildContext context, AsyncSnapshot<String> snapshot) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label)),
          Text(
            snapshot.data ?? '······',
            semanticsLabel: snapshot.data?.split('').join(' '),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              letterSpacing: 4,
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> _showApproval(
  BuildContext context,
  HiveRuntime runtime,
  DirectoryNode pending,
) {
  return showAppDialog<void>(
    context: context,
    builder: (BuildContext context) =>
        ApproveNodeDialog(runtime: runtime, pending: pending),
  );
}

/// Enrol/approve screen: shows the short authentication string. The user must
/// confirm it matches the code on the new device before approving.
final class ApproveNodeDialog extends StatefulWidget {
  const ApproveNodeDialog({
    required this.runtime,
    required this.pending,
    super.key,
  });

  final HiveRuntime runtime;
  final DirectoryNode pending;

  @override
  State<ApproveNodeDialog> createState() => _ApproveNodeDialogState();
}

final class _ApproveNodeDialogState extends State<ApproveNodeDialog> {
  late final Future<String> _code = widget.runtime.codeFor(widget.pending);
  bool _working = false;
  Object? _error;

  @override
  Widget build(BuildContext context) => AppDialog(
    title: 'Approve ${widget.pending.name}?',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'Check that this code is the same on the new device. If it differs, '
          'do not approve.',
        ),
        const SizedBox(height: 16),
        FutureBuilder<String>(
          future: _code,
          builder: (BuildContext context, AsyncSnapshot<String> snapshot) =>
              Center(
                child: Text(
                  snapshot.data ?? '······',
                  semanticsLabel: snapshot.data?.split('').join(' '),
                  style: Theme.of(context).textTheme.displaySmall
                      ?.copyWith(letterSpacing: 6),
                ),
              ),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            _message(_error!),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    ),
    actions: <Widget>[
      TextButton(
        onPressed: _working ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _working ? null : _approve,
        child: const Text('Codes match, approve'),
      ),
    ],
  );

  Future<void> _approve() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.runtime.approve(widget.pending);
      if (mounted) Navigator.of(context).pop();
    } on Object catch (caught) {
      if (mounted) {
        setState(() {
          _working = false;
          _error = caught;
        });
      }
    }
  }
}

String _message(Object error) =>
    error is HiveApiException ? error.message : '$error';

/// Device list failures never show raw text; the cause is logged.
@visibleForTesting
String devicesLoadFailedMessage(Object error, [String? lastAuthError]) {
  debugPrint('Devices error: $error');
  if (error is HiveApiException &&
      (error.statusCode == 401 || error.statusCode == 403)) {
    final String detail = lastAuthError == null ? '' : ' ($lastAuthError)';
    return 'Your session expired or was rejected by the server. '
        'Sign in again.$detail';
  }
  if (_isServerUnavailable(error)) return serverUnavailableMessage;
  if (error is HiveApiException && error.statusCode >= 400) {
    return 'The server returned ${error.statusCode}. Try again later.';
  }
  return "Couldn't load your devices. Check your connection and try again.";
}
