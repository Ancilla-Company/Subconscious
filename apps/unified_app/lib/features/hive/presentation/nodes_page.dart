import 'dart:async';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';

import '../../account/account_controller.dart';
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
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: runtime.refresh,
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
          if (runtime.status == HiveStatus.busy) const LinearProgressIndicator(),
          _NodeList(runtime: runtime, embedded: true),
        ],
      );
    },
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
    return ListView(
      shrinkWrap: embedded,
      physics: embedded ? const NeverScrollableScrollPhysics() : null,
      padding: embedded ? const EdgeInsets.only(top: 12) : const EdgeInsets.all(16),
      children: <Widget>[
        if (runtime.error case final Object error)
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
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
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
          ),
        if (local != null && local.node.status == 'pending')
          _PendingBanner(runtime: runtime, nodes: nodes),
        if (!runtime.canApprove && local != null && local.node.status == 'active')
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'This device cannot approve other devices.',
            ),
          ),
        if (nodes.isEmpty && runtime.error == null) const Text('No devices yet.'),
        for (final NodeView view in nodes)
          _NodeTile(runtime: runtime, view: view),
        if (runtime.executorCandidates.isNotEmpty) _ExecutorSection(runtime: runtime),
      ],
    );
  }
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
          Text(
            'Run tasks on',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Pick a device for a conversation with the run-on control next to '
            'the send button. The default is the engine this device is '
            'connected to.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          for (final ExecutorOption option in options)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                option.isHome ? Icons.computer_outlined : Icons.devices,
              ),
              title: Text(option.name),
              subtitle: option.subtitle.isEmpty ? null : Text(option.subtitle),
              trailing: option.isHome ? const Text('Default') : null,
            ),
        ],
      ),
    );
  }
}

final class _NodeTile extends StatelessWidget {
  const _NodeTile({required this.runtime, required this.view});
  final HiveRuntime runtime;
  final NodeView view;

  @override
  Widget build(BuildContext context) {
    final DirectoryNode node = view.node;
    final bool canApprove =
        runtime.canApprove && node.status == 'pending' && !view.isLocal;
    final List<String> details = <String>[
      node.isEngine ? 'Engine' : 'Thin client',
      node.platform,
      if (node.status != 'active') node.status,
      if (!view.trusted && node.status == 'active') 'not verified',
      if (view.online && view.tier != null) view.tier!,
    ].where((String s) => s.isNotEmpty).toList();
    return Card(
      child: ListTile(
        title: Text(view.isLocal ? '${node.name} (this device)' : node.name),
        subtitle: Text(
          <String>[view.online ? 'Online' : 'Offline', ...details].join(', '),
        ),
        trailing: canApprove
            ? FilledButton.tonal(
                onPressed: () => _showApproval(context, runtime, node),
                child: const Text('Approve'),
              )
            : (node.isEngine && view.trusted && view.online && !view.isLocal)
            ? TextButton(
                onPressed: () => runtime.setHomeEngine(node.id),
                child: const Text('Use as home'),
              )
            : null,
      ),
    );
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
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
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
  return showDialog<void>(
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
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Approve ${widget.pending.name}?'),
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
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    letterSpacing: 6,
                  ),
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
  if (error is HiveApiException && error.statusCode >= 400) {
    return 'The server returned ${error.statusCode}. Try again later.';
  }
  return "Couldn't load your devices. Check your connection and try again.";
}