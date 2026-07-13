import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
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
  });

  final String messageId;
  final PlainPayload payload;
  final DateTime createdAt;
}

class CloudCrypto {
  CloudCrypto();

  static const vaultAad = 'secure-p2p-cloud-vault/v1';
  static const keyWrapAad = 'secure-p2p-cloud-keywrap/v1';
  static const messageProtocol = 'secure-p2p-cloud-message/v1';
  static const identityBindingProtocol = 'secure-p2p-identity-key-binding/v2';

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
    required String conversationKey,
    required PlainPayload payload,
  }) async {
    final messageId = _uuid.v4();
    final createdAt = DateTime.now().toUtc().toIso8601String();
    final aad = {
      'v': 1,
      'protocol': messageProtocol,
      'conversationId': conversationId,
      'messageId': messageId,
      'senderUserId': senderUserId,
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
    return {
      'v': 1,
      'protocol': messageProtocol,
      'messageId': messageId,
      'aad': aad,
      'nonce': b64(box.nonce),
      'ciphertext': b64(box.cipherText),
      'mac': b64(box.mac.bytes),
      'compression': 'zlib',
    };
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
      payload: PlainPayload.fromJson(
        asStringKeyMap(clear['payload'], 'payload'),
      ),
    );
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
