import 'file_exporter_stub.dart'
    if (dart.library.io) 'file_exporter_io.dart'
    if (dart.library.html) 'file_exporter_web.dart';

Future<void> saveReceivedFile({
  required String fileName,
  required List<int> bytes,
  String? mimeType,
}) {
  return saveReceivedFileImpl(
    fileName: fileName,
    bytes: bytes,
    mimeType: mimeType,
  );
}
