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

  CloudSession copyWith({
    String? serverUrl,
    String? token,
    String? userId,
    String? username,
    String? displayName,
    String? deviceId,
    String? vaultSalt,
    String? vaultKey,
  }) {
    return CloudSession(
      serverUrl: serverUrl ?? this.serverUrl,
      token: token ?? this.token,
      userId: userId ?? this.userId,
      username: username ?? this.username,
      displayName: displayName ?? this.displayName,
      deviceId: deviceId ?? this.deviceId,
      vaultSalt: vaultSalt ?? this.vaultSalt,
      vaultKey: vaultKey ?? this.vaultKey,
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
    this.deviceCertificates = const {},
    this.deviceList,
    this.identityRotationProof,
  });

  final String userId;
  final String username;
  final String displayName;
  final String keyAgreementPublicKey;
  final String identityPublicKey;
  final String keyAgreementPublicKeySignature;
  final Map<String, CloudDeviceCertificate> deviceCertificates;
  final CloudDeviceList? deviceList;
  final IdentityRotationProof? identityRotationProof;

  factory CloudPublicUser.fromJson(Map<String, dynamic> json) {
    final devices = <String, CloudDeviceCertificate>{};
    final rawDevices = json['devices'];
    if (rawDevices is Map) {
      for (final entry in rawDevices.entries) {
        final value = entry.value;
        final certificateJson =
            value is Map ? value['deviceCertificate'] : null;
        final certificate = CloudDeviceCertificate.fromOptionalJson(
          certificateJson,
        );
        if (certificate != null) {
          devices[entry.key.toString()] = certificate;
        }
      }
    }
    return CloudPublicUser(
      userId: requiredString(json, 'userId'),
      username: requiredString(json, 'username'),
      displayName:
          json['displayName'] as String? ?? requiredString(json, 'username'),
      keyAgreementPublicKey: requiredString(json, 'keyAgreementPublicKey'),
      identityPublicKey: json['identityPublicKey'] as String? ?? '',
      keyAgreementPublicKeySignature:
          json['keyAgreementPublicKeySignature'] as String? ?? '',
      deviceCertificates: devices,
      deviceList: CloudDeviceList.fromOptionalJson(json['deviceList']),
      identityRotationProof: IdentityRotationProof.fromOptionalJson(
        json['identityRotationProof'],
      ),
    );
  }
}

class CloudDeviceCertificate {
  const CloudDeviceCertificate({
    required this.accountId,
    required this.serverOrigin,
    required this.deviceId,
    required this.deviceSigningPublicKey,
    required this.deviceEpoch,
    required this.createdAt,
    required this.signature,
  });

  final String accountId;
  final String serverOrigin;
  final String deviceId;
  final String deviceSigningPublicKey;
  final int deviceEpoch;
  final DateTime createdAt;
  final String signature;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'protocol': 'secure-chat/device-list/v1',
        'accountId': accountId,
        'serverOrigin': serverOrigin,
        'deviceId': deviceId,
        'deviceSigningPublicKey': deviceSigningPublicKey,
        'deviceEpoch': deviceEpoch,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'signature': signature,
      };

  factory CloudDeviceCertificate.fromJson(Map<String, dynamic> json) {
    return CloudDeviceCertificate(
      accountId: requiredString(json, 'accountId'),
      serverOrigin: requiredString(json, 'serverOrigin'),
      deviceId: requiredString(json, 'deviceId'),
      deviceSigningPublicKey: requiredString(json, 'deviceSigningPublicKey'),
      deviceEpoch: json['deviceEpoch'] is int
          ? json['deviceEpoch'] as int
          : int.tryParse(json['deviceEpoch']?.toString() ?? '') ?? 1,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      signature: requiredString(json, 'signature'),
    );
  }

  static CloudDeviceCertificate? fromOptionalJson(Object? value) {
    if (value is Map) {
      return CloudDeviceCertificate.fromJson(value.cast<String, dynamic>());
    }
    return null;
  }

  String get certificateHash =>
      crypto_hash.sha256.convert(canonicalJsonBytes(toJson())).toString();
}

class CloudDeviceListEntry {
  const CloudDeviceListEntry({
    required this.deviceId,
    required this.deviceSigningPublicKey,
    required this.certificateHash,
    required this.addedAt,
    required this.deviceEpoch,
  });

  final String deviceId;
  final String deviceSigningPublicKey;
  final String certificateHash;
  final DateTime addedAt;
  final int deviceEpoch;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceSigningPublicKey': deviceSigningPublicKey,
        'certificateHash': certificateHash,
        'addedAt': addedAt.toUtc().toIso8601String(),
        'deviceEpoch': deviceEpoch,
      };

  factory CloudDeviceListEntry.fromJson(Map<String, dynamic> json) {
    return CloudDeviceListEntry(
      deviceId: requiredString(json, 'deviceId'),
      deviceSigningPublicKey: requiredString(json, 'deviceSigningPublicKey'),
      certificateHash: requiredString(json, 'certificateHash'),
      addedAt: DateTime.tryParse(json['addedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      deviceEpoch: json['deviceEpoch'] is int
          ? json['deviceEpoch'] as int
          : int.tryParse(json['deviceEpoch']?.toString() ?? '') ?? 1,
    );
  }
}

class CloudRevokedDevice {
  const CloudRevokedDevice({
    required this.deviceId,
    required this.deviceSigningPublicKey,
    required this.deviceCertificateHash,
    required this.revokedDeviceEpoch,
    required this.revokedAt,
    required this.reasonCode,
  });

  final String deviceId;
  final String deviceSigningPublicKey;
  final String deviceCertificateHash;
  final int revokedDeviceEpoch;
  final DateTime revokedAt;
  final String reasonCode;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceSigningPublicKey': deviceSigningPublicKey,
        'deviceCertificateHash': deviceCertificateHash,
        'revokedDeviceEpoch': revokedDeviceEpoch,
        'revokedAt': revokedAt.toUtc().toIso8601String(),
        'reasonCode': reasonCode,
      };

  factory CloudRevokedDevice.fromJson(Map<String, dynamic> json) {
    return CloudRevokedDevice(
      deviceId: requiredString(json, 'deviceId'),
      deviceSigningPublicKey: json['deviceSigningPublicKey'] as String? ?? '',
      deviceCertificateHash: json['deviceCertificateHash'] as String? ?? '',
      revokedDeviceEpoch: json['revokedDeviceEpoch'] is int
          ? json['revokedDeviceEpoch'] as int
          : int.tryParse(json['revokedDeviceEpoch']?.toString() ?? '') ?? 1,
      revokedAt: DateTime.tryParse(json['revokedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      reasonCode: json['reasonCode'] as String? ?? 'unknown',
    );
  }
}

class CloudDeviceList {
  const CloudDeviceList({
    required this.accountId,
    required this.serverOrigin,
    required this.deviceListEpoch,
    required this.previousDeviceListHash,
    required this.identityRotationEpoch,
    required this.devices,
    required this.revokedDevices,
    required this.signature,
    required this.updatedAt,
  });

  final String accountId;
  final String serverOrigin;
  final int deviceListEpoch;
  final String previousDeviceListHash;
  final int identityRotationEpoch;
  final List<CloudDeviceListEntry> devices;
  final List<CloudRevokedDevice> revokedDevices;
  final String signature;
  final DateTime updatedAt;

  String get deviceListHash =>
      crypto_hash.sha256.convert(canonicalJsonBytes(toJson())).toString();

  Map<String, dynamic> toJson() => {
        'v': 1,
        'accountId': accountId,
        'serverOrigin': serverOrigin,
        'deviceListEpoch': deviceListEpoch,
        'previousDeviceListHash': previousDeviceListHash,
        'identityRotationEpoch': identityRotationEpoch,
        'devices': devices.map((device) => device.toJson()).toList(),
        'revokedDevices':
            revokedDevices.map((device) => device.toJson()).toList(),
        'signature': signature,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  Map<String, dynamic> signedPayload() => {
        'v': 1,
        'protocol': 'secure-chat/device-list/v1',
        'accountId': accountId,
        'serverOrigin': serverOrigin,
        'deviceListEpoch': deviceListEpoch,
        'previousDeviceListHash': previousDeviceListHash,
        'identityRotationEpoch': identityRotationEpoch,
        'devices': devices.map((device) => device.toJson()).toList(),
        'revokedDevices':
            revokedDevices.map((device) => device.toJson()).toList(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  CloudDeviceListEntry? activeDevice(String deviceId) {
    for (final device in devices) {
      if (device.deviceId == deviceId) return device;
    }
    return null;
  }

  bool isRevoked(String deviceId) {
    return revokedDevices.any((device) => device.deviceId == deviceId);
  }

  factory CloudDeviceList.fromJson(Map<String, dynamic> json) {
    return CloudDeviceList(
      accountId: requiredString(json, 'accountId'),
      serverOrigin: requiredString(json, 'serverOrigin'),
      deviceListEpoch: json['deviceListEpoch'] is int
          ? json['deviceListEpoch'] as int
          : int.tryParse(json['deviceListEpoch']?.toString() ?? '') ?? 1,
      previousDeviceListHash: json['previousDeviceListHash'] as String? ?? '',
      identityRotationEpoch: json['identityRotationEpoch'] is int
          ? json['identityRotationEpoch'] as int
          : int.tryParse(json['identityRotationEpoch']?.toString() ?? '') ?? 0,
      devices: ((json['devices'] as List?) ?? const [])
          .map(
            (item) => CloudDeviceListEntry.fromJson(
              (item as Map).cast<String, dynamic>(),
            ),
          )
          .toList(growable: false),
      revokedDevices: ((json['revokedDevices'] as List?) ?? const [])
          .map(
            (item) => CloudRevokedDevice.fromJson(
              (item as Map).cast<String, dynamic>(),
            ),
          )
          .toList(growable: false),
      signature: requiredString(json, 'signature'),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  static CloudDeviceList? fromOptionalJson(Object? value) {
    if (value is Map) {
      return CloudDeviceList.fromJson(value.cast<String, dynamic>());
    }
    return null;
  }
}

class CloudDeviceKeyMaterial {
  const CloudDeviceKeyMaterial({
    required this.accountId,
    required this.serverOrigin,
    required this.deviceId,
    required this.deviceSigningPrivateKey,
    required this.deviceSigningPublicKey,
    required this.certificate,
  });

  final String accountId;
  final String serverOrigin;
  final String deviceId;
  final String deviceSigningPrivateKey;
  final String deviceSigningPublicKey;
  final CloudDeviceCertificate certificate;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'accountId': accountId,
        'serverOrigin': serverOrigin,
        'deviceId': deviceId,
        'deviceSigningPrivateKey': deviceSigningPrivateKey,
        'deviceSigningPublicKey': deviceSigningPublicKey,
        'certificate': certificate.toJson(),
      };

  factory CloudDeviceKeyMaterial.fromJson(Map<String, dynamic> json) {
    return CloudDeviceKeyMaterial(
      accountId: requiredString(json, 'accountId'),
      serverOrigin: requiredString(json, 'serverOrigin'),
      deviceId: requiredString(json, 'deviceId'),
      deviceSigningPrivateKey: requiredString(json, 'deviceSigningPrivateKey'),
      deviceSigningPublicKey: requiredString(json, 'deviceSigningPublicKey'),
      certificate: CloudDeviceCertificate.fromJson(
        asStringKeyMap(json['certificate'], 'certificate'),
      ),
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
      newKeyAgreementPublicKey: requiredString(
        json,
        'newKeyAgreementPublicKey',
      ),
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
    required this.keyEpoch,
    required this.updatedAt,
  });

  final String conversationId;
  final String type;
  final List<String> memberIds;
  final Map<String, dynamic> memberKeys;
  final int keyEpoch;
  final DateTime updatedAt;

  factory CloudConversation.fromJson(Map<String, dynamic> json) {
    return CloudConversation(
      conversationId: requiredString(json, 'conversationId'),
      type: requiredString(json, 'type'),
      memberIds: ((json['memberIds'] as List?) ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
      memberKeys: ((json['memberKeys'] as Map?) ?? const {}).map(
        (key, value) => MapEntry(key.toString(), value),
      ),
      keyEpoch: json['keyEpoch'] is int ? json['keyEpoch'] as int : 1,
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
    this.requiresDeviceSignature = false,
  });

  final String accountId;
  final String conversationId;
  final String senderUserId;
  final String senderDeviceId;
  final int lastCounter;
  final String lastMessageHash;
  final bool requiresDeviceSignature;

  String get key => '$accountId|$conversationId|$senderUserId|$senderDeviceId';

  Map<String, dynamic> toJson() => {
        'v': 1,
        'accountId': accountId,
        'conversationId': conversationId,
        'senderUserId': senderUserId,
        'senderDeviceId': senderDeviceId,
        'lastCounter': lastCounter,
        'lastMessageHash': lastMessageHash,
        'requiresDeviceSignature': requiresDeviceSignature,
      };

  factory CloudMessageReplayState.fromJson(Map<String, dynamic> json) {
    return CloudMessageReplayState(
      accountId: requiredString(json, 'accountId'),
      conversationId: requiredString(json, 'conversationId'),
      senderUserId: requiredString(json, 'senderUserId'),
      senderDeviceId: requiredString(json, 'senderDeviceId'),
      lastCounter: requiredInt(json, 'lastCounter'),
      lastMessageHash: requiredString(json, 'lastMessageHash'),
      requiresDeviceSignature: json['requiresDeviceSignature'] == true,
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
      identityRotationProof: IdentityRotationProof.fromOptionalJson(
        json['identityRotationProof'],
      ),
      conversationKeys: ((json['conversationKeys'] as Map?) ?? const {}).map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
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
