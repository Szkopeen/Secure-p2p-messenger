import '../crypto/codec.dart';

class EncryptedPacket {
  const EncryptedPacket({
    required this.sessionId,
    required this.messageId,
    required this.aad,
    required this.nonce,
    required this.ciphertext,
    required this.mac,
    required this.compression,
  });

  final String sessionId;
  final String messageId;
  final Map<String, dynamic> aad;
  final String nonce;
  final String ciphertext;
  final String mac;
  final String compression;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'protocol': 'secure-p2p-e2ee/v1',
        'sessionId': sessionId,
        'messageId': messageId,
        'aad': aad,
        'nonce': nonce,
        'ciphertext': ciphertext,
        'mac': mac,
        'compression': compression,
      };

  factory EncryptedPacket.fromJson(Map<String, dynamic> json) {
    return EncryptedPacket(
      sessionId: requiredString(json, 'sessionId'),
      messageId: requiredString(json, 'messageId'),
      aad: asStringKeyMap(json['aad'], 'aad'),
      nonce: requiredString(json, 'nonce'),
      ciphertext: requiredString(json, 'ciphertext'),
      mac: requiredString(json, 'mac'),
      compression: requiredString(json, 'compression'),
    );
  }
}
