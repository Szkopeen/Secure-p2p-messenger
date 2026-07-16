import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

Future<Directory> _mediaCacheDirectory() async {
  final base = await getApplicationCacheDirectory();
  final directory = Directory(
    '${base.path}${Platform.pathSeparator}secure_chat_media_preview',
  );
  if (!await directory.exists()) {
    await directory.create(recursive: true);
  }
  return directory;
}

Future<String> writeTempMediaFile({
  required String fileName,
  required List<int> bytes,
}) async {
  final directory = await _mediaCacheDirectory();
  final safeName = fileName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_');
  await cleanupTempMediaFiles();
  final random = Random.secure();
  final nonce = List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  final path =
      '${directory.path}${Platform.pathSeparator}secure_chat_preview_${nonce}_$safeName';
  final file = File(path);
  final partFile = File('$path.part');
  try {
    await partFile.writeAsBytes(bytes, flush: true);
    await partFile.rename(file.path);
  } catch (_) {
    try {
      if (await partFile.exists()) await partFile.delete();
    } catch (_) {}
    rethrow;
  }
  return file.path;
}

Future<void> cleanupTempMediaFiles({
  Duration maxAge = const Duration(hours: 1),
}) async {
  final directory = await _mediaCacheDirectory();
  final cutoff = DateTime.now().subtract(maxAge);
  await for (final entity in directory.list()) {
    if (entity is! File ||
        !entity.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('secure_chat_preview_')) {
      continue;
    }
    try {
      final stat = await entity.stat();
      if (entity.path.endsWith('.part') || stat.modified.isBefore(cutoff)) {
        await entity.delete();
      }
    } catch (_) {}
  }
}

Future<void> deleteTempMediaFile(String path) async {
  try {
    final file = File(path);
    if (await file.exists()) await file.delete();
  } catch (_) {}
}
