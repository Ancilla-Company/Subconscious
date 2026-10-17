import 'dart:typed_data';

/// Wraps little-endian PCM16 samples in a canonical 44 byte WAV header.
Uint8List pcm16ToWav(
  Uint8List pcm, {
  int sampleRate = 16000,
  int channels = 1,
}) {
  const int bitsPerSample = 16;
  final int byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  final ByteData header = ByteData(44);
  void ascii(int offset, String text) {
    for (int i = 0; i < text.length; i++) {
      header.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, channels * bitsPerSample ~/ 8, Endian.little);
  header.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, pcm.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(header.buffer.asUint8List())
        ..add(pcm))
      .toBytes();
}
