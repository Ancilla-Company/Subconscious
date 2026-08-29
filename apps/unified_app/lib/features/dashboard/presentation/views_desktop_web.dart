import 'package:flutter/material.dart';

import '../controller/dashboard_controller.dart';

/// Wide dashboard shell for desktop and browser navigation patterns.
final class DesktopWebDashboardView extends StatelessWidget {
  const DesktopWebDashboardView({required this.controller, super.key});

  final DashboardController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: <Widget>[
          NavigationRail(
            destinations: const <NavigationRailDestination>[
              NavigationRailDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard),
                label: Text('Dashboard'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: Text('Settings'),
              ),
            ],
            selectedIndex: 0,
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: AnimatedBuilder(
              animation: controller,
              builder: (BuildContext context, Widget? child) {
                if (controller.isLoading) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (controller.error != null) {
                  return const Center(child: Text('Dashboard unavailable.'));
                }
                return Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        controller.summary?.title ?? 'Dashboard',
                        style: Theme.of(context).textTheme.headlineLarge,
                      ),
                      const SizedBox(height: 12),
                      Text(controller.summary?.description ?? 'No data yet.'),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
