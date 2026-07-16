import 'package:cryptography/cryptography.dart';

import '../crypto/codec.dart';

class UpdateSignatureVerifier {
  const UpdateSignatureVerifier();

  static const publicKeyBase64 = String.fromEnvironment(
    'SECURE_CHAT_UPDATE_PUBLIC_KEY',
  );
  static const publicKeyId = String.fromEnvironment(
    'SECURE_CHAT_UPDATE_KEY_ID',
    defaultValue: 'primary-ed25519-v1',
  );
  static const protocol = 'secure-chat-update-manifest/v1';

  Future<void> verifyManifest(Map<String, dynamic> manifest) async {
    if (publicKeyBase64.isEmpty) {
      throw StateError(
        'Brak wbudowanego klucza publicznego aktualizacji. Zbuduj aplikacje z --dart-define=SECURE_CHAT_UPDATE_PUBLIC_KEY=...',
      );
    }

    final signatureRaw = manifest['signature'];
    if (signatureRaw is! Map) {
      throw StateError('Manifest aktualizacji nie ma podpisu.');
    }
    final signature = signatureRaw.cast<String, dynamic>();
    if (signature['protocol'] != protocol) {
      throw StateError('Manifest aktualizacji ma nieznany protokol podpisu.');
    }

    final payload = asStringKeyMap(manifest['latest'], 'latest');
    if (payload['keyId'] != publicKeyId || signature['keyId'] != publicKeyId) {
      throw StateError(
        'Manifest aktualizacji jest podpisany nieznanym kluczem.',
      );
    }
    final signatureBytes = unb64(requiredString(signature, 'signature'));
    final valid = await Ed25519().verify(
      canonicalJsonBytes({'protocol': protocol, 'latest': payload}),
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(
          unb64(publicKeyBase64),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!valid) {
      throw StateError('Podpis manifestu aktualizacji jest niepoprawny.');
    }
  }
}
