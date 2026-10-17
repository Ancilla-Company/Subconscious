import 'dart:async';

/// One piece of cleanup that runs while the window closes.
final class ShutdownTask {
  const ShutdownTask(
    this.name,
    this.run, {
    this.timeout = const Duration(milliseconds: 500),
  });

  final String name;
  final Future<void> Function() run;
  final Duration timeout;
}

/// What happened to each task of one [ShutdownCoordinator.run].
final class ShutdownReport {
  const ShutdownReport({
    required this.completed,
    required this.timedOut,
    required this.failed,
  });

  final List<String> completed;
  final List<String> timedOut;
  final List<String> failed;
}

/// Runs cleanup tasks in parallel, each under its own timeout, and never
/// waits longer than [overall] in total, so a hung task cannot hold the
/// window open. Uses only [Duration]s, so tests can drive it with fakeAsync.
final class ShutdownCoordinator {
  const ShutdownCoordinator({
    this.overall = const Duration(seconds: 1),
    this.onFailure,
  });

  final Duration overall;
  final void Function(String name, Object error)? onFailure;

  Future<ShutdownReport> run(List<ShutdownTask> tasks) async {
    final List<String> completed = <String>[];
    final List<String> timedOut = <String>[];
    final List<String> failed = <String>[];
    final Set<String> pending = tasks.map((ShutdownTask t) => t.name).toSet();

    Future<void> runOne(ShutdownTask task) async {
      try {
        await task.run().timeout(task.timeout);
        completed.add(task.name);
      } on TimeoutException catch (error) {
        timedOut.add(task.name);
        onFailure?.call(task.name, error);
      } on Object catch (error) {
        failed.add(task.name);
        onFailure?.call(task.name, error);
      } finally {
        pending.remove(task.name);
      }
    }

    try {
      await Future.wait(tasks.map(runOne)).timeout(overall);
    } on TimeoutException catch (error) {
      for (final String name in pending) {
        timedOut.add(name);
        onFailure?.call(name, error);
      }
    }
    return ShutdownReport(
      completed: List<String>.of(completed),
      timedOut: List<String>.of(timedOut),
      failed: List<String>.of(failed),
    );
  }
}
