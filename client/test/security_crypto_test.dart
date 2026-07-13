import 'package:flutter_test/flutter_test.dart';
import 'package:secure_p2p_messenger/src/crypto/cloud_crypto.dart';
import 'package:secure_p2p_messenger/src/crypto/safety_number.dart';

void main() {
  group('Safety number', () {
    test('jest taki sam po obu stronach rozmowy', () {
      final aliceView = SafetyNumber.calculate(
        ownUserId: 'uuid-alice',
        ownIdentityPublicKey: 'ed25519-alice',
        contactUserId: 'uuid-bob',
        contactIdentityPublicKey: 'ed25519-bob',
      );

      final bobView = SafetyNumber.calculate(
        ownUserId: 'uuid-bob',
        ownIdentityPublicKey: 'ed25519-bob',
        contactUserId: 'uuid-alice',
        contactIdentityPublicKey: 'ed25519-alice',
      );

      expect(aliceView, bobView);
      expect(aliceView.split(' '), hasLength(8));
    });
  });

  group('Podpisana tozsamosc', () {
    test('wiaze klucz szyfrowania z UUID konta i originem serwera', () async {
      final crypto = CloudCrypto();
      final vault = await crypto.createVault(
        accountId: 'uuid-alice',
        serverOrigin: 'https://chat.szkpn.pl',
      );

      expect(
        await crypto.verifyKeyAgreementSignature(
          accountId: 'uuid-alice',
          serverOrigin: 'https://chat.szkpn.pl',
          identityPublicKey: vault.identityPublicKey,
          keyAgreementPublicKey: vault.keyAgreementPublicKey,
          signature: vault.keyAgreementPublicKeySignature,
        ),
        isTrue,
      );

      expect(
        await crypto.verifyKeyAgreementSignature(
          accountId: 'uuid-bob',
          serverOrigin: 'https://chat.szkpn.pl',
          identityPublicKey: vault.identityPublicKey,
          keyAgreementPublicKey: vault.keyAgreementPublicKey,
          signature: vault.keyAgreementPublicKeySignature,
        ),
        isFalse,
      );

      expect(
        await crypto.verifyKeyAgreementSignature(
          accountId: 'uuid-alice',
          serverOrigin: 'https://evil.example',
          identityPublicKey: vault.identityPublicKey,
          keyAgreementPublicKey: vault.keyAgreementPublicKey,
          signature: vault.keyAgreementPublicKeySignature,
        ),
        isFalse,
      );
    });
  });
}
