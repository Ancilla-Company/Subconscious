import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'encoding.dart';

/// Fixed, negotiated data channel ids (webrtc.md Appendix A).
const Map<String, int> channelIds = <String, int>{
  'control': 0,
  'rpc': 1,
  'sync': 2,
  'events': 3,
};

const int protocolVersion = 1;
const int maxMessageBytes = 16 * 1024;

/// Raw bytes per chunk; base64 plus envelope stays below [maxMessageBytes].
const int chunkBytes = 11000;
const int maxReassembledBytes = 8 * 1024 * 1024;
const int maxConcurrentStreams = 16;
const Duration reassemblyTimeout = Duration(seconds: 30);

final class ChannelException implements Exception {
  const ChannelException(this.message);
  final String message;
  @override
  String toString() => 'ChannelException: $message';
}

/// `{v, type, id, data, src, dst}`.
final class Envelope {
  const Envelope({
    required this.type,
    this.data,
    this.id,
    this.src,
    this.dst,
  });

  final String type;
  final Object? data;
  final String? id;
  final String? src;
  final String? dst;

  Map<String, dynamic> toWire() => <String, dynamic>{
    'v': protocolVersion,
    'type': type,
    'id': ?id,
    'data': data,
    'src': ?src,
    'dst': ?dst,
  };

  factory Envelope.fromWire(Object? value) {
    if (value is! Map) throw const ChannelException('Envelope must be an object.');
    if (value['v'] != protocolVersion) {
      throw const ChannelException('Unsupported envelope version.');
    }
    final Object? type = value['type'];
    if (type is! String || type.isEmpty) {
      throw const ChannelException('Envelope type is missing.');
    }
    final Object? id = value['id'];
    final Object? src = value['src'];
    final Object? dst = value['dst'];
    if (id != null && id is! String) {
      throw const ChannelException('Envelope id must be a string.');
    }
    if ((src != null && src is! String) || (dst != null && dst is! String)) {
      throw const ChannelException('Envelope src/dst must be strings.');
    }
    return Envelope(
      type: type,
      data: value['data'],
      id: id as String?,
      src: src as String?,
      dst: dst as String?,
    );
  }

  Map<String, dynamic>? get dataMap =>
      data is Map ? (data! as Map).cast<String, dynamic>() : null;
}

String encodeEnvelope(Envelope envelope) => jsonEncode(envelope.toWire());

/// Splits one serialised envelope into wire messages of at most 16 KiB.
///
/// Chunk format follows the engine (`hive/channels.py`):
/// `{v, type:"chunk", stream, index, total, data:<base64>}`.
List<String> splitMessage(String text, {Random? random}) {
  final Uint8List raw = Uint8List.fromList(utf8.encode(text));
  if (raw.length <= maxMessageBytes) return <String>[text];
  if (raw.length > maxReassembledBytes) {
    throw const ChannelException('Message exceeds the maximum size.');
  }
  final Random rng = random ?? Random.secure();
  final String stream = b64uEncode(
    List<int>.generate(9, (int _) => rng.nextInt(256)),
  );
  final int total = (raw.length + chunkBytes - 1) ~/ chunkBytes;
  return <String>[
    for (int index = 0; index < total; index++)
      jsonEncode(<String, dynamic>{
        'v': protocolVersion,
        'type': 'chunk',
        'stream': stream,
        'index': index,
        'total': total,
        'data': base64.encode(
          raw.sublist(
            index * chunkBytes,
            min(raw.length, (index + 1) * chunkBytes),
          ),
        ),
      }),
  ];
}

final class _Stream {
  _Stream(this.total, this.started);
  final int total;
  final DateTime started;
  final Map<int, Uint8List> pieces = <int, Uint8List>{};
  int size = 0;
}

/// Bounded chunk reassembly: size cap, stream cap and a per stream timeout.
final class Reassembler {
  Reassembler({
    this.maxBytes = maxReassembledBytes,
    this.timeout = reassemblyTimeout,
    this.maxStreams = maxConcurrentStreams,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int maxBytes;
  final Duration timeout;
  final int maxStreams;
  final DateTime Function() _clock;
  final Map<String, _Stream> _streams = <String, _Stream>{};

  int get openStreams => _streams.length;

  int expire() {
    final DateTime now = _clock();
    final List<String> stale = <String>[
      for (final MapEntry<String, _Stream> e in _streams.entries)
        if (now.difference(e.value.started) > timeout) e.key,
    ];
    stale.forEach(_streams.remove);
    return stale.length;
  }

  /// Adds one chunk; returns the full text when the stream completes.
  /// Accepts the engine form (`stream/index/total/data`) and the Appendix A
  /// form (`id/data.i/data.n/data.b64`).
  String? feed(Map<String, dynamic> chunk) {
    expire();
    Object? streamId = chunk['stream'];
    Object? index = chunk['index'];
    Object? total = chunk['total'];
    Object? data = chunk['data'];
    if (streamId == null && chunk['data'] is Map) {
      final Map<dynamic, dynamic> inner = chunk['data'] as Map;
      streamId = chunk['id'];
      index = inner['i'];
      total = inner['n'];
      data = inner['b64'];
    }
    if (streamId is! String ||
        streamId.isEmpty ||
        streamId.length > 64 ||
        index is! int ||
        total is! int ||
        data is! String ||
        total < 2 ||
        index < 0 ||
        index >= total) {
      throw const ChannelException('Malformed chunk.');
    }
    if (total * chunkBytes > maxBytes + chunkBytes) {
      throw const ChannelException('Chunked message exceeds the maximum size.');
    }
    _Stream? stream = _streams[streamId];
    if (stream == null) {
      if (_streams.length >= maxStreams) {
        throw const ChannelException('Too many concurrent chunk streams.');
      }
      stream = _streams[streamId] = _Stream(total, _clock());
    } else if (stream.total != total) {
      _streams.remove(streamId);
      throw const ChannelException('Chunk stream metadata changed.');
    }
    final Uint8List piece;
    try {
      piece = base64.decode(data);
    } on FormatException {
      _streams.remove(streamId);
      throw const ChannelException('Chunk payload is not valid base64.');
    }
    if (piece.length > chunkBytes || stream.pieces.containsKey(index)) {
      _streams.remove(streamId);
      throw const ChannelException('Invalid or duplicate chunk.');
    }
    stream.pieces[index] = piece;
    stream.size += piece.length;
    if (stream.size > maxBytes) {
      _streams.remove(streamId);
      throw const ChannelException('Reassembled message exceeds the maximum size.');
    }
    if (stream.pieces.length < stream.total) return null;
    _streams.remove(streamId);
    final BytesBuilder builder = BytesBuilder(copy: false);
    for (int i = 0; i < total; i++) {
      builder.add(stream.pieces[i]!);
    }
    try {
      return utf8.decode(builder.takeBytes());
    } on FormatException {
      throw const ChannelException('Reassembled message is not UTF-8.');
    }
  }
}

/// Parses one wire message; returns null while a chunked stream is incomplete.
Envelope? decodeMessage(Reassembler reassembler, Object? text) {
  if (text is! String) {
    throw const ChannelException('Binary data channel messages are not supported.');
  }
  if (utf8.encode(text).length > maxMessageBytes) {
    throw const ChannelException('Data channel message exceeds 16 KiB.');
  }
  Object? value = _json(text, 'Message is not valid JSON.');
  if (value is Map && value['type'] == 'chunk') {
    final String? full = reassembler.feed(value.cast<String, dynamic>());
    if (full == null) return null;
    value = _json(full, 'Reassembled message is not valid JSON.');
    if (value is Map && value['type'] == 'chunk') {
      throw const ChannelException('Nested chunks are not allowed.');
    }
  }
  return Envelope.fromWire(value);
}

Object? _json(String text, String error) {
  try {
    return jsonDecode(text);
  } on FormatException {
    throw ChannelException(error);
  }
}
