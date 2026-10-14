import 'dart:async';
import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'peer_connector_test.dart' show until;

/// A [PeerLink] backed directly by test streams.
final class FakeLink implements PeerLink {
  final StreamController<InboundEnvelope> inbound =
      StreamController<InboundEnvelope>.broadcast();
  final List<(String, Envelope)> sent = <(String, Envelope)>[];
  final Completer<void> _done = Completer<void>();
  bool open = true;
  void Function(String channel, Envelope e)? onSend;

  @override
  String get remoteNodeId => 'n_engine';
  @override
  String get tier => 'direct';
  @override
  bool get isOpen => open;
  @override
  Stream<InboundEnvelope> get envelopes => inbound.stream;
  @override
  Future<void> get done => _done.future;

  @override
  Future<void> send(String channel, Envelope envelope) async {
    sent.add((channel, envelope));
    onSend?.call(channel, envelope);
  }

  @override
  Future<void> close() async {
    open = false;
    if (!_done.isCompleted) _done.complete();
  }

  void receive(String channel, Envelope e) => inbound.add(InboundEnvelope(channel, e));
}

void main() {
  group('PeerEngineSocket', () {
    test('handshakes with client.hello and relays frames', () async {
      final FakeLink link = FakeLink();
      link.onSend = (String channel, Envelope e) {
        if (e.type == 'client.hello') {
          Future<void>.microtask(
            () => link.receive('control', Envelope(type: 'client.hello.ack', id: e.id, data: const <String, dynamic>{})),
          );
        }
      };
      final PeerEngineSocket socket = PeerEngineSocket(linkProvider: () async => link);
      expect(socket.isConnected, isFalse);
      await socket.connect();
      expect(socket.isConnected, isTrue);
      expect(link.sent.first.$1, 'control');
      expect(link.sent.first.$2.type, 'client.hello');

      final List<WireFrame> frames = <WireFrame>[];
      socket.frames.listen(frames.add);
      link.receive('events', Envelope(type: 'chat.delta', id: 't1', data: const <String, dynamic>{'delta': 'hi'}));
      link.receive('rpc', Envelope(type: 'http.response', id: 'h-0', data: const <String, dynamic>{}));
      await until(() => frames.isNotEmpty);
      expect(frames.single.type, 'chat.delta');
      expect(frames.single.id, 't1');
      expect(frames.single.data!['delta'], 'hi');

      final String turn = socket.sendChat(content: 'hello', workspaceUuid: 'w1');
      final (String, Envelope) chat = link.sent.last;
      expect(chat.$1, 'control');
      expect(chat.$2.type, 'chat.send');
      expect(chat.$2.id, turn);
      expect(chat.$2.dataMap, <String, dynamic>{'content': 'hello', 'workspace_uuid': 'w1'});
      expect(() => socket.sendChat(content: 'x'), throwsArgumentError);

      socket.cancelChat(turn);
      expect(link.sent.last.$2.type, 'chat.cancel');
      socket.respondToolApproval(turnId: turn, approvalId: 'a', approved: true);
      expect(link.sent.last.$2.dataMap!['decision'], 'approve');

      await socket.close();
      expect(socket.isConnected, isFalse);
      expect(link.isOpen, isTrue, reason: 'the shared link is not closed by the socket');
      await socket.dispose();
    });

    test('a rejected hello fails connect', () async {
      final FakeLink link = FakeLink();
      link.onSend = (String c, Envelope e) {
        Future<void>.microtask(
          () => link.receive('control', Envelope(type: 'client.hello.reject', data: const <String, dynamic>{'reason': 'nope'})),
        );
      };
      final PeerEngineSocket socket = PeerEngineSocket(linkProvider: () async => link);
      await expectLater(socket.connect(), throwsA(isA<StateError>()));
      expect(socket.isConnected, isFalse);
    });

    test('hello times out', () async {
      final PeerEngineSocket socket = PeerEngineSocket(
        linkProvider: () async => FakeLink(),
        helloTimeout: const Duration(milliseconds: 30),
      );
      await expectLater(socket.connect(), throwsA(isA<TimeoutException>()));
    });

    test('send before connect throws', () {
      final PeerEngineSocket socket = PeerEngineSocket(linkProvider: () async => FakeLink());
      expect(() => socket.send(type: 'ping'), throwsStateError);
    });

    test('works as the EngineRepository socket', () async {
      final FakeLink link = FakeLink();
      link.onSend = (String c, Envelope e) {
        Future<void>.microtask(() {
          if (e.type == 'client.hello') {
            link.receive('control', Envelope(type: 'client.hello.ack', data: const <String, dynamic>{}));
          } else if (e.type == 'chat.send') {
            link.receive('events', Envelope(type: 'chat.delta', id: e.id, data: const <String, dynamic>{'delta': 'A'}));
            link.receive('events', Envelope(type: 'chat.delta', id: e.id, data: const <String, dynamic>{'delta': 'B'}));
            link.receive('control', Envelope(type: 'chat.done', id: e.id, data: const <String, dynamic>{}));
          }
        });
      };
      final EngineRepository repository = EngineRepository(
        rest: RestEngineClient(baseUri: Uri.parse('http://peer/api/v1/'), token: ''),
        socket: PeerEngineSocket(linkProvider: () async => link),
      );
      await repository.connect();
      final List<String> parts = await repository.streamChat(content: 'q', workspaceUuid: 'w').toList();
      expect(parts, <String>['A', 'B']);
    });
  });

  group('DataChannelHttpClient', () {
    test('tunnels a request over rpc and decodes the response', () async {
      final FakeLink link = FakeLink();
      link.onSend = (String channel, Envelope e) {
        final Map<String, dynamic> d = e.dataMap!;
        Future<void>.microtask(
          () => link.receive(
            'rpc',
            Envelope(
              type: 'http.response',
              id: e.id,
              data: <String, dynamic>{
                'status': 201,
                'headers': <String, dynamic>{'content-type': 'application/json', 'ETag': 'x'},
                'body': base64.encode(utf8.encode(jsonEncode(<String, dynamic>{'echo': d['path']}))),
              },
            ),
          ),
        );
      };
      final DataChannelHttpClient client = DataChannelHttpClient(link: link);
      final RestEngineClient rest = RestEngineClient(
        baseUri: Uri.parse('http://peer/api/v1/'),
        token: 'ignored',
        client: client,
      );
      await expectLater(rest.listWorkspaces(), throwsA(isA<FormatException>())); // object, not array

      final (String, Envelope) sent = link.sent.first;
      expect(sent.$1, 'rpc');
      expect(sent.$2.type, 'http.request');
      final Map<String, dynamic> data = sent.$2.dataMap!;
      expect(data['method'], 'GET');
      expect(data['path'], '/api/v1/workspaces');
      // Only allowlisted headers travel; the bearer never does.
      expect((data['headers'] as Map).keys, isNot(contains('authorization')));
      expect(data.containsKey('body'), isFalse);
      client.close();
    });

    test('sends JSON bodies base64 encoded with query params', () async {
      final FakeLink link = FakeLink();
      link.onSend = (String channel, Envelope e) => Future<void>.microtask(
        () => link.receive(
          'rpc',
          Envelope(
            type: 'http.response',
            id: e.id,
            data: <String, dynamic>{
              'status': 200,
              'headers': <String, dynamic>{},
              'body': base64.encode(utf8.encode('[]')),
            },
          ),
        ),
      );
      final DataChannelHttpClient client = DataChannelHttpClient(link: link);
      final http.Request request = http.Request('POST', Uri.parse('http://peer/api/v1/messages?x=1'))
        ..headers['Content-Type'] = 'application/json'
        ..headers['Authorization'] = 'Bearer secret'
        ..body = '{"a":1}';
      final http.StreamedResponse response = await client.send(request);
      expect(response.statusCode, 200);
      expect(await response.stream.bytesToString(), '[]');
      final Map<String, dynamic> data = link.sent.single.$2.dataMap!;
      expect(data['query'], <String, dynamic>{'x': '1'});
      expect(utf8.decode(base64.decode(data['body'] as String)), '{"a":1}');
      expect((data['headers'] as Map)['content-type'], 'application/json');
      expect((data['headers'] as Map).containsKey('authorization'), isFalse);
      client.close();
    });

    test('times out and fails pending calls when the link closes', () async {
      final FakeLink link = FakeLink();
      final DataChannelHttpClient client = DataChannelHttpClient(
        link: link,
        timeout: const Duration(milliseconds: 40),
      );
      await expectLater(
        client.get(Uri.parse('http://peer/api/v1/models')),
        throwsA(isA<http.ClientException>()),
      );
      final Future<http.Response> pending = client.get(Uri.parse('http://peer/api/v1/models'));
      final Future<void> expectation = expectLater(pending, throwsA(isA<http.ClientException>()));
      await until(() => link.sent.length == 2);
      await link.close();
      await expectation;
      await expectLater(
        client.get(Uri.parse('http://peer/api/v1/models')),
        throwsA(isA<http.ClientException>()),
      );
      client.close();
    });

    test('engine error responses surface as EngineApiException', () async {
      final FakeLink link = FakeLink();
      link.onSend = (String channel, Envelope e) => Future<void>.microtask(
        () => link.receive(
          'rpc',
          Envelope(
            type: 'http.response',
            id: e.id,
            data: <String, dynamic>{
              'status': 403,
              'headers': <String, dynamic>{'content-type': 'application/json'},
              'body': base64.encode(utf8.encode('{"error":"Forbidden for this node."}')),
            },
          ),
        ),
      );
      final DataChannelHttpClient client = DataChannelHttpClient(link: link);
      final RestEngineClient rest = RestEngineClient(baseUri: Uri.parse('http://peer/api/v1/'), token: '', client: client);
      await expectLater(
        rest.listModels(),
        throwsA(isA<EngineApiException>().having((EngineApiException e) => e.statusCode, 'status', 403)),
      );
      client.close();
    });
  });
}
