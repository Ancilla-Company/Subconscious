import '../api/dashboard_api.dart';
import '../models/dashboard_summary.dart';

/// Presentation-independent access point for dashboard data.
final class DashboardRepository {
  const DashboardRepository({required this.api});

  final DashboardApi api;

  Future<DashboardSummary> loadSummary() => api.fetchSummary();
}
