import 'package:core_business_logic/core_business_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unified_app/features/hive/engine_card_view.dart';
import 'package:unified_app/features/hive/hive_runtime.dart';

/// One row of the design 5.5 matrix with the Section 11.1 amendments.
final class _Row {
  const _Row({
    required this.name,
    required this.state,
    required this.auto,
    required this.choice,
    required this.hasCandidates,
    required this.hysteresis,
    required this.title,
    required this.buttons,
    this.caption,
    this.progress = false,
  });
  final String name;
  final EngineLinkState state;
  final bool auto;
  final EngineChoiceKind choice;
  final bool hasCandidates;
  final bool hysteresis;
  final String title;

  /// `label:enabled` in display order.
  final List<String> buttons;
  final String? caption;
  final bool progress;
}

const List<_Row> _rows = <_Row>[
  _Row(
    name: '1 connected',
    state: EngineLinkState.connected,
    auto: true,
    choice: EngineChoiceKind.connect,
    hasCandidates: true,
    hysteresis: false,
    title: 'Connected to Desk',
    buttons: <String>['Disconnect:true'],
  ),
  _Row(
    name: '2 connecting, auto on, candidate',
    state: EngineLinkState.connecting,
    auto: true,
    choice: EngineChoiceKind.connect,
    hasCandidates: true,
    hysteresis: false,
    title: 'Connecting to engine...',
    buttons: <String>['Cancel:true'],
    progress: true,
  ),
  _Row(
    name: '3 connecting, auto off',
    state: EngineLinkState.connecting,
    auto: false,
    choice: EngineChoiceKind.connect,
    hasCandidates: true,
    hysteresis: false,
    title: 'Connecting to engine...',
    buttons: <String>['Cancel:true'],
    progress: true,
  ),
  _Row(
    name: '4 connecting, auto on, no candidate',
    state: EngineLinkState.connecting,
    auto: true,
    choice: EngineChoiceKind.none,
    hasCandidates: false,
    hysteresis: false,
    title: 'Connecting to engine...',
    buttons: <String>['Cancel:true'],
    progress: true,
  ),
  _Row(
    name: '5 failed, auto on, candidate',
    state: EngineLinkState.failed,
    auto: true,
    choice: EngineChoiceKind.connect,
    hasCandidates: true,
    hysteresis: false,
    title: 'Could not reach the engine',
    buttons: <String>['Retry:true', 'Pause:true'],
  ),
  _Row(
    name: '6 failed, auto on, no candidate',
    state: EngineLinkState.failed,
    auto: true,
    choice: EngineChoiceKind.none,
    hasCandidates: false,
    hysteresis: false,
    title: 'Could not reach the engine',
    buttons: <String>['Connect:false', 'Pause:true'],
    caption: 'No engine is online.',
  ),
  _Row(
    name: '7 failed, auto off, candidate',
    state: EngineLinkState.failed,
    auto: false,
    choice: EngineChoiceKind.connect,
    hasCandidates: true,
    hysteresis: false,
    title: 'Could not reach the engine',
    buttons: <String>['Connect:true'],
  ),
  _Row(
    name: '8 failed, auto off, no candidate',
    state: EngineLinkState.failed,
    auto: false,
    choice: EngineChoiceKind.none,
    hasCandidates: false,
    hysteresis: false,
    title: 'Could not reach the engine',
    buttons: <String>['Connect:false'],
    caption: 'No engine is online.',
  ),
  _Row(
    name: '9 disconnected, auto on, connect',
    state: EngineLinkState.disconnected,
    auto: true,
    choice: EngineChoiceKind.connect,
    hasCandidates: true,
    hysteresis: false,
    title: 'Connecting to engine...',
    buttons: <String>['Cancel:true'],
    progress: true,
  ),
  _Row(
    name: '10 disconnected, auto on, pick',
    state: EngineLinkState.disconnected,
    auto: true,
    choice: EngineChoiceKind.pick,
    hasCandidates: true,
    hysteresis: false,
    title: 'Choose an engine',
    buttons: <String>['Pause:true'],
  ),
  _Row(
    name: '11 disconnected, auto on, none, inside hysteresis',
    state: EngineLinkState.disconnected,
    auto: true,
    choice: EngineChoiceKind.none,
    hasCandidates: false,
    hysteresis: true,
    title: 'Reconnecting to engine...',
    buttons: <String>['Cancel:true'],
    progress: true,
  ),
  _Row(
    name: '12 disconnected, auto on, none, after hysteresis',
    state: EngineLinkState.disconnected,
    auto: true,
    choice: EngineChoiceKind.none,
    hasCandidates: false,
    hysteresis: false,
    title: 'No engine online',
    buttons: <String>['Connect:false'],
    caption:
        'No engine is online. This device connects as soon as one appears.',
  ),
  _Row(
    name: '13 disconnected, auto off, candidate',
    state: EngineLinkState.disconnected,
    auto: false,
    choice: EngineChoiceKind.connect,
    hasCandidates: true,
    hysteresis: false,
    title: 'Not connected',
    buttons: <String>['Connect:true'],
  ),
  _Row(
    name: '14 disconnected, auto off, no candidate',
    state: EngineLinkState.disconnected,
    auto: false,
    choice: EngineChoiceKind.none,
    hasCandidates: false,
    hysteresis: false,
    title: 'Not connected',
    buttons: <String>['Connect:false'],
    caption: 'No engine is online.',
  ),
];

void main() {
  test('the matrix has 14 rows', () => expect(_rows, hasLength(14)));

  for (final _Row row in _rows) {
    test('row ${row.name}', () {
      final EngineCardView view = buildEngineCardView(
        engineState: row.state,
        autoConnect: row.auto,
        choice: row.choice,
        hasCandidates: row.hasCandidates,
        inHysteresis: row.hysteresis,
        connectedName: 'Desk',
      );
      expect(view.title, row.title);
      expect(view.showProgress, row.progress);
      expect(<String>[
        for (final CardAction a in view.actions) '${a.label}:${a.enabled}',
      ], row.buttons);
      expect(view.caption, row.caption);

      // Rules that follow from the table.
      final List<String> labels = <String>[
        for (final CardAction a in view.actions) a.label,
      ];
      expect(
        view.actions
            .where((CardAction a) => a.kind == CardActionKind.primary)
            .length,
        lessThanOrEqualTo(1),
        reason: 'at most one primary action (Pause is a TextButton)',
      );
      expect(
        labels.contains('Connect') && labels.contains('Disconnect'),
        isFalse,
      );
      expect(labels, isNot(contains('Reconnect')));
      for (final CardAction a in view.actions) {
        if (!a.enabled)
          expect(
            view.caption,
            isNotNull,
            reason: 'a disabled action needs a caption',
          );
        if (a.label == 'Pause') expect(a.kind, CardActionKind.secondary);
      }
    });
  }
}
