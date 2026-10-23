import 'package:flutter/material.dart';
import 'package:shared_ui_kit/shared_ui_kit.dart';

import '../extension_pairing_controller.dart';

/// "Engine" section of the Account page in the browser extension: pairs this
/// browser with a local engine, or tells the user remote engines connect by
/// themselves. Built from the shared form kit only.
final class ExtensionEngineSection extends StatefulWidget {
  const ExtensionEngineSection({required this.controller, super.key});

  final ExtensionPairingController controller;

  @override
  State<ExtensionEngineSection> createState() => _ExtensionEngineSectionState();
}

final class _ExtensionEngineSectionState extends State<ExtensionEngineSection> {
  final TextEditingController _url = TextEditingController(
    text: 'http://127.0.0.1:51516',
  );
  final TextEditingController _token = TextEditingController();
  bool _advanced = false;

  @override
  void initState() {
    super.initState();
    if (widget.controller.status == ExtensionEngineStatus.idle) {
      widget.controller.refresh();
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (BuildContext context, Widget? child) {
      final ExtensionPairingController controller = widget.controller;
      final ThemeData theme = Theme.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Engine', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          AppCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ..._status(context, controller),
                if (controller.error != null) ...<Widget>[
                  const SizedBox(height: 12),
                  AppFormError(error: controller.error!),
                ],
              ],
            ),
          ),
          if (controller.status == ExtensionEngineStatus.notFound ||
              controller.status == ExtensionEngineStatus.found) ...<Widget>[
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() => _advanced = !_advanced),
              child: Text(
                _advanced
                    ? 'Hide: paste joining token'
                    : 'Advanced: paste joining token',
              ),
            ),
            if (_advanced) _advancedForm(controller),
          ],
        ],
      );
    },
  );

  List<Widget> _status(
    BuildContext context,
    ExtensionPairingController controller,
  ) {
    switch (controller.status) {
      case ExtensionEngineStatus.idle:
      case ExtensionEngineStatus.searching:
        return const <Widget>[
          Text('Looking for an engine on this computer...'),
        ];
      case ExtensionEngineStatus.pairing:
        return const <Widget>[Text('Pairing this browser...')];
      case ExtensionEngineStatus.found:
        return <Widget>[
          Text(
            'Engine found at ${controller.engine?.url.authority}. Pair this '
            'browser to use its tools and your workspaces.',
          ),
          const SizedBox(height: 12),
          AppButtonRow(
            children: <Widget>[
              FilledButton(
                onPressed: controller.pair,
                child: const Text('Pair this browser'),
              ),
            ],
          ),
        ];
      case ExtensionEngineStatus.paired:
        return <Widget>[
          Text(
            'Paired with ${controller.connection?.engineUrl ?? 'the engine'}.',
          ),
          const SizedBox(height: 12),
          AppButtonRow(
            children: <Widget>[
              OutlinedButton(
                onPressed: controller.unpair,
                child: const Text('Unpair'),
              ),
            ],
          ),
        ];
      case ExtensionEngineStatus.notFound:
        return <Widget>[
          const Text(
            'No engine found on this computer. Remote engines connect '
            'automatically through your account.',
          ),
          const SizedBox(height: 12),
          AppButtonRow(
            children: <Widget>[
              OutlinedButton(
                onPressed: controller.refresh,
                child: const Text('Search again'),
              ),
            ],
          ),
        ];
    }
  }

  Widget _advancedForm(ExtensionPairingController controller) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      AppTextField(
        label: 'Engine address',
        controller: _url,
        keyboardType: TextInputType.url,
        autocorrect: false,
      ),
      const SizedBox(height: 12),
      AppTextField(
        label: 'Joining token',
        controller: _token,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
      ),
      const SizedBox(height: 12),
      AppButtonRow(
        children: <Widget>[
          FilledButton(
            onPressed: () =>
                controller.connectWithToken(url: _url.text, token: _token.text),
            child: const Text('Connect'),
          ),
        ],
      ),
    ],
  );
}
