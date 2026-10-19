import 'directory.dart';

/// Live presence from the signalling socket, merged with `GET /nodes`.
///
/// Pushed frames and REST answers race. Every push gets a sequence number and
/// [beginRequest] records the sequence a REST request started at. A REST
/// answer then only overrides pushes older than its start, so a slow answer
/// can never flip a node back to a stale state (AC-18).
final class PresenceBook {
  int _sequence = 0;
  final Map<String, _Pushed> _pushed = <String, _Pushed>{};

  /// Applies one `presence.update` frame (or one snapshot row).
  void applyFrame(Object? raw) {
    if (raw is! Map || raw['node_id'] is! String) return;
    final Object? clients = raw['clients'];
    _pushed[raw['node_id'] as String] = _Pushed(
      sequence: ++_sequence,
      online: raw['online'] == true,
      clients: clients is List
          ? <String>[
              for (final Object? c in clients)
                if (c is String) c,
            ]
          : null,
      hasParent: raw.containsKey('parent_node_id'),
      parent: raw['parent_node_id'] is String
          ? raw['parent_node_id'] as String
          : null,
    );
  }

  /// A snapshot is the full truth: forget everything pushed before it.
  void applySnapshot(Iterable<Object?> nodes) {
    _pushed.clear();
    for (final Object? node in nodes) {
      applyFrame(node);
    }
  }

  /// Call right before sending a REST request; pass the result to [mergeRest].
  int beginRequest() => _sequence;

  /// Drops pushed values that the REST answer (started at [startSequence]) is
  /// newer than. Pushes that arrived after the request started stay.
  void mergeRest(int startSequence, Iterable<DirectoryNode> nodes) {
    for (final DirectoryNode node in nodes) {
      final _Pushed? pushed = _pushed[node.id];
      if (pushed != null && pushed.sequence <= startSequence) {
        _pushed.remove(node.id);
      }
    }
  }

  void clear() => _pushed.clear();

  bool onlineOf(String id, bool restOnline) => _pushed[id]?.online ?? restOnline;

  List<String> clientsOf(String id, List<String> restClients) =>
      _pushed[id]?.clients ?? restClients;

  String? parentOf(String id, String? restParent) {
    final _Pushed? pushed = _pushed[id];
    if (pushed == null || !pushed.hasParent) return restParent;
    return pushed.parent;
  }

  /// True when a pushed frame names a node the REST directory lacks.
  bool knows(String id) => _pushed.containsKey(id);
}

final class _Pushed {
  const _Pushed({
    required this.sequence,
    required this.online,
    required this.clients,
    required this.hasParent,
    required this.parent,
  });
  final int sequence;
  final bool online;
  final List<String>? clients;
  final bool hasParent;
  final String? parent;
}
