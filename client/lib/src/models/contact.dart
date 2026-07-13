class Contact {
  const Contact({
    required this.userId,
    required this.displayName,
    required this.identityPublicKey,
    this.signingPublicKey,
    this.keyAgreementPublicKeySignature,
    this.avatarMimeType,
    this.avatarBytesBase64,
    this.profileUpdatedAt,
  });

  final String userId;
  final String displayName;
  // X25519 public key used for wrapping conversation keys.
  final String identityPublicKey;
  // Ed25519 public identity key used to verify keyAgreementPublicKeySignature.
  final String? signingPublicKey;
  final String? keyAgreementPublicKeySignature;
  final String? avatarMimeType;
  final String? avatarBytesBase64;
  final DateTime? profileUpdatedAt;

  bool get hasAvatar =>
      avatarBytesBase64 != null && avatarBytesBase64!.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'displayName': displayName,
        'identityPublicKey': identityPublicKey,
        'signingPublicKey': signingPublicKey,
        'keyAgreementPublicKeySignature': keyAgreementPublicKeySignature,
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
      signingPublicKey: json['signingPublicKey'] as String?,
      keyAgreementPublicKeySignature:
          json['keyAgreementPublicKeySignature'] as String?,
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
    String? signingPublicKey,
    String? keyAgreementPublicKeySignature,
    String? avatarMimeType,
    String? avatarBytesBase64,
    DateTime? profileUpdatedAt,
  }) {
    return Contact(
      userId: userId,
      displayName: displayName ?? this.displayName,
      identityPublicKey: identityPublicKey ?? this.identityPublicKey,
      signingPublicKey: signingPublicKey ?? this.signingPublicKey,
      keyAgreementPublicKeySignature:
          keyAgreementPublicKeySignature ?? this.keyAgreementPublicKeySignature,
      avatarMimeType: avatarMimeType ?? this.avatarMimeType,
      avatarBytesBase64: avatarBytesBase64 ?? this.avatarBytesBase64,
      profileUpdatedAt: profileUpdatedAt ?? this.profileUpdatedAt,
    );
  }
}
