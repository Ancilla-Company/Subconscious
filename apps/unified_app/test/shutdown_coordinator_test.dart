import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/dashboard/controller/shutdown_coordinator.dart';

Future<void> _never() => Completer<void>().future;

void main() {
  test('a hanging task does not delay shutdown beyond the deadline', () async {
    final Stopwatch watch = Stopwatch()..start();
    final ShutdownReport report = await const ShutdownCoordinator(
      overall: Duration(milliseconds: 200),
    ).run(<ShutdownTask>[
      ShutdownTask('hang', _never, timeout: const Duration(seconds: 30)),
    ]);
    expect(watch.elapsedMilliseconds, lessThan(900));
    expect(report.timedOut, <String>['hang']);
  });

  test('per-task timeout is reported', () async {
    final ShutdownReport report = await const ShutdownCoordinator(
      overall: Duration(seconds: 2),
    ).run(<ShutdownTask>[
      ShutdownTask('slow', _never, timeout: const Duration(milliseconds: 50)),
    ]);
    expect(report.timedOut, <String>['slow']);
    expect(report.completed, isEmpty);
  });

  test('a throwing task does not stop the others', () async {
    final List<String> failures = <String>[];
    final ShutdownReport report = await ShutdownCoordinator(
      onFailure: (String name, Object _) => failures.add(name),
    ).run(<ShutdownTask>[
      ShutdownTask('bad', () async => throw StateError('boom')),
      ShutdownTask('good', () async {}),
    ]);
    expect(report.failed, <String>['bad']);
    expect(report.completed, <String>['good']);
    expect(failures, <String>['bad']);
  });

  test('tasks run in parallel', () async {
    final Stopwatch watch = Stopwatch()..start();
    final ShutdownReport report = await const ShutdownCoordinator(
      overall: Duration(seconds: 2),
    ).run(<ShutdownTask>[
      for (int i = 0; i < 4; i++)
        ShutdownTask(
          't$i',
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
          timeout: const Duration(seconds: 1),
        ),
    ]);
    expect(report.completed, hasLength(4));
    expect(watch.elapsedMilliseconds, lessThan(600));
  });
}
