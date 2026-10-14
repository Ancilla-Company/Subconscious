import 'dart:async';
import 'dart:typed_data';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:test/test.dart';

import 'fakes.dart';

Future<void> until(bool Function() condition) async {
  for (int i = 0; i < 600 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: 'condition not reached in time');
}

/// One relay frame in flight.
final class Frame {
  Frame(this.from, this.to, this.sid, this.bytes);
  final String from;
  final String to;
  final String sid;
  Uint8List bytes;
}

/// In-memory signalling hub: delivers `relay` frames between managers.
final class Hub {
  final Map<String, RelayManager> managers = <String, RelayManager>{};
  final List<Frame> log = <Frame>[];

  /// Return the frames to deliver instead of [frame] (empty drops it).
  List<Frame> Function(Frame frame)? interceptor;

  RelaySender senderFor(String fromId) => _Sender(this, fromId);

  /// Registers [manager] as the receiver for node id [id].
  void attach(String id, RelayManager manager) => managers[id] = manager;

  void deliver(Frame frame) {
    final RelayManager? target = managers[frame.to];
    if (target == null) return;
    unawaited(
      Future<void>(
        () => target.handleRelay(<String, dynamic>{
          'from': frame.from,
          'sid': frame.sid,
          'payload': b64uEncode(frame.bytes),
        }),
      ),
    );
  }
}

final class _Sender implements RelaySender {
  _Sender(this.hub, this.fromId);
  final Hub hub;
  final String fromId;

  @override
  Future<void> sendRelay({
    required String sid,
    required String to,
    required Object payload,
  }) async {
    final Frame frame = Frame(fromId, to, sid, b64uDecode(payload as String));
    hub.log.add(frame);
    final List<Frame> out = hub.interceptor?.call(frame) ?? <Frame>[frame];
    out.forEach(hub.deliver);
  }
}

final class Pair {
  late NodeIdentity a;
  late NodeIdentity b;
  late NodeDirectory dirA;
  late NodeDirectory dirB;
  late RelayManager ma;
  late RelayManager mb;
  final Hub hub = Hub();

  static Future<Pair> create({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final Pair p = Pair();
    p.a = await seededIdentity(1);
    p.b = await seededIdentity(60);
    final List<Object?> nodes = <Object?>[
      nodeJson(p.a, name: 'A'),
      nodeJson(
        p.b,
        kind: 'thin',
        name: 'B',
        approvedBy: p.a.nodeId,
        approvalSig: await p.a.sign(approvalMessage('u1', p.b.publicKeyB64u)),
      ),
    ];
    p.dirA = NodeDirectory(userId: 'u1', localNodeId: p.a.nodeId);
    p.dirB = NodeDirectory(userId: 'u1', localNodeId: p.b.nodeId);
    await p.dirA.update(nodes);
    await p.dirB.update(nodes);
    p.ma = RelayManager(
      identity: p.a,
      directory: p.dirA,
      sender: p.hub.senderFor(p.a.nodeId),
      handshakeTimeout: timeout,
    );
    p.mb = RelayManager(
      identity: p.b,
      directory: p.dirB,
      sender: p.hub.senderFor(p.b.nodeId),
      handshakeTimeout: timeout,
    );
    p.hub.attach(p.a.nodeId, p.ma);
    p.hub.attach(p.b.nodeId, p.mb);
    return p;
  }

  RelayManager get lower => a.nodeId.compareTo(b.nodeId) < 0 ? ma : mb;
}

/// Sets up a link A -> B and returns both ends.
Future<(RelayLink, RelayLink)> established(Pair p) async {
  final Future<RelayLink> accepted = p.mb.linkOpened.first;
  final RelayLink initiator = await p.ma.connect(p.b.nodeId);
  final RelayLink responder = await accepted;
  return (initiator, responder);
}

Envelope env(String type, [Object? data, String? id]) =>
    Envelope(type: type, data: data, id: id);

void main() {
  group('relay handshake and data', () {
    test('mutual authentication, ws-relay tier and an encrypted round trip', () async {
      final Pair p = await Pair.create();
      final (RelayLink i, RelayLink r) = await established(p);
      expect(i.tier, 'ws-relay');
      expect(r.tier, 'ws-relay');
      expect(i.remoteNodeId, p.b.nodeId);
      expect(r.remoteNodeId, p.a.nodeId);

      final List<InboundEnvelope> atB = <InboundEnvelope>[];
      final List<InboundEnvelope> atA = <InboundEnvelope>[];
      r.envelopes.listen(atB.add);
      i.envelopes.listen(atA.add);
      await i.send('rpc', env('http.request', <String, dynamic>{'path': '/x'}, 'h-1'));
      await r.send('events', env('chat.delta', <String, dynamic>{'delta': 'hi'}, 't1'));
      await until(() => atB.isNotEmpty && atA.isNotEmpty);
      expect(atB.single.channel, 'rpc');
      expect(atB.single.envelope.type, 'http.request');
      expect(atB.single.envelope.id, 'h-1');
      expect(atB.single.envelope.src, p.a.nodeId);
      expect(atA.single.channel, 'events');
      expect(atA.single.envelope.dataMap!['delta'], 'hi');

      // The server only ever sees the 0x01/0x02/0x03 handshake and 0x10 records.
      final Set<int> types = p.hub.log.map((Frame f) => f.bytes[0]).toSet();
      expect(types, <int>{0x01, 0x02, 0x03, 0x10});
      final Frame data = p.hub.log.firstWhere((Frame f) => f.bytes[0] == 0x10);
      expect(String.fromCharCodes(data.bytes), isNot(contains('http.request')));
    });

    test('large envelopes are chunked and each record stays under 24 KiB', () async {
      final Pair p = await Pair.create();
      final (RelayLink i, RelayLink r) = await established(p);
      final List<InboundEnvelope> atB = <InboundEnvelope>[];
      r.envelopes.listen(atB.add);
      final String big = 'x' * 70000;
      await i.send('sync', env('sync.batch', <String, dynamic>{'blob': big}, 'b1'));
      await until(() => atB.isNotEmpty);
      expect(atB.single.envelope.dataMap!['blob'], big);
      final Iterable<Frame> records = p.hub.log.where((Frame f) => f.bytes[0] == 0x10);
      expect(records.length, greaterThan(4));
      expect(records.every((Frame f) => f.bytes.length <= relayRawLimit), isTrue);
    });

    test('a tampered responder signature (M2) fails the attempt', () async {
      final Pair p = await Pair.create();
      p.hub.interceptor = (Frame f) {
        if (f.bytes[0] == 0x02) f.bytes[f.bytes.length - 1] ^= 1;
        return <Frame>[f];
      };
      await expectLater(p.ma.connect(p.b.nodeId), throwsA(isA<RelayException>()));
      expect(p.ma.linkFor(p.b.nodeId), isNull);
    });

    test('a tampered initiator signature (M3) never opens the responder link', () async {
      final Pair p = await Pair.create();
      p.hub.interceptor = (Frame f) {
        if (f.bytes[0] == 0x03) f.bytes[f.bytes.length - 1] ^= 1;
        return <Frame>[f];
      };
      final RelayLink i = await p.ma.connect(p.b.nodeId);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(p.mb.linkFor(p.a.nodeId), isNull);
      // Data from the initiator is dropped: the responder has no session.
      await i.send('rpc', env('http.request', null, 'x'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(p.mb.linkFor(p.a.nodeId), isNull);
    });

    test('a responder holding the wrong key is rejected', () async {
      final Pair p = await Pair.create();
      final NodeIdentity evil = await seededIdentity(120);
      final NodeDirectory dirEvil = NodeDirectory(userId: 'u1', localNodeId: evil.nodeId);
      await dirEvil.update(<Object?>[
        nodeJson(p.a, name: 'A'),
        nodeJson(
          evil,
          kind: 'thin',
          approvedBy: p.a.nodeId,
          approvalSig: await p.a.sign(approvalMessage('u1', evil.publicKeyB64u)),
        ),
      ]);
      // The impostor answers frames addressed to B, signing with its own key.
      final Hub impostorHub = Hub();
      final RelayManager me = RelayManager(
        identity: evil,
        directory: dirEvil,
        sender: _Impersonator(p.hub, p.b.nodeId, p.a.nodeId),
      );
      impostorHub.attach(p.a.nodeId, p.ma);
      p.hub.managers[p.b.nodeId] = me;
      await expectLater(p.ma.connect(p.b.nodeId), throwsA(isA<RelayException>()));
    });

    test('a replayed data record is dropped', () async {
      final Pair p = await Pair.create();
      final (RelayLink i, RelayLink r) = await established(p);
      final List<InboundEnvelope> atB = <InboundEnvelope>[];
      r.envelopes.listen(atB.add);
      await i.send('rpc', env('http.request', null, 'one'));
      await until(() => atB.length == 1);
      final Frame record = p.hub.log.lastWhere((Frame f) => f.bytes[0] == 0x10);
      p.hub.deliver(Frame(record.from, record.to, record.sid, Uint8List.fromList(record.bytes)));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(atB.length, 1);
      expect(r.isOpen, isTrue);
    });

    test('a reordered record (older counter after newer) is dropped', () async {
      final Pair p = await Pair.create();
      final (RelayLink i, RelayLink r) = await established(p);
      final List<Frame> held = <Frame>[];
      p.hub.interceptor = (Frame f) {
        if (f.bytes[0] == 0x10) {
          held.add(f);
          return <Frame>[];
        }
        return <Frame>[f];
      };
      final List<String> ids = <String>[];
      r.envelopes.listen((InboundEnvelope e) => ids.add(e.envelope.id!));
      await i.send('rpc', env('http.request', null, 'first'));
      await i.send('rpc', env('http.request', null, 'second'));
      expect(held.length, 2);
      p.hub.deliver(held[1]);
      await until(() => ids.length == 1);
      p.hub.deliver(held[0]);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(ids, <String>['second']);
    });

    test('five consecutive authentication failures close the link', () async {
      final Pair p = await Pair.create();
      final (RelayLink i, RelayLink r) = await established(p);
      p.hub.interceptor = (Frame f) {
        if (f.bytes[0] == 0x10) f.bytes[f.bytes.length - 1] ^= 1;
        return <Frame>[f];
      };
      for (int n = 0; n < 5; n++) {
        await i.send('rpc', env('http.request', null, 'm$n'));
      }
      await until(() => !r.isOpen);
      await r.done;
    });

    test('a good record resets the consecutive failure count', () async {
      final Pair p = await Pair.create();
      final (RelayLink i, RelayLink r) = await established(p);
      final List<InboundEnvelope> atB = <InboundEnvelope>[];
      r.envelopes.listen(atB.add);
      // 4 failures then a good record resets the counter.
      final int saved = p.hub.log.length;
      p.hub.interceptor = (Frame f) {
        if (f.bytes[0] == 0x10 && p.hub.log.length - saved <= 4) {
          f.bytes[f.bytes.length - 1] ^= 1;
        }
        return <Frame>[f];
      };
      for (int n = 0; n < 5; n++) {
        await i.send('rpc', env('http.request', null, 'm$n'));
      }
      await until(() => atB.length == 1);
      expect(r.isOpen, isTrue);
      expect(i.isOpen, isTrue);
    });

    test('simultaneous initiators converge on one link (lower id wins)', () async {
      final Pair p = await Pair.create();
      final Future<RelayLink> fa = p.ma.connect(p.b.nodeId);
      final Future<RelayLink> fb = p.mb.connect(p.a.nodeId);
      final List<RelayLink> links = await Future.wait(<Future<RelayLink>>[fa, fb]);
      final List<Frame> m1s = p.hub.log.where((Frame f) => f.bytes[0] == 0x01).toList();
      expect(m1s.length, 2, reason: 'both started');
      // The lower id kept its attempt: exactly one handshake completed (one M3).
      expect(p.hub.log.where((Frame f) => f.bytes[0] == 0x03).length, 1);
      final String lowerId = p.a.nodeId.compareTo(p.b.nodeId) < 0 ? p.a.nodeId : p.b.nodeId;
      final Frame m3 = p.hub.log.firstWhere((Frame f) => f.bytes[0] == 0x03);
      expect(m3.from, lowerId, reason: 'the winner finishes as initiator');

      final List<InboundEnvelope> atB = <InboundEnvelope>[];
      links[1].envelopes.listen(atB.add);
      await links[0].send('rpc', env('http.request', null, 'ping'));
      await until(() => atB.isNotEmpty);
      expect(atB.single.envelope.id, 'ping');
    });

    test('the handshake is abandoned after the timeout', () async {
      final Pair p = await Pair.create(timeout: const Duration(milliseconds: 60));
      p.hub.interceptor = (Frame f) => <Frame>[];
      await expectLater(p.ma.connect(p.b.nodeId), throwsA(isA<RelayException>()));
    });

    test('frames from an untrusted node are ignored', () async {
      final Pair p = await Pair.create();
      final NodeIdentity stranger = await seededIdentity(200);
      final List<RelayLink> opened = <RelayLink>[];
      p.mb.linkOpened.listen(opened.add);
      await p.mb.handleRelay(<String, dynamic>{
        'from': stranger.nodeId,
        'sid': '1.abc',
        'payload': b64uEncode(Uint8List(49)..[0] = 0x01),
      });
      expect(opened, isEmpty);
      expect(p.hub.log, isEmpty);
    });

    test('a duplicate sid is not accepted twice', () async {
      final Pair p = await Pair.create();
      final (RelayLink _, RelayLink _) = await established(p);
      final Frame m1 = p.hub.log.firstWhere((Frame f) => f.bytes[0] == 0x01);
      final int before = p.hub.log.length;
      p.hub.deliver(m1);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(p.hub.log.length, before, reason: 'no new M2 for a repeated M1');
    });

    test('close sends a close record and ends the peer link', () async {
      final Pair p = await Pair.create();
      final (RelayLink i, RelayLink r) = await established(p);
      await i.close();
      await until(() => !r.isOpen);
      expect(i.isOpen, isFalse);
    });
  });

  group('relay primitives', () {
    test('counters are 8 bytes big endian and bounded to 2^32', () {
      expect(relayCounterBytes(1), <int>[0, 0, 0, 0, 0, 0, 0, 1]);
      expect(relayParseCounter(relayCounterBytes(4294967295)), 4294967295);
      expect(relayParseCounter(<int>[0, 0, 0, 1, 0, 0, 0, 0]), isNull);
    });
  });
}

/// Delivers frames from an impostor as if the server stamped `from: asNode`.
final class _Impersonator implements RelaySender {
  _Impersonator(this.hub, this.asNode, this.target);
  final Hub hub;
  final String asNode;
  final String target;
  @override
  Future<void> sendRelay({
    required String sid,
    required String to,
    required Object payload,
  }) async {
    hub.deliver(Frame(asNode, target, sid, b64uDecode(payload as String)));
  }
}
