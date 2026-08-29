import 'package:core_business_logic/core_business_logic.dart';
import 'package:dart_tui/dart_tui.dart';

Future<void> main() async {
  // Mount the same pure Dart data layer used by the Flutter application.
  const DashboardRepository repository = DashboardRepository(
    api: BootstrapDashboardApi(),
  );
  await Program(options: <ProgramOption>[withAltScreen(), withHideCursor()])
      .run(DashboardTuiModel(repository: repository));
}

final class DashboardTuiModel extends Model {
  DashboardTuiModel({required this.repository, this.summary});

  final DashboardRepository repository;
  final DashboardSummary? summary;

  @override
  Cmd? init() {
    return () async => _DashboardLoaded(await repository.loadSummary());
  }

  @override
  (Model, Cmd?) update(Msg msg) {
    if (msg is _DashboardLoaded) {
      return (
        DashboardTuiModel(repository: repository, summary: msg.summary),
        null,
      );
    }
    if (msg is KeyMsg && (msg.key == 'q' || msg.key == 'ctrl+c')) {
      return (this, () => quit());
    }
    return (this, null);
  }

  @override
  View view() {
    final DashboardSummary? currentSummary = summary;
    if (currentSummary == null) {
      return newView('Loading Subconscious…');
    }
    return newView(
      '${currentSummary.title}\n\n${currentSummary.description}\n\nPress q to quit.',
    );
  }
}

final class _DashboardLoaded extends Msg {
  _DashboardLoaded(this.summary);

  final DashboardSummary summary;
}
