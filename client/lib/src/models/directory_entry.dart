class DirectoryEntry {
  const DirectoryEntry({
    required this.userId,
    required this.displayName,
    required this.identityPublicKey,
    required this.updatedAt,
    required this.online,
  });

  final String userId;
  final String displayName;
  final String identityPublicKey;
  final DateTime updatedAt;
  final bool online;

  factory DirectoryEntry.fromJson(Map<String, dynamic> json) {
    return DirectoryEntry(
      userId: json['userId'] as String,
      displayName:
          (json['displayName'] as String?) ?? (json['userId'] as String),
      identityPublicKey: json['identityPublicKey'] as String,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      online: json['online'] == true,
    );
  }
}
