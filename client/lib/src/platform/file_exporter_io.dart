import 'dart:io';

import 'package:file_picker/file_picker.dart';

Future<void> saveReceivedFileImpl({
  required String fileName,
  required List<int> bytes,
  String? mimeType,
}) async {
  final path = await FilePicker.platform.saveFile(fileName: fileName);
  if (path == null) return;
  await File(path).writeAsBytes(bytes, flush: true);
}
