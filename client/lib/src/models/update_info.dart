class UpdateArtifact {
  const UpdateArtifact({
    required this.platform,
    required this.fileName,
    required this.url,
    this.sha256,
    this.size,
  });

  final String platform;
  final String fileName;
  final Uri url;
  final String? sha256;
  final int? size;
}

class AvailableUpdate {
  const AvailableUpdate({
    required this.version,
    required this.buildNumber,
    required this.releasedAt,
    required this.notes,
    required this.artifact,
  });

  final String version;
  final int buildNumber;
  final DateTime? releasedAt;
  final List<String> notes;
  final UpdateArtifact artifact;

  String get label => '$version+$buildNumber';

  String get notesText {
    if (notes.isEmpty) return 'Brak opisu zmian.';
    return notes.join('\n');
  }
}
