import '../crypto/codec.dart';

class CloudSession {
  const CloudSession({
    required this.serverUrl,
    required this.token,
    required this.userId,
    required this.username,
    required this.displayName,
    required this.deviceId,
    required this.vaultSalt,
    required this.vaultKey,
  });

  final String serverUrl;
  final String token;
  final String userId;
  final String username;
  final String displayName;
  final String deviceId;
  final String vaultSalt;
  final String vaultKey;

  Map<String, dynamic> toJson() => {
        'serverUrl': serverUrl,
        'token': token,
        'userId': userId,
        'username': username,
        'displayName': displayName,
        'deviceId': deviceId,
        'vaultSalt': vaultSalt,
        'vaultKey': vaultKey,
      };

  factory CloudSession.fromJson(Map<String, dynamic> json) {
    return CloudSession(
      serverUrl: requiredString(json, 'serverUrl'),
      token: requiredString(json, 'token'),
      userId: requiredString(json, 'userId'),
      username: requiredString(json, 'username'),
      displayName:
          json['displayName'] as String? ?? requiredString(json, 'username'),
      deviceId: requiredString(json, 'deviceId'),
      vaultSalt: requiredString(json, 'vaultSalt'),
      vaultKey: requiredString(json, 'vaultKey'),
    );
  }
}

class CloudPublicUser {
  const CloudPublicUser({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.keyAgreementPublicKey,
  });

  final String userId;
  final String username;
  final String displayName;
  final String keyAgreementPublicKey;

  factory CloudPublicUser.fromJson(Map<String, dynamic> json) {
    return CloudPublicUser(
      userId: requiredString(json, 'userId'),
      username: requiredString(json, 'username'),
      displayName:
          json['displayName'] as String? ?? requiredString(json, 'username'),
      keyAgreementPublicKey: requiredString(json, 'keyAgreementPublicKey'),
    );
  }
}

class CloudConversation {
  const CloudConversation({
    required this.conversationId,
    required this.type,
    required this.memberIds,
    required this.memberKeys,
    required this.updatedAt,
  });

  final String conversationId;
  final String type;
  final List<String> memberIds;
  final Map<String, dynamic> memberKeys;
  final DateTime updatedAt;

  factory CloudConversation.fromJson(Map<String, dynamic> json) {
    return CloudConversation(
      conversationId: requiredString(json, 'conversationId'),
      type: requiredString(json, 'type'),
      memberIds: ((json['memberIds'] as List?) ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
      memberKeys: ((json['memberKeys'] as Map?) ?? const {})
          .map((key, value) => MapEntry(key.toString(), value)),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

class CloudStoredMessage {
  const CloudStoredMessage({
    required this.messageId,
    required this.conversationId,
    required this.seq,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.createdAt,
    required this.payload,
  });

  final String messageId;
  final String conversationId;
  final int seq;
  final String senderUserId;
  final String senderDeviceId;
  final DateTime createdAt;
  final Map<String, dynamic> payload;

  factory CloudStoredMessage.fromJson(Map<String, dynamic> json) {
    return CloudStoredMessage(
      messageId: requiredString(json, 'messageId'),
      conversationId: requiredString(json, 'conversationId'),
      seq: requiredInt(json, 'seq'),
      senderUserId: requiredString(json, 'senderUserId'),
      senderDeviceId: json['senderDeviceId'] as String? ?? '',
      createdAt: DateTime.parse(requiredString(json, 'createdAt')),
      payload: asStringKeyMap(json['payload'], 'payload'),
    );
  }
}

class CloudVault {
  const CloudVault({
    required this.keyAgreementPrivateKey,
    required this.keyAgreementPublicKey,
    required this.conversationKeys,
  });

  final String keyAgreementPrivateKey;
  final String keyAgreementPublicKey;
  final Map<String, String> conversationKeys;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'keyAgreementPrivateKey': keyAgreementPrivateKey,
        'keyAgreementPublicKey': keyAgreementPublicKey,
        'conversationKeys': conversationKeys,
      };

  factory CloudVault.fromJson(Map<String, dynamic> json) {
    return CloudVault(
      keyAgreementPrivateKey: requiredString(json, 'keyAgreementPrivateKey'),
      keyAgreementPublicKey: requiredString(json, 'keyAgreementPublicKey'),
      conversationKeys: ((json['conversationKeys'] as Map?) ?? const {})
          .map((key, value) => MapEntry(key.toString(), value.toString())),
    );
  }

  CloudVault copyWith({
    String? keyAgreementPrivateKey,
    String? keyAgreementPublicKey,
    Map<String, String>? conversationKeys,
  }) {
    return CloudVault(
      keyAgreementPrivateKey:
          keyAgreementPrivateKey ?? this.keyAgreementPrivateKey,
      keyAgreementPublicKey:
          keyAgreementPublicKey ?? this.keyAgreementPublicKey,
      conversationKeys: conversationKeys ?? this.conversationKeys,
    );
  }
}
