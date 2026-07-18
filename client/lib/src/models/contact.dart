class Contact {
  const Contact({
    required this.userId,
    required this.displayName,
    required this.identityPublicKey,
    this.signingPublicKey,
    this.keyAgreementPublicKeySignature,
    this.identityRotationProof,
    this.deviceList,
    this.avatarMimeType,
    this.avatarBytesBase64,
    this.profileUpdatedAt,
    this.isGroup = false,
    this.memberIds = const [],
  });

  final String userId;
  final String displayName;
  // X25519 public key used for wrapping conversation keys.
  final String identityPublicKey;
  // Ed25519 public identity key used to verify keyAgreementPublicKeySignature.
  final String? signingPublicKey;
  final String? keyAgreementPublicKeySignature;
  final Map<String, dynamic>? identityRotationProof;
  final Map<String, dynamic>? deviceList;
  final String? avatarMimeType;
  final String? avatarBytesBase64;
  final DateTime? profileUpdatedAt;
  final bool isGroup;
  final List<String> memberIds;

  bool get hasAvatar =>
      avatarBytesBase64 != null && avatarBytesBase64!.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'displayName': displayName,
        'identityPublicKey': identityPublicKey,
        'signingPublicKey': signingPublicKey,
        'keyAgreementPublicKeySignature': keyAgreementPublicKeySignature,
        'identityRotationProof': identityRotationProof,
        'deviceList': deviceList,
        'avatarMimeType': avatarMimeType,
        'avatarBytes': avatarBytesBase64,
        'profileUpdatedAt': profileUpdatedAt?.toUtc().toIso8601String(),
        'isGroup': isGroup,
        'memberIds': memberIds,
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
      identityRotationProof: (json['identityRotationProof'] as Map?)?.map(
        (key, value) => MapEntry(key.toString(), value),
      ),
      deviceList: (json['deviceList'] as Map?)?.map(
        (key, value) => MapEntry(key.toString(), value),
      ),
      avatarMimeType: json['avatarMimeType'] as String?,
      avatarBytesBase64: json['avatarBytes'] as String?,
      profileUpdatedAt: profileUpdatedAtRaw == null
          ? null
          : DateTime.parse(profileUpdatedAtRaw),
      isGroup: json['isGroup'] == true,
      memberIds: ((json['memberIds'] as List?) ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
    );
  }

  Contact copyWith({
    String? displayName,
    String? identityPublicKey,
    String? signingPublicKey,
    String? keyAgreementPublicKeySignature,
    Map<String, dynamic>? identityRotationProof,
    Map<String, dynamic>? deviceList,
    String? avatarMimeType,
    String? avatarBytesBase64,
    DateTime? profileUpdatedAt,
    bool? isGroup,
    List<String>? memberIds,
  }) {
    return Contact(
      userId: userId,
      displayName: displayName ?? this.displayName,
      identityPublicKey: identityPublicKey ?? this.identityPublicKey,
      signingPublicKey: signingPublicKey ?? this.signingPublicKey,
      keyAgreementPublicKeySignature:
          keyAgreementPublicKeySignature ?? this.keyAgreementPublicKeySignature,
      identityRotationProof:
          identityRotationProof ?? this.identityRotationProof,
      deviceList: deviceList ?? this.deviceList,
      avatarMimeType: avatarMimeType ?? this.avatarMimeType,
      avatarBytesBase64: avatarBytesBase64 ?? this.avatarBytesBase64,
      profileUpdatedAt: profileUpdatedAt ?? this.profileUpdatedAt,
      isGroup: isGroup ?? this.isGroup,
      memberIds: memberIds ?? this.memberIds,
    );
  }
}
