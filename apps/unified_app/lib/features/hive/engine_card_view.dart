import 'package:core_business_logic/core_business_logic.dart';

import 'hive_runtime.dart';

/// What a card button does. The widget maps these to the runtime:
/// [connect] and [retry] call `reconnectEngine`; [disconnect], [cancel] and
/// [pause] call `disconnectEngine`.
enum CardCommand { connect, disconnect, cancel, retry, pause }

enum CardActionKind {
  /// A `FilledButton` or `OutlinedButton`. At most one per card.
  primary,

  /// A `TextButton`.
  secondary,
}

final class CardAction {
  const CardAction(this.label, this.kind, this.command, {this.enabled = true});
  final String label;
  final CardActionKind kind;
  final CardCommand command;
  final bool enabled;
}

final class EngineCardView {
  const EngineCardView({
    required this.title,
    required this.detail,
    required this.showProgress,
    required this.actions,
    this.caption,
  });
  final String title;
  final String detail;
  final bool showProgress;
  final List<CardAction> actions;

  /// Why a disabled action is disabled. Set whenever one is.
  final String? caption;

  /// True while the card says the app is (re)connecting, for the caption chip.
  bool get isConnecting => showProgress;
}

/// The card view for the runtime's current state.
EngineCardView engineCardViewFor(HiveRuntime runtime) => buildEngineCardView(
  engineState: runtime.engineState,
  autoConnect: runtime.autoConnect,
  choice: runtime.engineChoice.kind,
  hasCandidates: runtime.connectableEngines.isNotEmpty,
  inHysteresis: runtime.inEngineHysteresis,
  connectedName: runtime.connectedEngineName,
);

const String _noEngineCaption = 'No engine is online.';
const String _noEngineWaitCaption =
    'No engine is online. This device connects as soon as one appears.';

/// The 14-row button matrix (design 5.5 with the Section 11.1 amendments).
///
/// [hasCandidates] is whether a trusted, online, remote engine exists.
/// [choice] is what `chooseEngine` decided. [inHysteresis] is true for the
/// grace window after the last online engine disappeared.
EngineCardView buildEngineCardView({
  required EngineLinkState engineState,
  required bool autoConnect,
  required EngineChoiceKind choice,
  required bool hasCandidates,
  required bool inHysteresis,
  String? connectedName,
}) {
  const CardAction cancel = CardAction(
    'Cancel',
    CardActionKind.primary,
    CardCommand.cancel,
  );
  const CardAction pause = CardAction(
    'Pause',
    CardActionKind.secondary,
    CardCommand.pause,
  );
  CardAction connect({required bool enabled}) => CardAction(
    'Connect',
    CardActionKind.primary,
    CardCommand.connect,
    enabled: enabled,
  );

  switch (engineState) {
    case EngineLinkState.connected:
      return EngineCardView(
        title: 'Connected to ${connectedName ?? 'engine'}',
        detail: connectedName == null
            ? 'Tasks run on the connected engine by default.'
            : 'Tasks run on $connectedName by default.',
        showProgress: false,
        actions: const <CardAction>[
          CardAction(
            'Disconnect',
            CardActionKind.primary,
            CardCommand.disconnect,
          ),
        ],
      );
    case EngineLinkState.connecting:
      return const EngineCardView(
        title: 'Connecting to engine...',
        detail: 'Setting up a secure link.',
        showProgress: true,
        actions: <CardAction>[cancel],
      );
    case EngineLinkState.failed:
      if (autoConnect) {
        if (hasCandidates) {
          return const EngineCardView(
            title: 'Could not reach the engine',
            detail: 'Trying again automatically.',
            showProgress: false,
            actions: <CardAction>[
              CardAction('Retry', CardActionKind.primary, CardCommand.retry),
              pause,
            ],
          );
        }
        return EngineCardView(
          title: 'Could not reach the engine',
          detail: 'Trying again automatically.',
          showProgress: false,
          actions: <CardAction>[connect(enabled: false), pause],
          caption: _noEngineCaption,
        );
      }
      return EngineCardView(
        title: 'Could not reach the engine',
        detail: 'Automatic connection is off. Press Connect to resume it.',
        showProgress: false,
        actions: <CardAction>[connect(enabled: hasCandidates)],
        caption: hasCandidates ? null : _noEngineCaption,
      );
    case EngineLinkState.disconnected:
      if (!autoConnect) {
        return EngineCardView(
          title: 'Not connected',
          detail: 'Automatic connection is off. Press Connect to resume it.',
          showProgress: false,
          actions: <CardAction>[connect(enabled: hasCandidates)],
          caption: hasCandidates ? null : _noEngineCaption,
        );
      }
      if (hasCandidates && choice == EngineChoiceKind.pick) {
        return const EngineCardView(
          title: 'Choose an engine',
          detail: 'Several engines are online. Pick one below to connect.',
          showProgress: false,
          actions: <CardAction>[pause],
        );
      }
      if (hasCandidates) {
        return const EngineCardView(
          title: 'Connecting to engine...',
          detail: 'Setting up a secure link.',
          showProgress: true,
          actions: <CardAction>[cancel],
        );
      }
      if (inHysteresis) {
        return const EngineCardView(
          title: 'Reconnecting to engine...',
          detail: 'The engine went quiet. Waiting a moment before giving up.',
          showProgress: true,
          actions: <CardAction>[cancel],
        );
      }
      return EngineCardView(
        title: 'No engine online',
        detail: 'Start Subconscious on your computer.',
        showProgress: false,
        actions: <CardAction>[connect(enabled: false)],
        caption: _noEngineWaitCaption,
      );
  }
}
