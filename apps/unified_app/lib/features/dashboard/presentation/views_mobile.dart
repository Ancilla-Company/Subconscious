import 'package:flutter/material.dart';

import '../../chat/engine_llm_provider.dart';
import '../../chat/presentation/engine_chat_panel.dart';
import '../controller/dashboard_controller.dart';

final class MobileDashboardView extends StatelessWidget {
  const MobileDashboardView({required this.controller, super.key});
  final DashboardController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (BuildContext context, Widget? child) => Scaffold(
      appBar: AppBar(
        title: const Text('Subconscious'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: _MobileConnectionStatus(status: controller.connectionStatus),
          ),
        ],
      ),
      body: _body(),
    ),
  );

  Widget _body() {
    if (controller.isLoading || controller.isLoadingChat) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.chatError case final Object error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('$error'),
        ),
      );
    }
    final EngineLlmProvider? provider = controller.chatProvider;
    if (provider != null && controller.isConnected) {
      return EngineChatPanel(
        key: ValueKey<String>(
          provider.threadUuid ?? provider.workspaceUuid ?? 'chat',
        ),
        provider: provider,
        title: controller.selectedThread?.title,
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          controller.error?.toString() ??
              'Select a workspace to start chatting.',
        ),
      ),
    );
  }
}

final class _MobileConnectionStatus extends StatelessWidget {
  const _MobileConnectionStatus({required this.status});

  final EngineConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final (Color, String) presentation = switch (status) {
      EngineConnectionStatus.connected => (Colors.green, 'connected'),
      EngineConnectionStatus.connecting => (Colors.amber, 'connecting'),
      EngineConnectionStatus.disconnected => (Colors.red, 'disconnected'),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: presentation.$1,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(presentation.$2, style: Theme.of(context).textTheme.labelMedium),
      ],
    );
  }
}
