import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:secure_p2p_messenger/src/crypto/cloud_crypto.dart';
import 'package:secure_p2p_messenger/src/crypto/cloud_origin.dart';
import 'package:secure_p2p_messenger/src/crypto/codec.dart';
import 'package:secure_p2p_messenger/src/crypto/safety_number.dart';
import 'package:secure_p2p_messenger/src/models/cloud_account.dart';
import 'package:secure_p2p_messenger/src/models/message.dart';

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

  group('Anty-replay wiadomosci', () {
    test('licznik i hash poprzedniej wiadomosci sa chronione przez AAD',
        () async {
      final crypto = CloudCrypto();
      final conversationKey = await crypto.newConversationKey();
      final vault = await crypto.createVault(
        accountId: accountId,
        serverOrigin: serverOrigin,
      );
      final deviceKey = await crypto.createDeviceKeyMaterial(
        vault: vault,
        accountId: accountId,
        serverOrigin: serverOrigin,
        deviceId: 'device-a',
      );
      final first = await crypto.encryptMessage(
        conversationId: 'conversation-1',
        senderUserId: accountId,
        senderDeviceId: 'device-a',
        messageCounter: 1,
        previousMessageHash: crypto.cloudMessageGenesisHash,
        conversationKey: conversationKey,
        deviceKey: deviceKey,
        payload: const PlainPayload.text('pierwsza'),
      );
      final firstHash = crypto.cloudMessageHash(first);
      final second = await crypto.encryptMessage(
        conversationId: 'conversation-1',
        senderUserId: accountId,
        senderDeviceId: 'device-a',
        messageCounter: 2,
        previousMessageHash: firstHash,
        conversationKey: conversationKey,
        deviceKey: deviceKey,
        payload: const PlainPayload.text('druga'),
      );

      final decryptedFirst = await crypto.decryptMessage(
        conversationId: 'conversation-1',
        conversationKey: conversationKey,
        payload: first,
      );
      final decryptedSecond = await crypto.decryptMessage(
        conversationId: 'conversation-1',
        conversationKey: conversationKey,
        payload: second,
      );

      expect(decryptedFirst.senderDeviceId, 'device-a');
      expect(decryptedFirst.messageCounter, 1);
      expect(
          decryptedFirst.previousMessageHash, crypto.cloudMessageGenesisHash);
      expect(decryptedFirst.messageHash, firstHash);
      expect(decryptedSecond.messageCounter, 2);
      expect(decryptedSecond.previousMessageHash, firstHash);
      expect(
        await crypto.verifyDeviceMessageSignature(
          accountId: accountId,
          serverOrigin: serverOrigin,
          identityPublicKey: vault.identityPublicKey,
          senderDeviceId: 'device-a',
          payload: first,
        ),
        isTrue,
      );
    });

    test('zmiana licznika w AAD uniewaznia szyfrogram', () async {
      final crypto = CloudCrypto();
      final conversationKey = await crypto.newConversationKey();
      final vault = await crypto.createVault(
        accountId: accountId,
        serverOrigin: serverOrigin,
      );
      final deviceKey = await crypto.createDeviceKeyMaterial(
        vault: vault,
        accountId: accountId,
        serverOrigin: serverOrigin,
        deviceId: 'device-a',
      );
      final encrypted = await crypto.encryptMessage(
        conversationId: 'conversation-1',
        senderUserId: accountId,
        senderDeviceId: 'device-a',
        messageCounter: 1,
        previousMessageHash: crypto.cloudMessageGenesisHash,
        conversationKey: conversationKey,
        deviceKey: deviceKey,
        payload: const PlainPayload.text('test'),
      );
      final aad = Map<String, dynamic>.of(
        (encrypted['aad'] as Map).cast<String, dynamic>(),
      );
      aad['messageCounter'] = 2;
      final tampered = Map<String, dynamic>.of(encrypted)..['aad'] = aad;

      expect(
        () => crypto.decryptMessage(
          conversationId: 'conversation-1',
          conversationKey: conversationKey,
          payload: tampered,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('hash lancucha obejmuje cala koperte wiadomosci', () async {
      final crypto = CloudCrypto();
      final conversationKey = await crypto.newConversationKey();
      final vault = await crypto.createVault(
        accountId: accountId,
        serverOrigin: serverOrigin,
      );
      final deviceKey = await crypto.createDeviceKeyMaterial(
        vault: vault,
        accountId: accountId,
        serverOrigin: serverOrigin,
        deviceId: 'device-a',
      );
      final encrypted = await crypto.encryptMessage(
        conversationId: 'conversation-1',
        senderUserId: accountId,
        senderDeviceId: 'device-a',
        messageCounter: 1,
        previousMessageHash: crypto.cloudMessageGenesisHash,
        conversationKey: conversationKey,
        deviceKey: deviceKey,
        payload: const PlainPayload.text('test'),
      );
      final originalHash = crypto.cloudMessageHash(encrypted);
      final changedNonce = Map<String, dynamic>.of(encrypted)
        ..['nonce'] = 'AAAAAAAAAAAAAAAA';
      final changedCiphertext = Map<String, dynamic>.of(encrypted)
        ..['ciphertext'] = '${encrypted['ciphertext']}AA';

      expect(crypto.cloudMessageHash(changedNonce), isNot(originalHash));
      expect(crypto.cloudMessageHash(changedCiphertext), isNot(originalHash));
      expect(crypto.cloudMessageGenesisHash, isNot(originalHash));
    });

    test('podpis urzadzenia odrzuca podmieniona koperte', () async {
      final crypto = CloudCrypto();
      final conversationKey = await crypto.newConversationKey();
      final vault = await crypto.createVault(
        accountId: accountId,
        serverOrigin: serverOrigin,
      );
      final deviceKey = await crypto.createDeviceKeyMaterial(
        vault: vault,
        accountId: accountId,
        serverOrigin: serverOrigin,
        deviceId: 'device-a',
      );
      final encrypted = await crypto.encryptMessage(
        conversationId: 'conversation-1',
        senderUserId: accountId,
        senderDeviceId: 'device-a',
        messageCounter: 1,
        previousMessageHash: crypto.cloudMessageGenesisHash,
        conversationKey: conversationKey,
        deviceKey: deviceKey,
        payload: const PlainPayload.text('test'),
      );
      final aad = Map<String, dynamic>.of(
        (encrypted['aad'] as Map).cast<String, dynamic>(),
      );
      aad['senderDeviceId'] = 'device-b';
      final tampered = Map<String, dynamic>.of(encrypted)..['aad'] = aad;

      expect(
        await crypto.verifyDeviceMessageSignature(
          accountId: accountId,
          serverOrigin: serverOrigin,
          identityPublicKey: vault.identityPublicKey,
          senderDeviceId: 'device-a',
          payload: encrypted,
        ),
        isTrue,
      );
      expect(
        await crypto.verifyDeviceMessageSignature(
          accountId: accountId,
          serverOrigin: serverOrigin,
          identityPublicKey: vault.identityPublicKey,
          senderDeviceId: 'device-b',
          payload: tampered,
        ),
        isFalse,
      );
    });

    test('podpisana lista urzadzen tworzy monotoniczny lancuch', () async {
      final crypto = CloudCrypto();
      final vault = await crypto.createVault(
        accountId: accountId,
        serverOrigin: serverOrigin,
      );
      final firstDevice = await crypto.createDeviceKeyMaterial(
        vault: vault,
        accountId: accountId,
        serverOrigin: serverOrigin,
        deviceId: 'device-a',
      );
      final firstList = await crypto.signDeviceList(
        vault: vault,
        accountId: accountId,
        serverOrigin: serverOrigin,
        previousList: null,
        devices: [
          crypto.deviceListEntryForCertificate(firstDevice.certificate),
        ],
        revokedDevices: const [],
      );

      final secondDevice = await crypto.createDeviceKeyMaterial(
        vault: vault,
        accountId: accountId,
        serverOrigin: serverOrigin,
        deviceId: 'device-b',
      );
      final secondList = await crypto.signDeviceList(
        vault: vault,
        accountId: accountId,
        serverOrigin: serverOrigin,
        previousList: firstList,
        devices: [
          ...firstList.devices,
          crypto.deviceListEntryForCertificate(secondDevice.certificate),
        ],
        revokedDevices: const [],
      );

      expect(
        await crypto.verifyDeviceList(
          accountId: accountId,
          serverOrigin: serverOrigin,
          identityPublicKey: vault.identityPublicKey,
          deviceList: firstList,
        ),
        isTrue,
      );
      expect(secondList.deviceListEpoch, 2);
      expect(secondList.previousDeviceListHash, firstList.deviceListHash);
      expect(
        await crypto.verifyDeviceList(
          accountId: accountId,
          serverOrigin: serverOrigin,
          identityPublicKey: vault.identityPublicKey,
          deviceList: secondList,
        ),
        isTrue,
      );

      final tampered = CloudDeviceList(
        accountId: secondList.accountId,
        serverOrigin: secondList.serverOrigin,
        deviceListEpoch: secondList.deviceListEpoch,
        previousDeviceListHash: secondList.previousDeviceListHash,
        identityRotationEpoch: secondList.identityRotationEpoch,
        devices: [secondList.devices.last],
        revokedDevices: secondList.revokedDevices,
        signature: secondList.signature,
        updatedAt: secondList.updatedAt,
      );
      expect(
        await crypto.verifyDeviceList(
          accountId: accountId,
          serverOrigin: serverOrigin,
          identityPublicKey: vault.identityPublicKey,
          deviceList: tampered,
        ),
        isFalse,
      );
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
