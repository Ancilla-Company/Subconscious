import 'package:flutter/material.dart';

import '../../context/presentation/context_panel.dart';
import '../../settings/controller/settings_controller.dart';
import '../../settings/presentation/settings_main_panel.dart';
import '../controller/dashboard_controller.dart';

final class DashboardMainPanel extends StatelessWidget {
  const DashboardMainPanel({required this.controller, super.key});

  final DashboardController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller.settings,
    builder: (BuildContext context, Widget? child) =>
        switch (controller.settings.destination) {
          MainPanelDestination.files => WorkspaceFileEditor(
            controller: controller,
          ),
          MainPanelDestination.settings => SettingsMainPanel(
            controller: controller.settings,
          ),
          MainPanelDestination.utility => const _UtilityPanel(),
        },
  );
}

final class _UtilityPanel extends StatelessWidget {
  const _UtilityPanel();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('Utility panel', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Preview · Terminal — coming soon',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}
