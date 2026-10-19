import 'dart:typed_data';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:test/test.dart';

DirectoryNode node(String id, {bool online = false, String? parent, List<String> clients = const <String>[]}) =>
    DirectoryNode(
      id: id,
      kind: 'engine',
      name: id,
      platform: 'windows',
      appVersion: '',
      publicKey: Uint8List(32),
      status: 'active',
      online: online,
      parentNodeId: parent,
      clients: clients,
    );

void main() {
  test('a REST answer older than a push does not revert online', () {
    final PresenceBook book = PresenceBook();
    final int start = book.beginRequest();
    book.applyFrame(<String, dynamic>{'node_id': 'n_a', 'online': true});
    book.mergeRest(start, <DirectoryNode>[node('n_a', online: false)]);
    expect(book.onlineOf('n_a', false), isTrue);
  });

  test('a REST answer newer than a push wins', () {
    final PresenceBook book = PresenceBook();
    book.applyFrame(<String, dynamic>{'node_id': 'n_a', 'online': true});
    final int start = book.beginRequest();
    book.mergeRest(start, <DirectoryNode>[node('n_a', online: false)]);
    expect(book.onlineOf('n_a', false), isFalse);
  });

  test('a snapshot replaces everything pushed before it', () {
    final PresenceBook book = PresenceBook();
    book.applyFrame(<String, dynamic>{'node_id': 'n_a', 'online': true});
    book.applySnapshot(<Object?>[
      <String, dynamic>{'node_id': 'n_b', 'online': true},
    ]);
    expect(book.onlineOf('n_a', false), isFalse);
    expect(book.onlineOf('n_b', false), isTrue);
  });

  test('parent and clients default to the REST values when not pushed', () {
    final PresenceBook book = PresenceBook();
    expect(book.parentOf('n_a', 'n_p'), 'n_p');
    expect(book.clientsOf('n_a', <String>['x']), <String>['x']);
    book.applyFrame(<String, dynamic>{'node_id': 'n_a', 'online': true});
    expect(book.parentOf('n_a', 'n_p'), 'n_p');
    expect(book.clientsOf('n_a', <String>['x']), <String>['x']);
  });

  test('pushed parent (including a cleared parent) and clients win', () {
    final PresenceBook book = PresenceBook();
    book.applyFrame(<String, dynamic>{
      'node_id': 'n_a',
      'online': true,
      'parent_node_id': 'n_e',
      'clients': <String>['ui'],
    });
    expect(book.parentOf('n_a', null), 'n_e');
    expect(book.clientsOf('n_a', const <String>[]), <String>['ui']);
    book.applyFrame(<String, dynamic>{'node_id': 'n_a', 'online': true, 'parent_node_id': null});
    expect(book.parentOf('n_a', 'n_e'), isNull);
  });

  test('malformed frames are ignored', () {
    final PresenceBook book = PresenceBook();
    book.applyFrame('nope');
    book.applyFrame(<String, dynamic>{'online': true});
    expect(book.knows('n_a'), isFalse);
  });

  test('DirectoryNode parses parent_node_id and clients, defaulting when absent', () {
    final DirectoryNode? parsed = DirectoryNode.tryParse(<String, dynamic>{
      'id': 'x',
      'public_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      'kind': 'thin',
      'parent_node_id': 'n_e',
      'clients': <Object?>['a', 3, 'b'],
    });
    expect(parsed, isNotNull);
    expect(parsed!.parentNodeId, 'n_e');
    expect(parsed.clients, <String>['a', 'b']);
    final DirectoryNode? plain = DirectoryNode.tryParse(<String, dynamic>{
      'id': 'x',
      'public_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    });
    expect(plain!.parentNodeId, isNull);
    expect(plain.clients, isEmpty);
  });
}
