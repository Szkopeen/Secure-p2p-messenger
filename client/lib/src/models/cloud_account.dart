import 'package:crypto/crypto.dart' as crypto_hash;

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
    required this.identityPublicKey,
    required this.keyAgreementPublicKeySignature,
    this.identityRotationProof,
  });

  final String userId;
  final String username;
  final String displayName;
  final String keyAgreementPublicKey;
  final String identityPublicKey;
  final String keyAgreementPublicKeySignature;
  final IdentityRotationProof? identityRotationProof;

  factory CloudPublicUser.fromJson(Map<String, dynamic> json) {
    return CloudPublicUser(
      userId: requiredString(json, 'userId'),
      username: requiredString(json, 'username'),
      displayName:
          json['displayName'] as String? ?? requiredString(json, 'username'),
      keyAgreementPublicKey: requiredString(json, 'keyAgreementPublicKey'),
      identityPublicKey: json['identityPublicKey'] as String? ?? '',
      keyAgreementPublicKeySignature:
          json['keyAgreementPublicKeySignature'] as String? ?? '',
      identityRotationProof:
          IdentityRotationProof.fromOptionalJson(json['identityRotationProof']),
    );
  }
}

class IdentityRotationProof {
  const IdentityRotationProof({
    required this.rotationEpoch,
    required this.previousRotationHash,
    required this.oldIdentityPublicKey,
    required this.newIdentityPublicKey,
    required this.newKeyAgreementPublicKey,
    required this.signature,
    required this.newIdentityConfirmationSignature,
    required this.rotatedAt,
  });

  final int rotationEpoch;
  final String previousRotationHash;
  final String oldIdentityPublicKey;
  final String newIdentityPublicKey;
  final String newKeyAgreementPublicKey;
  final String signature;
  final String newIdentityConfirmationSignature;
  final DateTime rotatedAt;

  String get rotationHash =>
      crypto_hash.sha256.convert(canonicalJsonBytes(toJson())).toString();

  Map<String, dynamic> toJson() => {
        'v': 1,
        'rotationEpoch': rotationEpoch,
        'previousRotationHash': previousRotationHash,
        'oldIdentityPublicKey': oldIdentityPublicKey,
        'newIdentityPublicKey': newIdentityPublicKey,
        'newKeyAgreementPublicKey': newKeyAgreementPublicKey,
        'signature': signature,
        'newIdentityConfirmationSignature': newIdentityConfirmationSignature,
        'rotatedAt': rotatedAt.toUtc().toIso8601String(),
      };

  factory IdentityRotationProof.fromJson(Map<String, dynamic> json) {
    return IdentityRotationProof(
      rotationEpoch: json['rotationEpoch'] is int
          ? json['rotationEpoch'] as int
          : int.tryParse(json['rotationEpoch']?.toString() ?? '') ?? 1,
      previousRotationHash: json['previousRotationHash'] as String? ?? '',
      oldIdentityPublicKey: requiredString(json, 'oldIdentityPublicKey'),
      newIdentityPublicKey: requiredString(json, 'newIdentityPublicKey'),
      newKeyAgreementPublicKey:
          requiredString(json, 'newKeyAgreementPublicKey'),
      signature: requiredString(json, 'signature'),
      newIdentityConfirmationSignature:
          json['newIdentityConfirmationSignature'] as String? ?? '',
      rotatedAt: DateTime.tryParse(json['rotatedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  static IdentityRotationProof? fromOptionalJson(Object? value) {
    if (value is Map) {
      return IdentityRotationProof.fromJson(value.cast<String, dynamic>());
    }
    return null;
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

class CloudMessageReplayState {
  const CloudMessageReplayState({
    required this.accountId,
    required this.conversationId,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.lastCounter,
    required this.lastMessageHash,
  });

  final String accountId;
  final String conversationId;
  final String senderUserId;
  final String senderDeviceId;
  final int lastCounter;
  final String lastMessageHash;

  String get key => '$accountId|$conversationId|$senderUserId|$senderDeviceId';

  Map<String, dynamic> toJson() => {
        'v': 1,
        'accountId': accountId,
        'conversationId': conversationId,
        'senderUserId': senderUserId,
        'senderDeviceId': senderDeviceId,
        'lastCounter': lastCounter,
        'lastMessageHash': lastMessageHash,
      };

  factory CloudMessageReplayState.fromJson(Map<String, dynamic> json) {
    return CloudMessageReplayState(
      accountId: requiredString(json, 'accountId'),
      conversationId: requiredString(json, 'conversationId'),
      senderUserId: requiredString(json, 'senderUserId'),
      senderDeviceId: requiredString(json, 'senderDeviceId'),
      lastCounter: requiredInt(json, 'lastCounter'),
      lastMessageHash: requiredString(json, 'lastMessageHash'),
    );
  }
}

class CloudVault {
  const CloudVault({
    required this.keyAgreementPrivateKey,
    required this.keyAgreementPublicKey,
    required this.identityPrivateKey,
    required this.identityPublicKey,
    required this.keyAgreementPublicKeySignature,
    required this.conversationKeys,
    this.identityRotationProof,
  });

  final String keyAgreementPrivateKey;
  final String keyAgreementPublicKey;
  final String identityPrivateKey;
  final String identityPublicKey;
  final String keyAgreementPublicKeySignature;
  final Map<String, String> conversationKeys;
  final IdentityRotationProof? identityRotationProof;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'keyAgreementPrivateKey': keyAgreementPrivateKey,
        'keyAgreementPublicKey': keyAgreementPublicKey,
        'identityPrivateKey': identityPrivateKey,
        'identityPublicKey': identityPublicKey,
        'keyAgreementPublicKeySignature': keyAgreementPublicKeySignature,
        'identityRotationProof': identityRotationProof?.toJson(),
        'conversationKeys': conversationKeys,
      };

  factory CloudVault.fromJson(Map<String, dynamic> json) {
    return CloudVault(
      keyAgreementPrivateKey: requiredString(json, 'keyAgreementPrivateKey'),
      keyAgreementPublicKey: requiredString(json, 'keyAgreementPublicKey'),
      identityPrivateKey: json['identityPrivateKey'] as String? ?? '',
      identityPublicKey: json['identityPublicKey'] as String? ?? '',
      keyAgreementPublicKeySignature:
          json['keyAgreementPublicKeySignature'] as String? ?? '',
      identityRotationProof:
          IdentityRotationProof.fromOptionalJson(json['identityRotationProof']),
      conversationKeys: ((json['conversationKeys'] as Map?) ?? const {})
          .map((key, value) => MapEntry(key.toString(), value.toString())),
    );
  }

  CloudVault copyWith({
    String? keyAgreementPrivateKey,
    String? keyAgreementPublicKey,
    String? identityPrivateKey,
    String? identityPublicKey,
    String? keyAgreementPublicKeySignature,
    IdentityRotationProof? identityRotationProof,
    Map<String, String>? conversationKeys,
  }) {
    return CloudVault(
      keyAgreementPrivateKey:
          keyAgreementPrivateKey ?? this.keyAgreementPrivateKey,
      keyAgreementPublicKey:
          keyAgreementPublicKey ?? this.keyAgreementPublicKey,
      identityPrivateKey: identityPrivateKey ?? this.identityPrivateKey,
      identityPublicKey: identityPublicKey ?? this.identityPublicKey,
      keyAgreementPublicKeySignature:
          keyAgreementPublicKeySignature ?? this.keyAgreementPublicKeySignature,
      identityRotationProof:
          identityRotationProof ?? this.identityRotationProof,
      conversationKeys: conversationKeys ?? this.conversationKeys,
    );
  }
}
