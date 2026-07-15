Future<String> writeTempMediaFile({
  required String fileName,
  required List<int> bytes,
}) async {
  throw UnsupportedError('Podglad wideo nie jest dostepny na tej platformie.');
}

Future<void> cleanupTempMediaFiles({
  Duration maxAge = const Duration(hours: 1),
}) async {}

Future<void> deleteTempMediaFile(String path) async {}
