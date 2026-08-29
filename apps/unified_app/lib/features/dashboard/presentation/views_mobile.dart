import 'package:flutter/material.dart';

import '../controller/dashboard_controller.dart';

/// Compact, touch-first dashboard presentation.
final class MobileDashboardView extends StatelessWidget {
  const MobileDashboardView({required this.controller, super.key});

  final DashboardController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Subconscious')),
      body: AnimatedBuilder(
        animation: controller,
        builder: (BuildContext context, Widget? child) {
          if (controller.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (controller.error != null) {
            return const Center(child: Text('Dashboard unavailable.'));
          }
          return ListView(
            padding: const EdgeInsets.all(24),
            children: <Widget>[
              Text(
                controller.summary?.title ?? 'Dashboard',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Text(controller.summary?.description ?? 'No data yet.'),
            ],
          );
        },
      ),
    );
  }
}
