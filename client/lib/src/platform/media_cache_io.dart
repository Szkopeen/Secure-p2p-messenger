import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<String> writeTempMediaFile({
  required String fileName,
  required List<int> bytes,
}) async {
  final directory = await getTemporaryDirectory();
  final safeName = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_');
  final path =
      '${directory.path}${Platform.pathSeparator}secure_chat_preview_$safeName';
  final file = File(path);
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
