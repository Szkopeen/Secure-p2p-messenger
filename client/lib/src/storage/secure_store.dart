import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../crypto/codec.dart';
import '../models/contact.dart';
import '../models/identity.dart';

class SecureStore {
  SecureStore({
    FlutterSecureStorage? storage,
  }) : _storage = storage ?? const FlutterSecureStorage();

  static const _identityUserId = 'identity.userId';
  static const _identityDeviceId = 'identity.deviceId';
  static const _identityPrivateKey = 'identity.ed25519.private';
  static const _identityPublicKey = 'identity.ed25519.public';
  static const _relaySettings = 'relay.settings';
  static const _contacts = 'contacts.v1';

  final FlutterSecureStorage _storage;

  Future<void> saveIdentity(IdentityKeyMaterial identity) async {
    final privateKeyBytes = await identity.keyPair.extractPrivateKeyBytes();
    await _storage.write(key: _identityUserId, value: identity.userId);
    await _storage.write(key: _identityDeviceId, value: identity.deviceId);
    await _storage.write(key: _identityPrivateKey, value: b64(privateKeyBytes));
    await _storage.write(key: _identityPublicKey, value: b64(identity.publicKey.bytes));
  }

  Future<IdentityKeyMaterial?> loadIdentity() async {
    final userId = await _storage.read(key: _identityUserId);
    final deviceId = await _storage.read(key: _identityDeviceId);
    final privateKey = await _storage.read(key: _identityPrivateKey);
    final publicKey = await _storage.read(key: _identityPublicKey);

    if (userId == null || deviceId == null || privateKey == null || publicKey == null) {
      return null;
    }

    final public = SimplePublicKey(unb64(publicKey), type: KeyPairType.ed25519);
    final keyPair = SimpleKeyPairData(
      unb64(privateKey),
      publicKey: public,
      type: KeyPairType.ed25519,
    );

    return IdentityKeyMaterial(
      userId: userId,
      deviceId: deviceId,
      keyPair: keyPair,
      publicKey: public,
    );
  }

  Future<void> saveRelaySettings(RelaySettings settings) async {
    await _storage.write(key: _relaySettings, value: jsonEncode(settings.toJson()));
  }

  Future<RelaySettings?> loadRelaySettings() async {
    final raw = await _storage.read(key: _relaySettings);
    if (raw == null) return null;
    return RelaySettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveContacts(List<Contact> contacts) async {
    await _storage.write(
      key: _contacts,
      value: jsonEncode(contacts.map((contact) => contact.toJson()).toList()),
    );
  }

  Future<List<Contact>> loadContacts() async {
    final raw = await _storage.read(key: _contacts);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((item) => Contact.fromJson((item as Map).cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<void> wipeLocalSecrets() async {
    await _storage.deleteAll();
  }
}
