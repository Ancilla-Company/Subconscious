import 'dart:convert';

import 'package:core_business_logic/core_business_logic.dart';
import 'package:test/test.dart';

void main() {
  group('envelope codec', () {
    test('round trips with src and dst', () {
      const Envelope e = Envelope(
        type: 'chat.send',
        id: 'x1',
        data: <String, dynamic>{'content': 'hi'},
        src: 'n_a',
        dst: 'n_b',
      );
      final Envelope? back = decodeMessage(Reassembler(), encodeEnvelope(e));
      expect(back!.type, 'chat.send');
      expect(back.id, 'x1');
      expect(back.src, 'n_a');
      expect(back.dst, 'n_b');
      expect(back.dataMap, <String, dynamic>{'content': 'hi'});
    });

    test('rejects wrong version, missing type, binary and bad json', () {
      expect(() => decodeMessage(Reassembler(), '{"v":2,"type":"a"}'),
          throwsA(isA<ChannelException>()));
      expect(() => decodeMessage(Reassembler(), '{"v":1}'),
          throwsA(isA<ChannelException>()));
      expect(() => decodeMessage(Reassembler(), 'nope'),
          throwsA(isA<ChannelException>()));
      expect(() => decodeMessage(Reassembler(), <int>[1]),
          throwsA(isA<ChannelException>()));
    });

    test('rejects messages over 16 KiB that are not chunked', () {
      final String big = jsonEncode(<String, dynamic>{
        'v': 1,
        'type': 'x',
        'data': 'a' * 17000,
      });
      expect(() => decodeMessage(Reassembler(), big),
          throwsA(isA<ChannelException>()));
    });
  });

  group('chunking', () {
    test('small messages are not chunked', () {
      expect(splitMessage('{"v":1}'), <String>['{"v":1}']);
    });

    test('large messages split under 16 KiB and reassemble out of order', () {
      final String payload = 'é' * 40000; // multi-byte on purpose
      final String text = encodeEnvelope(
        Envelope(type: 'big', data: <String, dynamic>{'p': payload}),
      );
      final List<String> parts = splitMessage(text);
      expect(parts.length, greaterThan(2));
      for (final String p in parts) {
        expect(utf8.encode(p).length, lessThanOrEqualTo(maxMessageBytes));
      }
      final Reassembler r = Reassembler();
      Envelope? result;
      for (final String p in parts.reversed) {
        result = decodeMessage(r, p) ?? result;
      }
      expect(result!.dataMap!['p'], payload);
      expect(r.openStreams, 0);
    });

    test('accepts the Appendix A chunk shape', () {
      final String text = jsonEncode(<String, dynamic>{
        'v': 1,
        'type': 'x',
        'data': 'z' * 20000,
      });
      final List<int> raw = utf8.encode(text);
      final Reassembler r = Reassembler();
      final int n = (raw.length + 9999) ~/ 10000;
      String? full;
      for (int i = 0; i < n; i++) {
        full = r.feed(<String, dynamic>{
          'v': 1,
          'type': 'chunk',
          'id': 's1',
          'data': <String, dynamic>{
            'i': i,
            'n': n,
            'b64': base64.encode(raw.sublist(i * 10000, (i + 1) * 10000 > raw.length ? raw.length : (i + 1) * 10000)),
          },
        }) ?? full;
      }
      expect(full, text);
    });

    test('enforces the reassembly cap', () {
      final Reassembler r = Reassembler(maxBytes: 20000);
      final String piece = base64.encode(List<int>.filled(11000, 65));
      expect(
        () {
          r.feed(<String, dynamic>{'stream': 's', 'index': 0, 'total': 2, 'data': piece});
          r.feed(<String, dynamic>{'stream': 's', 'index': 1, 'total': 2, 'data': piece});
        },
        throwsA(isA<ChannelException>()),
      );
      expect(r.openStreams, 0);
    });

    test('rejects an oversized declared total', () {
      final Reassembler r = Reassembler();
      expect(
        () => r.feed(<String, dynamic>{
          'stream': 's',
          'index': 0,
          'total': 5000,
          'data': 'QQ==',
        }),
        throwsA(isA<ChannelException>()),
      );
    });

    test('drops incomplete streams after the timeout', () {
      DateTime now = DateTime(2025);
      final Reassembler r = Reassembler(
        timeout: const Duration(seconds: 30),
        clock: () => now,
      );
      r.feed(<String, dynamic>{'stream': 's', 'index': 0, 'total': 2, 'data': 'QQ=='});
      expect(r.openStreams, 1);
      now = now.add(const Duration(seconds: 31));
      expect(r.expire(), 1);
      expect(r.openStreams, 0);
    });

    test('rejects duplicates, bad base64 and too many streams', () {
      final Reassembler r = Reassembler(maxStreams: 2);
      r.feed(<String, dynamic>{'stream': 'a', 'index': 0, 'total': 2, 'data': 'QQ=='});
      expect(
        () => r.feed(<String, dynamic>{'stream': 'a', 'index': 0, 'total': 2, 'data': 'QQ=='}),
        throwsA(isA<ChannelException>()),
      );
      expect(
        () => r.feed(<String, dynamic>{'stream': 'b', 'index': 0, 'total': 2, 'data': '***'}),
        throwsA(isA<ChannelException>()),
      );
      r.feed(<String, dynamic>{'stream': 'c', 'index': 0, 'total': 2, 'data': 'QQ=='});
      r.feed(<String, dynamic>{'stream': 'd', 'index': 0, 'total': 2, 'data': 'QQ=='});
      expect(
        () => r.feed(<String, dynamic>{'stream': 'e', 'index': 0, 'total': 2, 'data': 'QQ=='}),
        throwsA(isA<ChannelException>()),
      );
    });

    test('refuses to split beyond the cap', () {
      expect(
        () => splitMessage('a' * (maxReassembledBytes + 1)),
        throwsA(isA<ChannelException>()),
      );
    });
  });
}
