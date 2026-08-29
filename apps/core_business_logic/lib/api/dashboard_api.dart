import '../models/dashboard_summary.dart';

/// Contract implemented by the eventual HTTP, local, or embedded data source.
abstract interface class DashboardApi {
  Future<DashboardSummary> fetchSummary();
}

/// Offline bootstrap source that keeps every presentation runnable.
final class BootstrapDashboardApi implements DashboardApi {
  const BootstrapDashboardApi();

  @override
  Future<DashboardSummary> fetchSummary() async {
    return const DashboardSummary(
      title: 'Subconscious',
      description: 'Core business logic is mounted and ready.',
    );
  }
}
