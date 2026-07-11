class Contact {
  const Contact({
    required this.userId,
    required this.displayName,
    required this.identityPublicKey,
    this.avatarMimeType,
    this.avatarBytesBase64,
    this.profileUpdatedAt,
  });

  final String userId;
  final String displayName;
  final String identityPublicKey;
  final String? avatarMimeType;
  final String? avatarBytesBase64;
  final DateTime? profileUpdatedAt;

  bool get hasAvatar =>
      avatarBytesBase64 != null && avatarBytesBase64!.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'displayName': displayName,
        'identityPublicKey': identityPublicKey,
        'avatarMimeType': avatarMimeType,
        'avatarBytes': avatarBytesBase64,
        'profileUpdatedAt': profileUpdatedAt?.toUtc().toIso8601String(),
      };

  factory Contact.fromJson(Map<String, dynamic> json) {
    final profileUpdatedAtRaw = json['profileUpdatedAt'] as String?;
    return Contact(
      userId: json['userId'] as String,
      displayName: json['displayName'] as String,
      identityPublicKey: json['identityPublicKey'] as String,
      avatarMimeType: json['avatarMimeType'] as String?,
      avatarBytesBase64: json['avatarBytes'] as String?,
      profileUpdatedAt: profileUpdatedAtRaw == null
          ? null
          : DateTime.parse(profileUpdatedAtRaw),
    );
  }

  Contact copyWith({
    String? displayName,
    String? identityPublicKey,
    String? avatarMimeType,
    String? avatarBytesBase64,
    DateTime? profileUpdatedAt,
  }) {
    return Contact(
      userId: userId,
      displayName: displayName ?? this.displayName,
      identityPublicKey: identityPublicKey ?? this.identityPublicKey,
      avatarMimeType: avatarMimeType ?? this.avatarMimeType,
      avatarBytesBase64: avatarBytesBase64 ?? this.avatarBytesBase64,
      profileUpdatedAt: profileUpdatedAt ?? this.profileUpdatedAt,
    );
  }
}
