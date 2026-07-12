class ContactInvite {
  const ContactInvite({
    required this.requestId,
    required this.userId,
    required this.displayName,
    required this.identityPublicKey,
    required this.createdAt,
  });

  final String requestId;
  final String userId;
  final String displayName;
  final String identityPublicKey;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        'userId': userId,
        'displayName': displayName,
        'identityPublicKey': identityPublicKey,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  factory ContactInvite.fromJson(Map<String, dynamic> json) {
    return ContactInvite(
      requestId: json['requestId'] as String,
      userId: json['userId'] as String,
      displayName:
          (json['displayName'] as String?) ?? (json['userId'] as String),
      identityPublicKey: json['identityPublicKey'] as String,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}
