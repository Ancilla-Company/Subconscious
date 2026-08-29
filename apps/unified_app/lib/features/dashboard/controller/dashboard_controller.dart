import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter/foundation.dart';

/// Shared dashboard state consumed by every Flutter presentation layout.
final class DashboardController extends ChangeNotifier {
  DashboardController({required this.repository});

  final DashboardRepository repository;

  DashboardSummary? summary;
  Object? error;
  bool isLoading = false;

  Future<void> load() async {
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      summary = await repository.loadSummary();
    } on Object catch (caughtError) {
      error = caughtError;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }
}
