import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_p2p_messenger/src/crypto/cloud_crypto.dart';
import 'package:secure_p2p_messenger/src/crypto/cloud_origin.dart';
import 'package:secure_p2p_messenger/src/crypto/codec.dart';
import 'package:secure_p2p_messenger/src/crypto/safety_number.dart';
import 'package:secure_p2p_messenger/src/models/cloud_account.dart';

void main() {
  const accountId = 'uuid-alice';
  const serverOrigin = 'https://chat.szkpn.pl';

  Future<String> legacyV1Signature(CloudVault vault) async {
    final signature = await Ed25519().sign(
      canonicalJsonBytes({
        'v': 1,
        'protocol': 'secure-p2p-identity-key-binding/v1',
        'identityPublicKey': vault.identityPublicKey,
        'keyAgreementPublicKey': vault.keyAgreementPublicKey,
      }),
      keyPair: SimpleKeyPairData(
        unb64(vault.identityPrivateKey),
        publicKey: SimplePublicKey(
          unb64(vault.identityPublicKey),
          type: KeyPairType.ed25519,
        ),
        type: KeyPairType.ed25519,
      ),
    );
    return b64(signature.bytes);
  }

  group('Origin serwera', () {
    test('jest kanonizowany przed uzyciem w podpisie', () {
      expect(
        canonicalCloudOrigin('https://CHAT.SZKPN.PL/'),
        serverOrigin,
      );
      expect(
        canonicalCloudOrigin('https://chat.szkpn.pl:443/api?x=1#fragment'),
        serverOrigin,
      );
      expect(
        canonicalCloudOrigin('wss://chat.szkpn.pl/v2/ws'),
        serverOrigin,
      );
      expect(
        canonicalCloudOrigin('https://chat.szkpn.pl:8443/api'),
        'https://chat.szkpn.pl:8443',
      );
      expect(
        canonicalCloudOrigin('https://chat.szkpn.pl.'),
        serverOrigin,
      );
      expect(
        canonicalCloudOrigin('https://chat.szkpn.pl:443'),
        serverOrigin,
      );
      expect(
        canonicalCloudOrigin('https://chat.szkpn.pl:444'),
        'https://chat.szkpn.pl:444',
      );
      expect(
        canonicalCloudOrigin('http://localhost:8080/api'),
        'http://localhost:8080',
      );
      expect(
        canonicalCloudOrigin('https://[2001:db8::1]:443/'),
        'https://[2001:db8::1]',
      );
      expect(
        canonicalCloudOrigin('https://b\u00fccher.example/'),
        'https://xn--bcher-kva.example',
      );
      expect(
        () => canonicalCloudOrigin('http://chat.szkpn.pl'),
        throwsArgumentError,
      );
      expect(
        () => canonicalCloudOrigin('https://user:password@chat.szkpn.pl'),
        throwsArgumentError,
      );
      expect(
        () => canonicalCloudOrigin('/relative/path'),
        throwsArgumentError,
      );
      expect(
        () => canonicalCloudOrigin('ftp://chat.szkpn.pl'),
        throwsArgumentError,
      );
    });
  });

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

    test('zmienia sie po przypisaniu tego samego klucza do innego UUID', () {
      final original = SafetyNumber.calculate(
        ownUserId: 'uuid-alice',
        ownIdentityPublicKey: 'ed25519-alice',
        contactUserId: 'uuid-bob',
        contactIdentityPublicKey: 'ed25519-bob',
      );

      final rebound = SafetyNumber.calculate(
        ownUserId: 'uuid-charlie',
        ownIdentityPublicKey: 'ed25519-alice',
        contactUserId: 'uuid-bob',
        contactIdentityPublicKey: 'ed25519-bob',
      );

      expect(rebound, isNot(original));
    });
  });

  group('Podpisana tozsamosc', () {
    test('wiaze klucz szyfrowania z UUID konta i originem serwera', () async {
      final crypto = CloudCrypto();
      final vault = await crypto.createVault(
        accountId: accountId,
        serverOrigin: serverOrigin,
      );

      expect(
        await crypto.verifyKeyAgreementSignature(
          accountId: accountId,
          serverOrigin: serverOrigin,
          identityPublicKey: vault.identityPublicKey,
          keyAgreementPublicKey: vault.keyAgreementPublicKey,
          signature: vault.keyAgreementPublicKeySignature,
        ),
        isTrue,
      );

      expect(
        await crypto.verifyKeyAgreementSignature(
          accountId: 'uuid-bob',
          serverOrigin: serverOrigin,
          identityPublicKey: vault.identityPublicKey,
          keyAgreementPublicKey: vault.keyAgreementPublicKey,
          signature: vault.keyAgreementPublicKeySignature,
        ),
        isFalse,
      );

      expect(
        await crypto.verifyKeyAgreementSignature(
          accountId: accountId,
          serverOrigin: 'https://evil.example',
          identityPublicKey: vault.identityPublicKey,
          keyAgreementPublicKey: vault.keyAgreementPublicKey,
          signature: vault.keyAgreementPublicKeySignature,
        ),
        isFalse,
      );
    });

    test('odrzuca podmieniony klucz X25519 i Ed25519', () async {
      final crypto = CloudCrypto();
      final vault = await crypto.createVault(
        accountId: accountId,
        serverOrigin: serverOrigin,
      );
      final otherVault = await crypto.createVault(
        accountId: accountId,
        serverOrigin: serverOrigin,
      );

      expect(
        await crypto.verifyKeyAgreementSignature(
          accountId: accountId,
          serverOrigin: serverOrigin,
          identityPublicKey: vault.identityPublicKey,
          keyAgreementPublicKey: otherVault.keyAgreementPublicKey,
          signature: vault.keyAgreementPublicKeySignature,
        ),
        isFalse,
      );

      expect(
        await crypto.verifyKeyAgreementSignature(
          accountId: accountId,
          serverOrigin: serverOrigin,
          identityPublicKey: otherVault.identityPublicKey,
          keyAgreementPublicKey: vault.keyAgreementPublicKey,
          signature: vault.keyAgreementPublicKeySignature,
        ),
        isFalse,
      );
    });

    test('odrzuca ten sam serwer z innym niestandardowym portem', () async {
      final crypto = CloudCrypto();
      final vault = await crypto.createVault(
        accountId: accountId,
        serverOrigin: serverOrigin,
      );

      expect(
        await crypto.verifyKeyAgreementSignature(
          accountId: accountId,
          serverOrigin: 'https://chat.szkpn.pl:8443',
          identityPublicKey: vault.identityPublicKey,
          keyAgreementPublicKey: vault.keyAgreementPublicKey,
          signature: vault.keyAgreementPublicKeySignature,
        ),
        isFalse,
      );
    });

    test('odrzuca uszkodzony podpis i stary format v1', () async {
      final crypto = CloudCrypto();
      final vault = await crypto.createVault(
        accountId: accountId,
        serverOrigin: serverOrigin,
      );
      final legacySignature = await legacyV1Signature(vault);

      expect(
        await crypto.verifyKeyAgreementSignature(
          accountId: accountId,
          serverOrigin: serverOrigin,
          identityPublicKey: vault.identityPublicKey,
          keyAgreementPublicKey: vault.keyAgreementPublicKey,
          signature: '!not-base64!',
        ),
        isFalse,
      );

      expect(
        await crypto.verifyKeyAgreementSignature(
          accountId: accountId,
          serverOrigin: serverOrigin,
          identityPublicKey: vault.identityPublicKey,
          keyAgreementPublicKey: vault.keyAgreementPublicKey,
          signature: legacySignature,
        ),
        isFalse,
      );
    });

    test('rotacja tozsamosci jest podpisana starym kluczem', () async {
      final crypto = CloudCrypto();
      final oldVault = await crypto.createVault(
        accountId: accountId,
        serverOrigin: serverOrigin,
      );
      final rotation = await crypto.rotateIdentity(
        vault: oldVault,
        accountId: accountId,
        serverOrigin: serverOrigin,
      );

      expect(
          rotation.vault.identityPublicKey, isNot(oldVault.identityPublicKey));
      expect(
        rotation.vault.keyAgreementPublicKey,
        oldVault.keyAgreementPublicKey,
      );
      expect(
        await crypto.verifyKeyAgreementSignature(
          accountId: accountId,
          serverOrigin: serverOrigin,
          identityPublicKey: rotation.vault.identityPublicKey,
          keyAgreementPublicKey: rotation.vault.keyAgreementPublicKey,
          signature: rotation.vault.keyAgreementPublicKeySignature,
        ),
        isTrue,
      );
      expect(
        await crypto.verifyIdentityRotationProof(
          accountId: accountId,
          serverOrigin: serverOrigin,
          proof: rotation.proof,
        ),
        isTrue,
      );
      expect(
        await crypto.verifyIdentityRotationProof(
          accountId: 'uuid-bob',
          serverOrigin: serverOrigin,
          proof: rotation.proof,
        ),
        isFalse,
      );
      expect(
        await crypto.verifyIdentityRotationProof(
          accountId: accountId,
          serverOrigin: 'https://chat.szkpn.pl:8443',
          proof: rotation.proof,
        ),
        isFalse,
      );
    });

    test('rotacja odrzuca podmienione pola dowodu', () async {
      final crypto = CloudCrypto();
      final oldVault = await crypto.createVault(
        accountId: accountId,
        serverOrigin: serverOrigin,
      );
      final rotation = await crypto.rotateIdentity(
        vault: oldVault,
        accountId: accountId,
        serverOrigin: serverOrigin,
      );
      final otherVault = await crypto.createVault(
        accountId: accountId,
        serverOrigin: serverOrigin,
      );
      final tamperedProof = IdentityRotationProof(
        rotationEpoch: rotation.proof.rotationEpoch,
        previousRotationHash: rotation.proof.previousRotationHash,
        oldIdentityPublicKey: rotation.proof.oldIdentityPublicKey,
        newIdentityPublicKey: rotation.proof.newIdentityPublicKey,
        newKeyAgreementPublicKey: otherVault.keyAgreementPublicKey,
        signature: rotation.proof.signature,
        newIdentityConfirmationSignature:
            rotation.proof.newIdentityConfirmationSignature,
        rotatedAt: rotation.proof.rotatedAt,
      );

      expect(
        await crypto.verifyIdentityRotationProof(
          accountId: accountId,
          serverOrigin: serverOrigin,
          proof: tamperedProof,
        ),
        isFalse,
      );
    });

    test('rotacja tworzy monotoniczny lancuch epoch i hashy', () async {
      final crypto = CloudCrypto();
      final initialVault = await crypto.createVault(
        accountId: accountId,
        serverOrigin: serverOrigin,
      );
      final first = await crypto.rotateIdentity(
        vault: initialVault,
        accountId: accountId,
        serverOrigin: serverOrigin,
      );
      final second = await crypto.rotateIdentity(
        vault: first.vault,
        accountId: accountId,
        serverOrigin: serverOrigin,
      );

      expect(first.proof.rotationEpoch, 1);
      expect(first.proof.previousRotationHash, isEmpty);
      expect(second.proof.rotationEpoch, 2);
      expect(second.proof.previousRotationHash, first.proof.rotationHash);
      expect(
        crypto.isNextIdentityRotation(
          previousProof: null,
          nextProof: first.proof,
        ),
        isTrue,
      );
      expect(
        crypto.isNextIdentityRotation(
          previousProof: first.proof,
          nextProof: second.proof,
        ),
        isTrue,
      );
      expect(
        crypto.isNextIdentityRotation(
          previousProof: first.proof,
          nextProof: first.proof,
        ),
        isFalse,
      );
      expect(
        crypto.isNextIdentityRotation(
          previousProof: null,
          nextProof: second.proof,
        ),
        isFalse,
      );
    });

    test('rotacja odrzuca alternatywna galaz po zaakceptowaniu pierwszej',
        () async {
      final crypto = CloudCrypto();
      final initialVault = await crypto.createVault(
        accountId: accountId,
        serverOrigin: serverOrigin,
      );
      final branchA = await crypto.rotateIdentity(
        vault: initialVault,
        accountId: accountId,
        serverOrigin: serverOrigin,
      );
      final branchB = await crypto.rotateIdentity(
        vault: initialVault,
        accountId: accountId,
        serverOrigin: serverOrigin,
      );

      expect(
        crypto.isNextIdentityRotation(
          previousProof: null,
          nextProof: branchA.proof,
        ),
        isTrue,
      );
      expect(
        crypto.isNextIdentityRotation(
          previousProof: branchA.proof,
          nextProof: branchB.proof,
        ),
        isFalse,
      );
    });
  });
}
