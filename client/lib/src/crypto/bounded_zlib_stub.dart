import 'package:archive/archive.dart';

List<int> boundedZlibDecode(List<int> compressed, {required int maxBytes}) {
  final decoded = const ZLibDecoder().decodeBytes(compressed);
  if (decoded.length > maxBytes) {
    throw const FormatException('Wiadomosc po dekompresji przekracza limit.');
  }
  return decoded;
}
