import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/material.dart';

import '../executor_selection.dart';
import '../hive_runtime.dart';

/// Button for the settings page that opens the devices screen.
final class HiveDevicesEntry extends StatelessWidget {
  const HiveDevicesEntry({this.runtime, super.key});

  final HiveRuntime? runtime;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: OutlinedButton.icon(
      icon: const Icon(Icons.devices_other_outlined),
      label: const Text('Manage devices'),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              NodesPage(runtime: runtime ?? HiveRuntime.shared),
        ),
      ),
    ),
  );
}

/// Node list (name, kind, online, tier) plus sign-in and enrol/approve flows.
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
            ? _NodeList(runtime: runtime)
            : _SignInForm(runtime: runtime),
      );
    },
  );
}

final class _SignInForm extends StatefulWidget {
  const _SignInForm({required this.runtime});
  final HiveRuntime runtime;

  @override
  State<_SignInForm> createState() => _SignInFormState();
}

final class _SignInFormState extends State<_SignInForm> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final HiveRuntime runtime = widget.runtime;
    final bool busy = runtime.status == HiveStatus.busy;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: ListView(
          padding: const EdgeInsets.all(24),
          shrinkWrap: true,
          children: <Widget>[
            Text(
              'Sign in to see your devices and reach your engines from here.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const <String>[AutofillHints.email],
              decoration: const InputDecoration(labelText: 'Email'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              autofillHints: const <String>[AutofillHints.password],
              decoration: const InputDecoration(labelText: 'Password'),
              onSubmitted: (_) => _submit(),
            ),
            if (runtime.error case final Object error) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _message(error),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: busy ? null : _submit,
              child: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Sign in'),
            ),
          ],
        ),
      ),
    );
  }

  void _submit() {
    widget.runtime.signIn(
      email: _email.text.trim(),
      password: _password.text,
    );
  }
}

final class _NodeList extends StatelessWidget {
  const _NodeList({required this.runtime});
  final HiveRuntime runtime;

  @override
  Widget build(BuildContext context) {
    final List<NodeView> nodes = runtime.nodes;
    final NodeView? local = runtime.localNode;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (runtime.error case final Object error)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _message(error),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
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
        if (nodes.isEmpty) const Text('No devices yet.'),
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
    final ColorScheme colors = Theme.of(context).colorScheme;
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
        leading: Icon(
          Icons.circle,
          size: 12,
          color: view.online ? Colors.green : colors.outline,
          semanticLabel: view.online ? 'Online' : 'Offline',
        ),
        title: Text(view.isLocal ? '${node.name} (this device)' : node.name),
        subtitle: Text(
          '${view.online ? 'Online' : 'Offline'} · ${details.join(' · ')}',
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

final class _PendingBanner extends StatelessWidget {
  const _PendingBanner({required this.runtime, required this.nodes});
  final HiveRuntime runtime;
  final List<NodeView> nodes;

  @override
  Widget build(BuildContext context) {
    final List<NodeView> approvers = <NodeView>[
      for (final NodeView v in nodes)
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
              'Waiting for approval',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'On an approved device, open Devices and approve this one. '
              'Both screens must show the same code.',
            ),
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
