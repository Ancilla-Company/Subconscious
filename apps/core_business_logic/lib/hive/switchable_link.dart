import 'dart:async';

import 'channel_codec.dart';
import 'peer_link.dart';

/// A [PeerLink] whose underlying link can be replaced while consumers
/// (`PeerEngineSocket`, `DataChannelHttpClient`) keep their reference.
///
/// Used for the relay to direct upgrade: sends go to the newest link at once;
/// the previous link stays open for [grace] so in-flight responses still
/// arrive, then it is closed.
final class SwitchablePeerLink implements PeerLink {
  SwitchablePeerLink(
    PeerLink initial, {
    this.grace = const Duration(seconds: 5),
  }) : _current = initial {
    _attach(initial);
  }

  final Duration grace;
  PeerLink _current;
  final List<PeerLink> _attached = <PeerLink>[];
  final Map<PeerLink, StreamSubscription<InboundEnvelope>> _subscriptions =
      <PeerLink, StreamSubscription<InboundEnvelope>>{};
  final StreamController<InboundEnvelope> _inbound =
      StreamController<InboundEnvelope>.broadcast();
  final Completer<void> _done = Completer<void>();
  bool _closed = false;

  /// The link currently used for sending.
  PeerLink get current => _current;

  @override
  String get remoteNodeId => _current.remoteNodeId;
  @override
  String get tier => _current.tier;
  @override
  bool get isOpen => !_closed && _current.isOpen;
  @override
  Stream<InboundEnvelope> get envelopes => _inbound.stream;
  @override
  Future<void> get done => _done.future;

  void _attach(PeerLink link) {
    _attached.add(link);
    _subscriptions[link] = link.envelopes.listen((InboundEnvelope e) {
      if (!_closed && !_inbound.isClosed) _inbound.add(e);
    });
    unawaited(
      link.done.then<void>((_) {
        if (identical(link, _current)) _finish();
        _detach(link);
      }),
    );
  }

  void _detach(PeerLink link) {
    _attached.remove(link);
    final StreamSubscription<InboundEnvelope>? sub = _subscriptions.remove(link);
    if (sub != null) unawaited(sub.cancel());
  }

  /// Makes [next] the sending link and retires the previous one after [grace].
  void swap(PeerLink next) {
    if (_closed || identical(next, _current)) return;
    final PeerLink previous = _current;
    _attach(next);
    _current = next;
    unawaited(
      Future<void>.delayed(grace).then<void>((_) => previous.close()),
    );
  }

  @override
  Future<void> send(String channel, Envelope envelope) {
    if (_closed) {
      return Future<void>.error(const ChannelException('The peer link is closed.'));
    }
    return _current.send(channel, envelope);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    final List<PeerLink> links = List<PeerLink>.of(_attached);
    _finish();
    for (final PeerLink link in links) {
      try {
        await link.close();
      } on Object {
        // Already closed.
      }
    }
  }

  void _finish() {
    if (_closed) return;
    _closed = true;
    if (!_done.isCompleted) _done.complete();
    unawaited(_inbound.close());
  }
}
