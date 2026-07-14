import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto_hash;
import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import '../models/cloud_account.dart';
import '../models/message.dart';
import 'codec.dart';

class CloudDecryptedMessage {
  const CloudDecryptedMessage({
    required this.messageId,
    required this.payload,
    required this.createdAt,
    required this.senderUserId,
    required this.senderDeviceId,
    required this.messageCounter,
    required this.previousMessageHash,
    required this.messageHash,
  });

  final String messageId;
  final PlainPayload payload;
  final DateTime createdAt;
  final String senderUserId;
  final String senderDeviceId;
  final int? messageCounter;
  final String previousMessageHash;
  final String messageHash;
}

class CloudIdentityRotation {
  const CloudIdentityRotation({
    required this.vault,
    required this.proof,
  });

  final CloudVault vault;
  final IdentityRotationProof proof;
}

class CloudCrypto {
  CloudCrypto();

  static const vaultAad = 'secure-p2p-cloud-vault/v1';
  static const keyWrapAad = 'secure-p2p-cloud-keywrap/v1';
  static const messageProtocol = 'secure-p2p-cloud-message/v1';
  static const messageChainProtocol = 'secure-chat/message-chain/v1';
  static const identityBindingProtocol = 'secure-p2p-identity-key-binding/v2';
  static const identityRotationProtocol = 'secure-p2p-identity-rotation/v1';
  static const deviceCertificateProtocol = 'secure-chat/device-certificate/v1';
  static const deviceMessageProtocol = 'secure-chat/device-message/v1';
  static const deviceListProtocol = 'secure-chat/device-list/v1';

  final AesGcm _aead = AesGcm.with256bits();
  final X25519 _x25519 = X25519();
  final Ed25519 _ed25519 = Ed25519();
  final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final Uuid _uuid = const Uuid();

  Future<String> deriveVaultKey({
    required String vaultSecret,
    required String salt,
  }) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 310000,
      bits: 256,
    );
    final key = await kdf.deriveKey(
      secretKey: SecretKey(utf8Bytes(vaultSecret)),
      nonce: unb64(salt),
    );
    return b64(await key.extractBytes());
  }

  Future<CloudVault> createVault({
    String accountId = '',
    String serverOrigin = '',
  }) async {
    final keyPair = await _x25519.newKeyPair();
    final privateBytes = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    final identityKeyPair = await _ed25519.newKeyPair();
    final identityPrivateBytes = await identityKeyPair.extractPrivateKeyBytes();
    final identityPublicKey = await identityKeyPair.extractPublicKey();
    final identityPublicKeyBase64 = b64(identityPublicKey.bytes);
    final keyAgreementPublicKeyBase64 = b64(publicKey.bytes);
    final signature = await _signKeyAgreementPublicKey(
      accountId: accountId,
      serverOrigin: serverOrigin,
      identityPrivateKey: b64(identityPrivateBytes),
      identityPublicKey: identityPublicKeyBase64,
      keyAgreementPublicKey: keyAgreementPublicKeyBase64,
    );
    return CloudVault(
      keyAgreementPrivateKey: b64(privateBytes),
      keyAgreementPublicKey: keyAgreementPublicKeyBase64,
      identityPrivateKey: b64(identityPrivateBytes),
      identityPublicKey: identityPublicKeyBase64,
      keyAgreementPublicKeySignature: signature,
      conversationKeys: const {},
    );
  }

  Future<CloudVault> ensureSignedIdentity(
    CloudVault vault, {
    required String accountId,
    required String serverOrigin,
  }) async {
    if (vault.identityPrivateKey.isNotEmpty &&
        vault.identityPublicKey.isNotEmpty &&
        vault.keyAgreementPublicKeySignature.isNotEmpty) {
      final valid = await verifyKeyAgreementSignature(
        accountId: accountId,
        serverOrigin: serverOrigin,
        identityPublicKey: vault.identityPublicKey,
        keyAgreementPublicKey: vault.keyAgreementPublicKey,
        signature: vault.keyAgreementPublicKeySignature,
      );
      if (valid) return vault;

      final signature = await _signKeyAgreementPublicKey(
        accountId: accountId,
        serverOrigin: serverOrigin,
        identityPrivateKey: vault.identityPrivateKey,
        identityPublicKey: vault.identityPublicKey,
        keyAgreementPublicKey: vault.keyAgreementPublicKey,
      );
      return vault.copyWith(keyAgreementPublicKeySignature: signature);
    }

    if (vault.identityPublicKey.isNotEmpty &&
        vault.identityPrivateKey.isEmpty) {
      throw StateError(
        'Vault zawiera publiczna tozsamosc, ale nie zawiera prywatnego klucza podpisu.',
      );
    }

    final identityKeyPair = await _ed25519.newKeyPair();
    final identityPrivateBytes = await identityKeyPair.extractPrivateKeyBytes();
    final identityPublicKey = await identityKeyPair.extractPublicKey();
    final identityPrivateKeyBase64 = b64(identityPrivateBytes);
    final identityPublicKeyBase64 = b64(identityPublicKey.bytes);
    final signature = await _signKeyAgreementPublicKey(
      accountId: accountId,
      serverOrigin: serverOrigin,
      identityPrivateKey: identityPrivateKeyBase64,
      identityPublicKey: identityPublicKeyBase64,
      keyAgreementPublicKey: vault.keyAgreementPublicKey,
    );
    return vault.copyWith(
      identityPrivateKey: identityPrivateKeyBase64,
      identityPublicKey: identityPublicKeyBase64,
      keyAgreementPublicKeySignature: signature,
    );
  }

  Future<CloudDeviceKeyMaterial> createDeviceKeyMaterial({
    required CloudVault vault,
    required String accountId,
    required String serverOrigin,
    required String deviceId,
  }) async {
    if (vault.identityPrivateKey.isEmpty || vault.identityPublicKey.isEmpty) {
      throw StateError(
        'Brak klucza tozsamosci konta do podpisania certyfikatu urzadzenia.',
      );
    }
    final deviceKeyPair = await _ed25519.newKeyPair();
    final devicePrivateBytes = await deviceKeyPair.extractPrivateKeyBytes();
    final devicePublicKey = await deviceKeyPair.extractPublicKey();
    final devicePublicKeyBase64 = b64(devicePublicKey.bytes);
    final createdAt = DateTime.now().toUtc();
    const deviceEpoch = 1;
    final signature = await _ed25519.sign(
      _deviceCertificateBytes(
        accountId: accountId,
        serverOrigin: serverOrigin,
        deviceId: deviceId,
        deviceSigningPublicKey: devicePublicKeyBase64,
        deviceEpoch: deviceEpoch,
        createdAt: createdAt,
      ),
      keyPair: SimpleKeyPairData(
        unb64(vault.identityPrivateKey),
        publicKey: SimplePublicKey(
          unb64(vault.identityPublicKey),
          type: KeyPairType.ed25519,
        ),
        type: KeyPairType.ed25519,
      ),
    );
    final certificate = CloudDeviceCertificate(
      accountId: accountId,
      serverOrigin: serverOrigin,
      deviceId: deviceId,
      deviceSigningPublicKey: devicePublicKeyBase64,
      deviceEpoch: deviceEpoch,
      createdAt: createdAt,
      signature: b64(signature.bytes),
    );
    return CloudDeviceKeyMaterial(
      accountId: accountId,
      serverOrigin: serverOrigin,
      deviceId: deviceId,
      deviceSigningPrivateKey: b64(devicePrivateBytes),
      deviceSigningPublicKey: devicePublicKeyBase64,
      certificate: certificate,
    );
  }

  Future<bool> verifyKeyAgreementSignature({
    required String accountId,
    required String serverOrigin,
    required String identityPublicKey,
    required String keyAgreementPublicKey,
    required String signature,
  }) async {
    if (identityPublicKey.isEmpty ||
        keyAgreementPublicKey.isEmpty ||
        signature.isEmpty) {
      return false;
    }
    try {
      return _ed25519.verify(
        _keyAgreementBindingBytes(
          accountId: accountId,
          serverOrigin: serverOrigin,
          identityPublicKey: identityPublicKey,
          keyAgreementPublicKey: keyAgreementPublicKey,
        ),
        signature: Signature(
          unb64(signature),
          publicKey: SimplePublicKey(
            unb64(identityPublicKey),
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  Future<CloudIdentityRotation> rotateIdentity({
    required CloudVault vault,
    required String accountId,
    required String serverOrigin,
  }) async {
    if (vault.identityPrivateKey.isEmpty || vault.identityPublicKey.isEmpty) {
      throw StateError('Brak starego klucza tozsamosci do podpisania rotacji.');
    }

    final oldIdentityPrivateKey = vault.identityPrivateKey;
    final oldIdentityPublicKey = vault.identityPublicKey;
    final newIdentityKeyPair = await _ed25519.newKeyPair();
    final newIdentityPrivateBytes =
        await newIdentityKeyPair.extractPrivateKeyBytes();
    final newIdentityPublicKey = await newIdentityKeyPair.extractPublicKey();
    final newIdentityPrivateKeyBase64 = b64(newIdentityPrivateBytes);
    final newIdentityPublicKeyBase64 = b64(newIdentityPublicKey.bytes);
    final keyAgreementSignature = await _signKeyAgreementPublicKey(
      accountId: accountId,
      serverOrigin: serverOrigin,
      identityPrivateKey: newIdentityPrivateKeyBase64,
      identityPublicKey: newIdentityPublicKeyBase64,
      keyAgreementPublicKey: vault.keyAgreementPublicKey,
    );
    final rotatedAt = DateTime.now().toUtc();
    final previousProof = vault.identityRotationProof;
    final rotationEpoch = (previousProof?.rotationEpoch ?? 0) + 1;
    final previousRotationHash = previousProof?.rotationHash ?? '';
    final rotationSignature = await _signIdentityRotation(
      accountId: accountId,
      serverOrigin: serverOrigin,
      oldIdentityPrivateKey: oldIdentityPrivateKey,
      oldIdentityPublicKey: oldIdentityPublicKey,
      newIdentityPublicKey: newIdentityPublicKeyBase64,
      newKeyAgreementPublicKey: vault.keyAgreementPublicKey,
      rotationEpoch: rotationEpoch,
      previousRotationHash: previousRotationHash,
      rotatedAt: rotatedAt,
    );
    final confirmationSignature = await _signIdentityRotationConfirmation(
      accountId: accountId,
      serverOrigin: serverOrigin,
      newIdentityPrivateKey: newIdentityPrivateKeyBase64,
      newIdentityPublicKey: newIdentityPublicKeyBase64,
      oldIdentityPublicKey: oldIdentityPublicKey,
      newKeyAgreementPublicKey: vault.keyAgreementPublicKey,
      rotationEpoch: rotationEpoch,
      previousRotationHash: previousRotationHash,
      rotatedAt: rotatedAt,
    );
    final proof = IdentityRotationProof(
      rotationEpoch: rotationEpoch,
      previousRotationHash: previousRotationHash,
      oldIdentityPublicKey: oldIdentityPublicKey,
      newIdentityPublicKey: newIdentityPublicKeyBase64,
      newKeyAgreementPublicKey: vault.keyAgreementPublicKey,
      signature: rotationSignature,
      newIdentityConfirmationSignature: confirmationSignature,
      rotatedAt: rotatedAt,
    );

    return CloudIdentityRotation(
      vault: vault.copyWith(
        identityPrivateKey: newIdentityPrivateKeyBase64,
        identityPublicKey: newIdentityPublicKeyBase64,
        keyAgreementPublicKeySignature: keyAgreementSignature,
        identityRotationProof: proof,
      ),
      proof: proof,
    );
  }

  Future<bool> verifyIdentityRotationProof({
    required String accountId,
    required String serverOrigin,
    required IdentityRotationProof proof,
  }) async {
    if (proof.oldIdentityPublicKey.isEmpty ||
        proof.newIdentityPublicKey.isEmpty ||
        proof.newKeyAgreementPublicKey.isEmpty ||
        proof.signature.isEmpty ||
        proof.newIdentityConfirmationSignature.isEmpty ||
        proof.rotationEpoch < 1) {
      return false;
    }
    try {
      final rotationBytes = _identityRotationBytes(
        accountId: accountId,
        serverOrigin: serverOrigin,
        oldIdentityPublicKey: proof.oldIdentityPublicKey,
        newIdentityPublicKey: proof.newIdentityPublicKey,
        newKeyAgreementPublicKey: proof.newKeyAgreementPublicKey,
        rotationEpoch: proof.rotationEpoch,
        previousRotationHash: proof.previousRotationHash,
        rotatedAt: proof.rotatedAt,
      );
      final oldKeyValid = await _ed25519.verify(
        rotationBytes,
        signature: Signature(
          unb64(proof.signature),
          publicKey: SimplePublicKey(
            unb64(proof.oldIdentityPublicKey),
            type: KeyPairType.ed25519,
          ),
        ),
      );
      if (!oldKeyValid) return false;
      return _ed25519.verify(
        rotationBytes,
        signature: Signature(
          unb64(proof.newIdentityConfirmationSignature),
          publicKey: SimplePublicKey(
            unb64(proof.newIdentityPublicKey),
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  Future<bool> verifyDeviceCertificate({
    required String accountId,
    required String serverOrigin,
    required String identityPublicKey,
    required CloudDeviceCertificate certificate,
  }) async {
    if (certificate.accountId != accountId ||
        certificate.serverOrigin != serverOrigin ||
        certificate.deviceId.isEmpty ||
        certificate.deviceSigningPublicKey.isEmpty ||
        certificate.signature.isEmpty ||
        certificate.deviceEpoch < 1) {
      return false;
    }
    try {
      return _ed25519.verify(
        _deviceCertificateBytes(
          accountId: certificate.accountId,
          serverOrigin: certificate.serverOrigin,
          deviceId: certificate.deviceId,
          deviceSigningPublicKey: certificate.deviceSigningPublicKey,
          deviceEpoch: certificate.deviceEpoch,
          createdAt: certificate.createdAt,
        ),
        signature: Signature(
          unb64(certificate.signature),
          publicKey: SimplePublicKey(
            unb64(identityPublicKey),
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  Future<CloudDeviceList> signDeviceList({
    required CloudVault vault,
    required String accountId,
    required String serverOrigin,
    required CloudDeviceList? previousList,
    required List<CloudDeviceListEntry> devices,
    required List<CloudRevokedDevice> revokedDevices,
  }) async {
    if (vault.identityPrivateKey.isEmpty || vault.identityPublicKey.isEmpty) {
      throw StateError('Brak klucza tozsamosci do podpisania listy urzadzen.');
    }
    final updatedAt = DateTime.now().toUtc();
    final deviceListEpoch = (previousList?.deviceListEpoch ?? 0) + 1;
    final previousDeviceListHash = previousList?.deviceListHash ?? '';
    final identityRotationEpoch =
        vault.identityRotationProof?.rotationEpoch ?? 0;
    final signature = await _ed25519.sign(
      canonicalJsonBytes(_deviceListPayload(
        accountId: accountId,
        serverOrigin: serverOrigin,
        deviceListEpoch: deviceListEpoch,
        previousDeviceListHash: previousDeviceListHash,
        identityRotationEpoch: identityRotationEpoch,
        devices: devices,
        revokedDevices: revokedDevices,
        updatedAt: updatedAt,
      )),
      keyPair: SimpleKeyPairData(
        unb64(vault.identityPrivateKey),
        publicKey: SimplePublicKey(
          unb64(vault.identityPublicKey),
          type: KeyPairType.ed25519,
        ),
        type: KeyPairType.ed25519,
      ),
    );
    return CloudDeviceList(
      accountId: accountId,
      serverOrigin: serverOrigin,
      deviceListEpoch: deviceListEpoch,
      previousDeviceListHash: previousDeviceListHash,
      identityRotationEpoch: identityRotationEpoch,
      devices: devices,
      revokedDevices: revokedDevices,
      signature: b64(signature.bytes),
      updatedAt: updatedAt,
    );
  }

  Future<bool> verifyDeviceList({
    required String accountId,
    required String serverOrigin,
    required String identityPublicKey,
    required CloudDeviceList deviceList,
  }) async {
    if (deviceList.accountId != accountId ||
        deviceList.serverOrigin != serverOrigin ||
        deviceList.deviceListEpoch < 1 ||
        deviceList.signature.isEmpty) {
      return false;
    }
    final seenDevices = <String>{};
    for (final device in deviceList.devices) {
      if (!seenDevices.add(device.deviceId) ||
          device.deviceSigningPublicKey.isEmpty ||
          device.certificateHash.isEmpty ||
          device.deviceEpoch < 1) {
        return false;
      }
    }
    try {
      return _ed25519.verify(
        canonicalJsonBytes(deviceList.signedPayload()),
        signature: Signature(
          unb64(deviceList.signature),
          publicKey: SimplePublicKey(
            unb64(identityPublicKey),
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  CloudDeviceListEntry deviceListEntryForCertificate(
    CloudDeviceCertificate certificate,
  ) {
    return CloudDeviceListEntry(
      deviceId: certificate.deviceId,
      deviceSigningPublicKey: certificate.deviceSigningPublicKey,
      certificateHash: certificate.certificateHash,
      addedAt: certificate.createdAt,
      deviceEpoch: certificate.deviceEpoch,
    );
  }

  bool hasDeviceSignature(Map<String, dynamic> payload) {
    return payload['deviceCertificate'] is Map &&
        payload['deviceSignature'] is String &&
        (payload['deviceSignature'] as String).isNotEmpty;
  }

  Future<bool> verifyDeviceMessageSignature({
    required String accountId,
    required String serverOrigin,
    required String identityPublicKey,
    required String senderDeviceId,
    required Map<String, dynamic> payload,
  }) async {
    final rawCertificate = payload['deviceCertificate'];
    final signature = payload['deviceSignature'];
    if (rawCertificate is! Map || signature is! String || signature.isEmpty) {
      return false;
    }
    try {
      final certificate = CloudDeviceCertificate.fromJson(
        rawCertificate.cast<String, dynamic>(),
      );
      if (certificate.deviceId != senderDeviceId) return false;
      final certificateValid = await verifyDeviceCertificate(
        accountId: accountId,
        serverOrigin: serverOrigin,
        identityPublicKey: identityPublicKey,
        certificate: certificate,
      );
      if (!certificateValid) return false;

      final unsignedEnvelope = Map<String, dynamic>.of(payload)
        ..remove('deviceCertificate')
        ..remove('deviceSignature');
      final digest = _deviceMessageDigest(unsignedEnvelope);
      return _ed25519.verify(
        digest,
        signature: Signature(
          unb64(signature),
          publicKey: SimplePublicKey(
            unb64(certificate.deviceSigningPublicKey),
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  bool isNextIdentityRotation({
    required IdentityRotationProof? previousProof,
    required IdentityRotationProof nextProof,
  }) {
    final expectedEpoch = (previousProof?.rotationEpoch ?? 0) + 1;
    final expectedPreviousHash = previousProof?.rotationHash ?? '';
    return nextProof.rotationEpoch == expectedEpoch &&
        nextProof.previousRotationHash == expectedPreviousHash;
  }

  Future<String> _signKeyAgreementPublicKey({
    required String accountId,
    required String serverOrigin,
    required String identityPrivateKey,
    required String identityPublicKey,
    required String keyAgreementPublicKey,
  }) async {
    final signature = await _ed25519.sign(
      _keyAgreementBindingBytes(
        accountId: accountId,
        serverOrigin: serverOrigin,
        identityPublicKey: identityPublicKey,
        keyAgreementPublicKey: keyAgreementPublicKey,
      ),
      keyPair: SimpleKeyPairData(
        unb64(identityPrivateKey),
        publicKey: SimplePublicKey(
          unb64(identityPublicKey),
          type: KeyPairType.ed25519,
        ),
        type: KeyPairType.ed25519,
      ),
    );
    return b64(signature.bytes);
  }

  Future<String> _signIdentityRotation({
    required String accountId,
    required String serverOrigin,
    required String oldIdentityPrivateKey,
    required String oldIdentityPublicKey,
    required String newIdentityPublicKey,
    required String newKeyAgreementPublicKey,
    required int rotationEpoch,
    required String previousRotationHash,
    required DateTime rotatedAt,
  }) async {
    final signature = await _ed25519.sign(
      _identityRotationBytes(
        accountId: accountId,
        serverOrigin: serverOrigin,
        oldIdentityPublicKey: oldIdentityPublicKey,
        newIdentityPublicKey: newIdentityPublicKey,
        newKeyAgreementPublicKey: newKeyAgreementPublicKey,
        rotationEpoch: rotationEpoch,
        previousRotationHash: previousRotationHash,
        rotatedAt: rotatedAt,
      ),
      keyPair: SimpleKeyPairData(
        unb64(oldIdentityPrivateKey),
        publicKey: SimplePublicKey(
          unb64(oldIdentityPublicKey),
          type: KeyPairType.ed25519,
        ),
        type: KeyPairType.ed25519,
      ),
    );
    return b64(signature.bytes);
  }

  Future<String> _signIdentityRotationConfirmation({
    required String accountId,
    required String serverOrigin,
    required String newIdentityPrivateKey,
    required String newIdentityPublicKey,
    required String oldIdentityPublicKey,
    required String newKeyAgreementPublicKey,
    required int rotationEpoch,
    required String previousRotationHash,
    required DateTime rotatedAt,
  }) async {
    final signature = await _ed25519.sign(
      _identityRotationBytes(
        accountId: accountId,
        serverOrigin: serverOrigin,
        oldIdentityPublicKey: oldIdentityPublicKey,
        newIdentityPublicKey: newIdentityPublicKey,
        newKeyAgreementPublicKey: newKeyAgreementPublicKey,
        rotationEpoch: rotationEpoch,
        previousRotationHash: previousRotationHash,
        rotatedAt: rotatedAt,
      ),
      keyPair: SimpleKeyPairData(
        unb64(newIdentityPrivateKey),
        publicKey: SimplePublicKey(
          unb64(newIdentityPublicKey),
          type: KeyPairType.ed25519,
        ),
        type: KeyPairType.ed25519,
      ),
    );
    return b64(signature.bytes);
  }

  Uint8List _keyAgreementBindingBytes({
    required String accountId,
    required String serverOrigin,
    required String identityPublicKey,
    required String keyAgreementPublicKey,
  }) {
    return canonicalJsonBytes({
      'v': 1,
      'protocol': identityBindingProtocol,
      'accountId': accountId,
      'serverOrigin': serverOrigin,
      'identityPublicKey': identityPublicKey,
      'keyAgreementPublicKey': keyAgreementPublicKey,
    });
  }

  Uint8List _identityRotationBytes({
    required String accountId,
    required String serverOrigin,
    required String oldIdentityPublicKey,
    required String newIdentityPublicKey,
    required String newKeyAgreementPublicKey,
    required int rotationEpoch,
    required String previousRotationHash,
    required DateTime rotatedAt,
  }) {
    return canonicalJsonBytes({
      'v': 1,
      'protocol': identityRotationProtocol,
      'accountId': accountId,
      'serverOrigin': serverOrigin,
      'rotationEpoch': rotationEpoch,
      'previousRotationHash': previousRotationHash,
      'oldIdentityPublicKey': oldIdentityPublicKey,
      'newIdentityPublicKey': newIdentityPublicKey,
      'newKeyAgreementPublicKey': newKeyAgreementPublicKey,
      'rotatedAt': rotatedAt.toUtc().toIso8601String(),
    });
  }

  Uint8List _deviceCertificateBytes({
    required String accountId,
    required String serverOrigin,
    required String deviceId,
    required String deviceSigningPublicKey,
    required int deviceEpoch,
    required DateTime createdAt,
  }) {
    return canonicalJsonBytes({
      'v': 1,
      'protocol': deviceCertificateProtocol,
      'accountId': accountId,
      'serverOrigin': serverOrigin,
      'deviceId': deviceId,
      'deviceSigningPublicKey': deviceSigningPublicKey,
      'deviceEpoch': deviceEpoch,
      'createdAt': createdAt.toUtc().toIso8601String(),
    });
  }

  Uint8List _deviceMessageDigest(Map<String, dynamic> unsignedEnvelope) {
    return Uint8List.fromList(
      crypto_hash.sha256
          .convert(canonicalJsonBytes({
            'v': 1,
            'protocol': deviceMessageProtocol,
            'envelope': unsignedEnvelope,
          }))
          .bytes,
    );
  }

  Map<String, dynamic> _deviceListPayload({
    required String accountId,
    required String serverOrigin,
    required int deviceListEpoch,
    required String previousDeviceListHash,
    required int identityRotationEpoch,
    required List<CloudDeviceListEntry> devices,
    required List<CloudRevokedDevice> revokedDevices,
    required DateTime updatedAt,
  }) {
    return {
      'v': 1,
      'protocol': deviceListProtocol,
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
  }

  Future<Map<String, dynamic>> encryptVault(
    CloudVault vault,
    String vaultKey,
  ) async {
    final nonce = secureRandomBytes(12);
    final box = await _aead.encrypt(
      utf8Bytes(jsonEncode(vault.toJson())),
      secretKey: SecretKey(unb64(vaultKey)),
      nonce: nonce,
      aad: utf8Bytes(vaultAad),
    );
    return {
      'v': 1,
      'algorithm': 'AES-256-GCM',
      'nonce': b64(box.nonce),
      'ciphertext': b64(box.cipherText),
      'mac': b64(box.mac.bytes),
    };
  }

  Future<CloudVault> decryptVault(
    Map<String, dynamic> encryptedVault,
    String vaultKey,
  ) async {
    final box = SecretBox(
      unb64(encryptedVault['ciphertext'] as String),
      nonce: unb64(encryptedVault['nonce'] as String),
      mac: Mac(unb64(encryptedVault['mac'] as String)),
    );
    final clear = await _aead.decrypt(
      box,
      secretKey: SecretKey(unb64(vaultKey)),
      aad: utf8Bytes(vaultAad),
    );
    return CloudVault.fromJson(
        jsonDecode(utf8.decode(clear)) as Map<String, dynamic>);
  }

  Future<String> newConversationKey() async {
    return b64(secureRandomBytes(32));
  }

  Future<Map<String, dynamic>> wrapConversationKey({
    required CloudVault vault,
    required String senderUserId,
    required String recipientUserId,
    required String recipientPublicKey,
    required String conversationKey,
  }) async {
    final wrappingKey = await _deriveWrappingKey(
      vault: vault,
      otherPublicKey: recipientPublicKey,
      leftUserId: senderUserId,
      rightUserId: recipientUserId,
    );
    final nonce = secureRandomBytes(12);
    final aad = canonicalJsonBytes({
      'protocol': keyWrapAad,
      'senderUserId': senderUserId,
      'recipientUserId': recipientUserId,
      'senderPublicKey': vault.keyAgreementPublicKey,
    });
    final box = await _aead.encrypt(
      unb64(conversationKey),
      secretKey: wrappingKey,
      nonce: nonce,
      aad: aad,
    );
    return {
      'v': 1,
      'senderUserId': senderUserId,
      'recipientUserId': recipientUserId,
      'senderPublicKey': vault.keyAgreementPublicKey,
      'nonce': b64(box.nonce),
      'ciphertext': b64(box.cipherText),
      'mac': b64(box.mac.bytes),
    };
  }

  Future<String> unwrapConversationKey({
    required CloudVault vault,
    required String localUserId,
    required Map<String, dynamic> envelope,
  }) async {
    final senderUserId = requiredString(envelope, 'senderUserId');
    final senderPublicKey = requiredString(envelope, 'senderPublicKey');
    final wrappingKey = await _deriveWrappingKey(
      vault: vault,
      otherPublicKey: senderPublicKey,
      leftUserId: senderUserId,
      rightUserId: localUserId,
    );
    final aad = canonicalJsonBytes({
      'protocol': keyWrapAad,
      'senderUserId': senderUserId,
      'recipientUserId': localUserId,
      'senderPublicKey': senderPublicKey,
    });
    final box = SecretBox(
      unb64(requiredString(envelope, 'ciphertext')),
      nonce: unb64(requiredString(envelope, 'nonce')),
      mac: Mac(unb64(requiredString(envelope, 'mac'))),
    );
    final clear = await _aead.decrypt(
      box,
      secretKey: wrappingKey,
      aad: aad,
    );
    return b64(clear);
  }

  Future<Map<String, dynamic>> encryptMessage({
    required String conversationId,
    required String senderUserId,
    required String senderDeviceId,
    required int messageCounter,
    required String previousMessageHash,
    required String conversationKey,
    required CloudDeviceKeyMaterial deviceKey,
    required PlainPayload payload,
  }) async {
    final messageId = _uuid.v4();
    final createdAt = DateTime.now().toUtc().toIso8601String();
    final aad = {
      'v': 1,
      'protocol': messageProtocol,
      'protocolVersion': 2,
      'conversationId': conversationId,
      'messageId': messageId,
      'senderUserId': senderUserId,
      'senderDeviceId': senderDeviceId,
      'messageCounter': messageCounter,
      'previousMessageHash': previousMessageHash,
      'contentType': payload.type.name,
      'createdAt': createdAt,
    };
    final clear = utf8Bytes(canonicalJson({
      'v': 1,
      'messageId': messageId,
      'createdAt': createdAt,
      'payload': payload.toJson(),
    }));
    final compressed = ZLibEncoder().encode(clear);
    final nonce = secureRandomBytes(12);
    final box = await _aead.encrypt(
      compressed,
      secretKey: SecretKey(unb64(conversationKey)),
      nonce: nonce,
      aad: canonicalJsonBytes(aad),
    );
    final unsignedEnvelope = {
      'v': 1,
      'protocol': messageProtocol,
      'messageId': messageId,
      'aad': aad,
      'nonce': b64(box.nonce),
      'ciphertext': b64(box.cipherText),
      'mac': b64(box.mac.bytes),
      'compression': 'zlib',
    };
    final signature = await _ed25519.sign(
      _deviceMessageDigest(unsignedEnvelope),
      keyPair: SimpleKeyPairData(
        unb64(deviceKey.deviceSigningPrivateKey),
        publicKey: SimplePublicKey(
          unb64(deviceKey.deviceSigningPublicKey),
          type: KeyPairType.ed25519,
        ),
        type: KeyPairType.ed25519,
      ),
    );
    return {
      ...unsignedEnvelope,
      'deviceCertificate': deviceKey.certificate.toJson(),
      'deviceSignature': b64(signature.bytes),
    };
  }

  String get cloudMessageGenesisHash {
    return crypto_hash.sha256
        .convert(canonicalJsonBytes({
          'v': 1,
          'protocol': messageChainProtocol,
          'type': 'genesis',
        }))
        .toString();
  }

  String cloudMessageHash(Map<String, dynamic> payload) {
    return crypto_hash.sha256
        .convert(canonicalJsonBytes({
          'v': 1,
          'protocol': messageChainProtocol,
          'type': 'message',
          'message': payload,
        }))
        .toString();
  }

  Future<CloudDecryptedMessage> decryptMessage({
    required String conversationId,
    required String conversationKey,
    required Map<String, dynamic> payload,
  }) async {
    if (payload['protocol'] != messageProtocol) {
      throw const FormatException('Niepoprawny protokol wiadomosci cloud.');
    }
    final aad = asStringKeyMap(payload['aad'], 'aad');
    if (aad['conversationId'] != conversationId ||
        aad['messageId'] != payload['messageId']) {
      throw const FormatException('AAD wiadomosci cloud nie pasuje.');
    }
    final box = SecretBox(
      unb64(requiredString(payload, 'ciphertext')),
      nonce: unb64(requiredString(payload, 'nonce')),
      mac: Mac(unb64(requiredString(payload, 'mac'))),
    );
    final compressed = await _aead.decrypt(
      box,
      secretKey: SecretKey(unb64(conversationKey)),
      aad: canonicalJsonBytes(aad),
    );
    final clearBytes = ZLibDecoder().decodeBytes(compressed);
    final clear = asStringKeyMap(
      jsonDecode(utf8.decode(clearBytes)),
      'cloudMessage',
    );
    return CloudDecryptedMessage(
      messageId: requiredString(clear, 'messageId'),
      createdAt: DateTime.parse(requiredString(clear, 'createdAt')),
      senderUserId: aad['senderUserId']?.toString() ?? '',
      senderDeviceId: aad['senderDeviceId']?.toString() ?? '',
      messageCounter: _optionalInt(aad['messageCounter']),
      previousMessageHash: aad['previousMessageHash']?.toString() ?? '',
      messageHash: cloudMessageHash(payload),
      payload: PlainPayload.fromJson(
        asStringKeyMap(clear['payload'], 'payload'),
      ),
    );
  }

  int? _optionalInt(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    return int.tryParse(value.toString());
  }

  Future<SecretKey> _deriveWrappingKey({
    required CloudVault vault,
    required String otherPublicKey,
    required String leftUserId,
    required String rightUserId,
  }) async {
    final privateKey = SimpleKeyPairData(
      unb64(vault.keyAgreementPrivateKey),
      publicKey: SimplePublicKey(
        unb64(vault.keyAgreementPublicKey),
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );
    final shared = await _x25519.sharedSecretKey(
      keyPair: privateKey,
      remotePublicKey: SimplePublicKey(
        unb64(otherPublicKey),
        type: KeyPairType.x25519,
      ),
    );
    final ids = [leftUserId, rightUserId]..sort();
    return _hkdf.deriveKey(
      secretKey: shared,
      nonce: utf8Bytes(ids.join(':')),
      info: utf8Bytes(keyWrapAad),
    );
  }
}
