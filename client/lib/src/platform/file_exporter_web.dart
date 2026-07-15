// This is the conditional browser implementation. dart:html remains necessary
// until the exporter is migrated to package:web.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:html' as html;

Future<void> saveReceivedFileImpl({
  required String fileName,
  required List<int> bytes,
  String? mimeType,
}) async {
  final blob = html.Blob([bytes], mimeType ?? 'application/octet-stream');
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = fileName
    ..style.display = 'none';

  html.document.body?.children.add(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
}
