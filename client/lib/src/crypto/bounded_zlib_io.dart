import 'dart:io';

class _BoundedSink implements Sink<List<int>> {
  _BoundedSink(this.maxBytes);
  final int maxBytes;
  final List<int> bytes = [];

  @override
  void add(List<int> data) {
    if (bytes.length + data.length > maxBytes) {
      throw const FormatException('Wiadomosc po dekompresji przekracza limit.');
    }
    bytes.addAll(data);
  }

  @override
  void close() {}
}

List<int> boundedZlibDecode(List<int> compressed, {required int maxBytes}) {
  final sink = _BoundedSink(maxBytes);
  final decoder = ZLibDecoder().startChunkedConversion(sink);
  decoder.add(compressed);
  decoder.close();
  return sink.bytes;
}
