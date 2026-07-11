class UserProfile {
  const UserProfile({
    this.avatarMimeType,
    this.avatarBytesBase64,
    this.updatedAt,
  });

  final String? avatarMimeType;
  final String? avatarBytesBase64;
  final DateTime? updatedAt;

  bool get hasAvatar =>
      avatarBytesBase64 != null && avatarBytesBase64!.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'avatarMimeType': avatarMimeType,
        'avatarBytes': avatarBytesBase64,
        'updatedAt':
            (updatedAt ?? DateTime.now().toUtc()).toUtc().toIso8601String(),
      };

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    final updatedAtRaw = json['updatedAt'] as String?;
    return UserProfile(
      avatarMimeType: json['avatarMimeType'] as String?,
      avatarBytesBase64: json['avatarBytes'] as String?,
      updatedAt: updatedAtRaw == null ? null : DateTime.parse(updatedAtRaw),
    );
  }
}
