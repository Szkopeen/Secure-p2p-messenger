import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto_hash;
import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import '../models/contact.dart';
import '../models/encrypted_packet.dart';
import '../models/identity.dart';
import '../models/message.dart';
import '../models/session.dart';
import 'codec.dart';

class HandshakeInitResult {
  const HandshakeInitResult({
    required this.pendingSession,
    required this.wirePayload,
  });

  final PendingSession pendingSession;
  final Map<String, dynamic> wirePayload;
}

class HandshakeAcceptResult {
  const HandshakeAcceptResult({
    required this.session,
    required this.wirePayload,
  });

  final SessionState session;
  final Map<String, dynamic> wirePayload;
}

class DecryptedPayload {
  const DecryptedPayload({
    required this.messageId,
    required this.payload,
    required this.createdAt,
  });

  final String messageId;
  final PlainPayload payload;
  final DateTime createdAt;
}

class CryptoService {
  CryptoService();

  static const protocol = 'secure-p2p-e2ee/v1';

  final Ed25519 _identityAlgorithm = Ed25519();
  final X25519 _keyAgreement = X25519();
  final AesGcm _aead = AesGcm.with256bits();
  final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final Uuid _uuid = const Uuid();

  Future<IdentityKeyMaterial> createIdentity(String userId) async {
    final keyPair = await _identityAlgorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    return IdentityKeyMaterial(
      userId: userId,
      deviceId: _uuid.v4(),
      keyPair: keyPair,
      publicKey: publicKey,
    );
  }

  Future<HandshakeInitResult> createHandshakeInit({
    required IdentityKeyMaterial identity,
    required Contact contact,
  }) async {
    final ephemeral = await _keyAgreement.newKeyPair();
    final ephemeralPublic = await ephemeral.extractPublicKey();
    final sessionId = _uuid.v4();
    final body = <String, dynamic>{
      'v': 1,
      'type': 'crypto-handshake-init',
      'protocol': protocol,
      'sessionId': sessionId,
      'from': identity.userId,
      'to': contact.userId,
      'identityPublicKey': b64(identity.publicKey.bytes),
      'ephemeralPublicKey': b64(ephemeralPublic.bytes),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };

    final signature = await _identityAlgorithm.sign(
      canonicalJsonBytes(body),
      keyPair: identity.keyPair,
    );

    return HandshakeInitResult(
      pendingSession: PendingSession(
        contactId: contact.userId,
        sessionId: sessionId,
        ephemeralKeyPair: ephemeral,
        ephemeralPublicKey: b64(ephemeralPublic.bytes),
        createdAt: DateTime.now().toUtc(),
      ),
      wirePayload: {
        'body': body,
        'signature': b64(signature.bytes),
      },
    );
  }

  Future<HandshakeAcceptResult> acceptHandshakeInit({
    required IdentityKeyMaterial identity,
    required Contact contact,
    required Map<String, dynamic> wirePayload,
  }) async {
    final body = asStringKeyMap(wirePayload['body'], 'body');
    final signature = requiredString(wirePayload, 'signature');

    _validateHandshakeBody(
      body: body,
      expectedType: 'crypto-handshake-init',
      localUserId: identity.userId,
      contact: contact,
    );
    await _verifyContactSignature(contact, body, signature);

    final responderEphemeral = await _keyAgreement.newKeyPair();
    final responderEphemeralPublic = await responderEphemeral.extractPublicKey();
    final initiatorEphemeralPublicKey = requiredString(body, 'ephemeralPublicKey');

    final sharedSecret = await _keyAgreement.sharedSecretKey(
      keyPair: responderEphemeral,
      remotePublicKey: SimplePublicKey(
        unb64(initiatorEphemeralPublicKey),
        type: KeyPairType.x25519,
      ),
    );

    final session = SessionState(
      contactId: contact.userId,
      sessionId: requiredString(body, 'sessionId'),
      secretKey: await _deriveMessageKey(
        sharedSecret: sharedSecret,
        sessionId: requiredString(body, 'sessionId'),
        initiatorEphemeralPublicKey: initiatorEphemeralPublicKey,
        responderEphemeralPublicKey: b64(responderEphemeralPublic.bytes),
      ),
      createdAt: DateTime.now().toUtc(),
    );

    final acceptBody = <String, dynamic>{
      'v': 1,
      'type': 'crypto-handshake-accept',
      'protocol': protocol,
      'sessionId': session.sessionId,
      'from': identity.userId,
      'to': contact.userId,
      'identityPublicKey': b64(identity.publicKey.bytes),
      'initiatorEphemeralPublicKey': initiatorEphemeralPublicKey,
      'responderEphemeralPublicKey': b64(responderEphemeralPublic.bytes),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };

    final acceptSignature = await _identityAlgorithm.sign(
      canonicalJsonBytes(acceptBody),
      keyPair: identity.keyPair,
    );

    return HandshakeAcceptResult(
      session: session,
      wirePayload: {
        'body': acceptBody,
        'signature': b64(acceptSignature.bytes),
      },
    );
  }

  Future<SessionState> finishHandshakeAccept({
    required IdentityKeyMaterial identity,
    required Contact contact,
    required PendingSession pending,
    required Map<String, dynamic> wirePayload,
  }) async {
    final body = asStringKeyMap(wirePayload['body'], 'body');
    final signature = requiredString(wirePayload, 'signature');

    _validateHandshakeBody(
      body: body,
      expectedType: 'crypto-handshake-accept',
      localUserId: identity.userId,
      contact: contact,
    );
    await _verifyContactSignature(contact, body, signature);

    final sessionId = requiredString(body, 'sessionId');
    if (sessionId != pending.sessionId) {
      throw const FormatException('Odpowiedz handshake ma inny sessionId.');
    }

    final initiatorEphemeralPublicKey = requiredString(body, 'initiatorEphemeralPublicKey');
    if (initiatorEphemeralPublicKey != pending.ephemeralPublicKey) {
      throw const FormatException('Odpowiedz handshake nie pasuje do efemerycznego klucza.');
    }

    final responderEphemeralPublicKey = requiredString(body, 'responderEphemeralPublicKey');
    final sharedSecret = await _keyAgreement.sharedSecretKey(
      keyPair: pending.ephemeralKeyPair,
      remotePublicKey: SimplePublicKey(
        unb64(responderEphemeralPublicKey),
        type: KeyPairType.x25519,
      ),
    );

    return SessionState(
      contactId: contact.userId,
      sessionId: sessionId,
      secretKey: await _deriveMessageKey(
        sharedSecret: sharedSecret,
        sessionId: sessionId,
        initiatorEphemeralPublicKey: initiatorEphemeralPublicKey,
        responderEphemeralPublicKey: responderEphemeralPublicKey,
      ),
      createdAt: DateTime.now().toUtc(),
    );
  }

  Future<EncryptedPacket> encryptPayload({
    required SessionState session,
    required String from,
    required String to,
    required PlainPayload payload,
  }) async {
    final messageId = _uuid.v4();
    final createdAt = DateTime.now().toUtc().toIso8601String();
    final aad = <String, dynamic>{
      'v': 1,
      'protocol': protocol,
      'sessionId': session.sessionId,
      'messageId': messageId,
      'from': from,
      'to': to,
      'contentType': payload.type.name,
      'createdAt': createdAt,
    };

    final clearJson = <String, dynamic>{
      'v': 1,
      'messageId': messageId,
      'createdAt': createdAt,
      'payload': payload.toJson(),
    };
    final clearBytes = utf8Bytes(canonicalJson(clearJson));
    final compressed = ZLibEncoder().encode(clearBytes);
    final nonce = secureRandomBytes(12);

    final box = await _aead.encrypt(
      compressed,
      secretKey: session.secretKey,
      nonce: nonce,
      aad: canonicalJsonBytes(aad),
    );

    return EncryptedPacket(
      sessionId: session.sessionId,
      messageId: messageId,
      aad: aad,
      nonce: b64(box.nonce),
      ciphertext: b64(box.cipherText),
      mac: b64(box.mac.bytes),
      compression: 'zlib',
    );
  }

  Future<DecryptedPayload> decryptPayload({
    required SessionState session,
    required String expectedFrom,
    required String expectedTo,
    required EncryptedPacket packet,
  }) async {
    if (packet.sessionId != session.sessionId) {
      throw const FormatException('Pakiet nalezy do innej sesji.');
    }
    if (packet.aad['from'] != expectedFrom || packet.aad['to'] != expectedTo) {
      throw const FormatException('AAD pakietu nie pasuje do nadawcy lub odbiorcy.');
    }
    if (packet.aad['messageId'] != packet.messageId || packet.aad['sessionId'] != packet.sessionId) {
      throw const FormatException('AAD pakietu nie pasuje do koperty.');
    }
    if (packet.compression != 'zlib') {
      throw const FormatException('Nieobslugiwany format kompresji.');
    }

    final box = SecretBox(
      unb64(packet.ciphertext),
      nonce: unb64(packet.nonce),
      mac: Mac(unb64(packet.mac)),
    );

    final compressed = await _aead.decrypt(
      box,
      secretKey: session.secretKey,
      aad: canonicalJsonBytes(packet.aad),
    );
    final clearBytes = ZLibDecoder().decodeBytes(compressed);
    final clearJson = asStringKeyMap(
      jsonDecode(utf8.decode(clearBytes)),
      'decryptedPayload',
    );
    final payloadMap = asStringKeyMap(clearJson['payload'], 'payload');

    return DecryptedPayload(
      messageId: requiredString(clearJson, 'messageId'),
      createdAt: DateTime.parse(requiredString(clearJson, 'createdAt')),
      payload: PlainPayload.fromJson(payloadMap),
    );
  }

  void _validateHandshakeBody({
    required Map<String, dynamic> body,
    required String expectedType,
    required String localUserId,
    required Contact contact,
  }) {
    if (body['v'] != 1 || body['protocol'] != protocol || body['type'] != expectedType) {
      throw const FormatException('Niepoprawny handshake.');
    }
    if (body['from'] != contact.userId || body['to'] != localUserId) {
      throw const FormatException('Handshake nie pasuje do lokalnego kontaktu.');
    }
    if (body['identityPublicKey'] != contact.identityPublicKey) {
      throw const FormatException('Klucz tozsamosci kontaktu nie zgadza sie z przypietym kluczem.');
    }
    DateTime.parse(requiredString(body, 'createdAt'));
  }

  Future<void> _verifyContactSignature(
    Contact contact,
    Map<String, dynamic> body,
    String signature,
  ) async {
    final ok = await _identityAlgorithm.verify(
      canonicalJsonBytes(body),
      signature: Signature(
        unb64(signature),
        publicKey: SimplePublicKey(
          unb64(contact.identityPublicKey),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!ok) {
      throw const FormatException('Podpis handshake jest niepoprawny.');
    }
  }

  Future<SecretKey> _deriveMessageKey({
    required SecretKey sharedSecret,
    required String sessionId,
    required String initiatorEphemeralPublicKey,
    required String responderEphemeralPublicKey,
  }) {
    final saltInput = canonicalJsonBytes({
      'protocol': protocol,
      'purpose': 'session-key',
      'sessionId': sessionId,
      'initiatorEphemeralPublicKey': initiatorEphemeralPublicKey,
      'responderEphemeralPublicKey': responderEphemeralPublicKey,
    });
    final salt = crypto_hash.sha256.convert(saltInput).bytes;
    return _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: salt,
      info: utf8Bytes('AES-256-GCM message key'),
    );
  }
}
