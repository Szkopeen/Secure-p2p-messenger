class Contact {
  const Contact({
    required this.userId,
    required this.displayName,
    required this.identityPublicKey,
  });

  final String userId;
  final String displayName;
  final String identityPublicKey;

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'displayName': displayName,
        'identityPublicKey': identityPublicKey,
      };

  factory Contact.fromJson(Map<String, dynamic> json) {
    return Contact(
      userId: json['userId'] as String,
      displayName: json['displayName'] as String,
      identityPublicKey: json['identityPublicKey'] as String,
    );
  }
}
