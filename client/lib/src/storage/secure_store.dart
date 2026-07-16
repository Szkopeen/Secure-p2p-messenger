import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../crypto/codec.dart';
import '../models/contact.dart';
import '../models/cloud_account.dart';
import '../models/identity.dart';
import '../models/user_profile.dart';

class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _identityUserId = 'identity.userId';
  static const _identityDeviceId = 'identity.deviceId';
  static const _identityPrivateKey = 'identity.ed25519.private';
  static const _identityPublicKey = 'identity.ed25519.public';
  static const _adminSettings = 'admin.settings.v1';
  static const _contacts = 'contacts.v1';
  static const _localArchiveKey = 'local.archive.key.v1';
  static const _ownProfile = 'profile.public.v1';
  static const _sessions = 'sessions.v1';
  static const _cloudSession = 'cloud.session.v1';
  static const _cloudDeviceKey = 'cloud.deviceKey.v1';
  static const _cloudReplayStates = 'cloud.messageReplay.v1';
  static const _cloudVaultPins = 'cloud.vaultPins.v1';
  static const _privacyScreenEnabled = 'privacy.screen.enabled.v1';
  static const _appLockPin = 'privacy.appLock.pin.v1';

  final FlutterSecureStorage _storage;

  Future<void> saveIdentity(IdentityKeyMaterial identity) async {
    final privateKeyBytes = await identity.keyPair.extractPrivateKeyBytes();
    await _storage.write(key: _identityUserId, value: identity.userId);
    await _storage.write(key: _identityDeviceId, value: identity.deviceId);
    await _storage.write(key: _identityPrivateKey, value: b64(privateKeyBytes));
    await _storage.write(
      key: _identityPublicKey,
      value: b64(identity.publicKey.bytes),
    );
  }

  Future<IdentityKeyMaterial?> loadIdentity() async {
    final userId = await _storage.read(key: _identityUserId);
    final deviceId = await _storage.read(key: _identityDeviceId);
    final privateKey = await _storage.read(key: _identityPrivateKey);
    final publicKey = await _storage.read(key: _identityPublicKey);

    if (userId == null ||
        deviceId == null ||
        privateKey == null ||
        publicKey == null) {
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

  Future<void> saveAdminSettings(AdminSettings settings) async {
    await _storage.write(
      key: _adminSettings,
      value: jsonEncode(settings.toJson()),
    );
  }

  Future<AdminSettings?> loadAdminSettings() async {
    final raw = await _storage.read(key: _adminSettings);
    if (raw == null || raw.isEmpty) return null;
    return AdminSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<bool> loadPrivacyScreenEnabled() async {
    final raw = await _storage.read(key: _privacyScreenEnabled);
    return raw == null || raw != 'false';
  }

  Future<void> savePrivacyScreenEnabled(bool enabled) {
    return _storage.write(
      key: _privacyScreenEnabled,
      value: enabled ? 'true' : 'false',
    );
  }

  Future<Map<String, String>?> loadAppLockPin() async {
    final raw = await _storage.read(key: _appLockPin);
    if (raw == null || raw.isEmpty) return null;
    return (jsonDecode(raw) as Map).map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    );
  }

  Future<void> saveAppLockPin({required String salt, required String hash}) {
    return _storage.write(
      key: _appLockPin,
      value: jsonEncode({'salt': salt, 'hash': hash}),
    );
  }

  Future<void> clearAppLockPin() {
    return _storage.delete(key: _appLockPin);
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

  Future<void> saveCloudSession(CloudSession session) async {
    await _storage.write(
      key: _cloudSession,
      value: jsonEncode(session.toJson()),
    );
  }

  Future<CloudSession?> loadCloudSession() async {
    final raw = await _storage.read(key: _cloudSession);
    if (raw == null || raw.isEmpty) return null;
    return CloudSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveCloudDeviceKey(CloudDeviceKeyMaterial key) async {
    await _storage.write(key: _cloudDeviceKey, value: jsonEncode(key.toJson()));
  }

  Future<CloudDeviceKeyMaterial?> loadCloudDeviceKey() async {
    final raw = await _storage.read(key: _cloudDeviceKey);
    if (raw == null || raw.isEmpty) return null;
    return CloudDeviceKeyMaterial.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  }

  Future<void> saveCloudMessageReplayStates(
    Iterable<CloudMessageReplayState> states,
  ) async {
    await _storage.write(
      key: _cloudReplayStates,
      value: jsonEncode(states.map((state) => state.toJson()).toList()),
    );
  }

  Future<List<CloudMessageReplayState>> loadCloudMessageReplayStates() async {
    final raw = await _storage.read(key: _cloudReplayStates);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map(
          (item) => CloudMessageReplayState.fromJson(
            (item as Map).cast<String, dynamic>(),
          ),
        )
        .toList(growable: false);
  }

  Future<void> clearCloudSession() {
    return _storage.delete(key: _cloudSession);
  }

  Future<Map<String, dynamic>?> loadCloudVaultPin(String accountId) async {
    final raw = await _storage.read(key: _cloudVaultPins);
    if (raw == null || raw.isEmpty) return null;
    final pins = (jsonDecode(raw) as Map).cast<String, dynamic>();
    final pin = pins[accountId];
    return pin is Map ? pin.cast<String, dynamic>() : null;
  }

  Future<void> saveCloudVaultPin(
    String accountId,
    int epoch,
    String hash,
  ) async {
    final raw = await _storage.read(key: _cloudVaultPins);
    final pins = raw == null || raw.isEmpty
        ? <String, dynamic>{}
        : (jsonDecode(raw) as Map).cast<String, dynamic>();
    pins[accountId] = {'epoch': epoch, 'hash': hash};
    await _storage.write(key: _cloudVaultPins, value: jsonEncode(pins));
  }

  Future<void> saveOwnProfile(UserProfile profile) async {
    await _storage.write(key: _ownProfile, value: jsonEncode(profile.toJson()));
  }

  Future<UserProfile?> loadOwnProfile() async {
    final raw = await _storage.read(key: _ownProfile);
    if (raw == null || raw.isEmpty) return null;
    return UserProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> clearLegacySessions() {
    return _storage.delete(key: _sessions);
  }

  Future<void> wipeLocalSecrets() async {
    await _storage.deleteAll();
  }

  Future<String?> loadLocalArchiveKey() {
    return _storage.read(key: _localArchiveKey);
  }

  Future<void> saveLocalArchiveKey(String value) {
    return _storage.write(key: _localArchiveKey, value: value);
  }
}
