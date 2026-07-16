import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto_hash;
import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'crypto/codec.dart';
import 'crypto/cloud_crypto.dart';
import 'crypto/cloud_origin.dart';
import 'crypto/safety_number.dart';
import 'models/cloud_account.dart';
import 'models/contact.dart';
import 'models/identity.dart';
import 'models/message.dart';
import 'models/update_info.dart';
import 'models/user_profile.dart';
import 'platform/media_cache.dart';
import 'platform/screen_security.dart';
import 'security/update_signature_verifier.dart';
import 'services/cloud_api_client.dart';
import 'services/desktop_notifier.dart';
import 'storage/message_archive.dart';
import 'storage/secure_store.dart';

enum _CloudReplayDecision { accept, buffer }

bool cloudAccountPasswordSeparatedFromVaultSecret(
  String password,
  String vaultSecret,
) =>
    password.trim() != vaultSecret.trim();

class _AppLockConfig {
  const _AppLockConfig({
    required this.algorithm,
    required this.iterations,
    required this.salt,
    required this.hash,
  });

  final String algorithm;
  final int iterations;
  final String salt;
  final String hash;
}

class AppState extends ChangeNotifier {
  AppState({SecureStore? store}) : _store = store ?? SecureStore() {
    _messageArchive = MessageArchive(secureStore: _store);
  }

  static const maxPlainFileBytes = 8 * 1024 * 1024;
  static const maxCloudPlainFileBytes = 48 * 1024;
  static const maxProfileImageBytes = 1024 * 1024;
  static const _maxUpdateArtifactBytes = 512 * 1024 * 1024;
  static const _maxUpdateManifestBytes = 1024 * 1024;
  static const _appLockPinAlgorithm = 'pbkdf2-hmac-sha256';
  static const _legacyAppLockPinAlgorithm = 'legacy-sha256';
  static const _appLockPinIterations = 310000;
  static const _appLockPinBits = 256;
  final SecureStore _store;
  final CloudCrypto _cloudCrypto = CloudCrypto();
  final UpdateSignatureVerifier _updateSignatureVerifier =
      const UpdateSignatureVerifier();
  late final MessageArchive _messageArchive;
  final Uuid _uuid = const Uuid();
  Future<void> _persistQueue = Future<void>.value();
  final List<Contact> _contacts = [];
  final Map<String, List<ChatMessage>> _messages = {};
  final Map<String, CloudConversation> _cloudConversations = {};
  final Map<String, String> _cloudContactToConversation = {};
  final Map<String, int> _cloudLastSeq = {};
  final Map<String, CloudMessageReplayState> _cloudReplayStates = {};
  final Map<String, Map<int, CloudStoredMessage>> _pendingCloudReplayMessages =
      {};
  final Set<String> _cloudGapFetches = {};
  final Map<String, Future<void>> _cloudSendQueues = {};
  final List<CloudPublicUser> _cloudUsers = [];

  IdentityKeyMaterial? _identity;
  CloudSession? _cloudSession;
  CloudVault? _cloudVault;
  Map<String, dynamic> _cloudVaultKdf = Map<String, dynamic>.of(
    CloudCrypto.defaultVaultKdf,
  );
  CloudDeviceKeyMaterial? _cloudDeviceKey;
  CloudDeviceList? _ownCloudDeviceList;
  CloudApiClient? _cloudClient;
  StreamSubscription<CloudEvent>? _cloudSubscription;
  UserProfile? _ownProfile;
  Timer? _presenceTimer;
  bool _cloudConnected = false;
  bool _initializing = true;
  String? _status;
  String _currentVersionLabel = '';
  int _currentBuildNumber = 0;
  AvailableUpdate? _availableUpdate;
  bool _checkingForUpdate = false;
  bool _downloadingUpdate = false;
  double? _updateDownloadProgress;
  String? _updateStatus;
  String? _downloadedUpdatePath;
  bool _privacyScreenEnabled = true;
  bool _privacyLocked = false;
  _AppLockConfig? _appLock;
  int _appLockFailures = 0;
  DateTime? _appLockBlockedUntil;

  bool get initializing => _initializing;
  bool get hasIdentity => _identity != null;
  bool get cloudMode => _cloudSession != null;
  bool get hasAccount => cloudMode;
  bool get cloudConnected => _cloudConnected;
  String? get status => _status;
  String? get ownUserId => _cloudSession?.userId ?? _identity?.userId;
  String? get ownDeviceId => _cloudSession?.deviceId ?? _identity?.deviceId;
  String? get ownDisplayName =>
      _cloudSession?.displayName ??
      _cloudSession?.username ??
      _identity?.userId;
  String? get ownPublicKey =>
      _cloudVault?.identityPublicKey ??
      (_identity == null ? null : b64(_identity!.publicKey.bytes));
  UserProfile? get ownProfile => _ownProfile;
  List<Contact> get contacts => List.unmodifiable(_contacts);
  List<CloudPublicUser> get cloudUsers => List.unmodifiable(_cloudUsers);
  CloudDeviceList? get ownCloudDeviceList => _ownCloudDeviceList;
  String get currentVersionLabel => _currentVersionLabel;
  AvailableUpdate? get availableUpdate => _availableUpdate;
  bool get checkingForUpdate => _checkingForUpdate;
  bool get downloadingUpdate => _downloadingUpdate;
  double? get updateDownloadProgress => _updateDownloadProgress;
  String? get updateStatus => _updateStatus;
  String? get downloadedUpdatePath => _downloadedUpdatePath;
  bool get privacyScreenEnabled => _privacyScreenEnabled;
  bool get privacyLocked => _privacyLocked;
  bool get appLockEnabled => _appLock != null;

  List<ChatMessage> messagesFor(String contactId) {
    final items = _messages[contactId] ?? const <ChatMessage>[];
    return List.unmodifiable(items);
  }

  int unreadCountFor(String contactId) {
    final items = _messages[contactId] ?? const <ChatMessage>[];
    return items.where(_isUnreadIncomingMessage).length;
  }

  int get totalUnreadCount {
    return _messages.values
        .expand((messages) => messages)
        .where(_isUnreadIncomingMessage)
        .length;
  }

  void handleLifecycleActive(bool active) {
    if (!active) {
      _lockPrivacy();
    }
  }

  Future<void> setPrivacyScreenEnabled(bool enabled) async {
    _privacyScreenEnabled = enabled;
    await _store.savePrivacyScreenEnabled(enabled);
    if (!enabled && !appLockEnabled) {
      _privacyLocked = false;
    }
    await _refreshScreenSecurity();
    notifyListeners();
  }

  Future<void> enableAppLockPin(String pin, String confirmation) async {
    final normalizedPin = _normalizePin(pin);
    if (normalizedPin != _normalizePin(confirmation)) {
      throw ArgumentError('PIN i powtorzenie PIN-u musza byc takie same.');
    }
    _validatePinFormat(normalizedPin);
    final salt = b64(secureRandomBytes(16));
    final hash = await _hashAppLockPin(
      normalizedPin,
      salt,
      _appLockPinIterations,
    );
    await _store.saveAppLockPin(
      algorithm: _appLockPinAlgorithm,
      iterations: _appLockPinIterations,
      salt: salt,
      hash: hash,
    );
    _appLock = _AppLockConfig(
      algorithm: _appLockPinAlgorithm,
      iterations: _appLockPinIterations,
      salt: salt,
      hash: hash,
    );
    _appLockFailures = 0;
    _appLockBlockedUntil = null;
    await _store.clearAppLockState();
    await _refreshScreenSecurity();
    notifyListeners();
  }

  Future<void> disableAppLockPin(String pin) async {
    final config = _appLock;
    if (config == null) return;
    if (!await _verifyAppLockPin(pin, config)) {
      throw ArgumentError('Niepoprawny PIN.');
    }
    await _store.clearAppLockPin();
    await _store.clearAppLockState();
    _appLock = null;
    _privacyLocked = false;
    _appLockFailures = 0;
    _appLockBlockedUntil = null;
    await _refreshScreenSecurity();
    notifyListeners();
  }

  Future<void> unlockPrivacy(String pin) async {
    final config = _appLock;
    if (config == null) {
      _privacyLocked = false;
      notifyListeners();
      return;
    }
    final blockedUntil = _appLockBlockedUntil;
    final now = DateTime.now();
    if (blockedUntil != null && now.isBefore(blockedUntil)) {
      throw StateError('Za duzo prob. Sprobuj ponownie za chwile.');
    }
    final normalizedPin = _normalizePin(pin);
    if (await _verifyAppLockPin(normalizedPin, config)) {
      if (_appLockNeedsUpgrade(config)) {
        await _replaceAppLockPin(normalizedPin);
      }
      _privacyLocked = false;
      _appLockFailures = 0;
      _appLockBlockedUntil = null;
      await _store.clearAppLockState();
      notifyListeners();
      return;
    }
    _appLockFailures += 1;
    final lockDuration = _appLockLockDuration(_appLockFailures);
    _appLockBlockedUntil =
        lockDuration == Duration.zero ? null : now.add(lockDuration);
    await _persistAppLockState();
    notifyListeners();
    throw ArgumentError('Niepoprawny PIN.');
  }

  bool isContactOnline(String contactId) {
    if (cloudMode) return true;
    return false;
  }

  String displayNameForUser(String userId) {
    return _contactById(userId)?.displayName ??
        (userId == _cloudSession?.userId || userId == _identity?.userId
            ? 'Ty'
            : userId);
  }

  String safetyNumberFor(Contact contact) {
    final ownKey = ownPublicKey;
    final contactKey = contact.signingPublicKey?.isNotEmpty == true
        ? contact.signingPublicKey!
        : contact.identityPublicKey;
    if (ownKey == null || ownKey.isEmpty || contactKey.isEmpty) {
      return '';
    }
    return SafetyNumber.calculate(
      ownUserId: ownUserId ?? '',
      ownIdentityPublicKey: ownKey,
      contactUserId: contact.userId,
      contactIdentityPublicKey: contactKey,
    );
  }

  Future<void> initialize() async {
    try {
      await _loadPackageInfo();
      _privacyScreenEnabled = await _store.loadPrivacyScreenEnabled();
      _appLock = _appLockFromStore(await _store.loadAppLockPin());
      _restoreAppLockState(
        _appLock == null ? null : await _store.loadAppLockState(),
      );
      await _refreshScreenSecurity();
      await cleanupTempMediaFiles(maxAge: Duration.zero);
      _cloudSession = await _store.loadCloudSession();
      _identity = null;
      _ownProfile = await _store.loadOwnProfile();
      _contacts
        ..clear()
        ..addAll(await _store.loadContacts());
      await _loadArchivedMessages();
      await _clearLegacySessions();
      await _loadCloudReplayStates();
      _initializing = false;
      notifyListeners();

      if (_cloudSession != null) {
        await connectCloud();
        unawaited(checkForUpdate(silent: true));
      }
    } catch (error) {
      _initializing = false;
      _setStatus('Nie udalo sie wczytac konfiguracji: $error');
    }
  }

  Future<void> registerCloudAccount({
    required String serverUrl,
    required String username,
    required String password,
    required String vaultSecret,
    String inviteToken = '',
  }) async {
    final normalizedServer = _normalizeCloudServerUrl(serverUrl);
    final normalizedUsername = username.trim().toLowerCase();
    if (normalizedUsername.length < 3) {
      throw ArgumentError('Login musi miec minimum 3 znaki.');
    }
    if (password.length < 8) {
      throw ArgumentError('Haslo musi miec minimum 8 znakow.');
    }
    if (vaultSecret.length < 16) {
      throw ArgumentError('Sekret vaultu musi miec minimum 16 znakow.');
    }
    _validateVaultSecretSeparated(password, vaultSecret);

    final vaultSalt = b64(secureRandomBytes(16));
    final vaultKey = await _cloudCrypto.deriveVaultKey(
      vaultSecret: vaultSecret,
      salt: vaultSalt,
    );
    _cloudVaultKdf = Map<String, dynamic>.of(CloudCrypto.defaultVaultKdf);
    final serverOrigin = _cloudSignatureOrigin(normalizedServer);
    var vault = await _cloudCrypto.createVault(serverOrigin: serverOrigin);
    final encryptedVault = await _cloudCrypto.encryptVault(vault, vaultKey);
    final deviceId = _uuid.v4();
    final client = CloudApiClient(serverUrl: normalizedServer);
    final result = await client.register(
      username: normalizedUsername,
      password: password,
      deviceId: deviceId,
      deviceName: _genericDeviceName(),
      keyAgreementPublicKey: vault.keyAgreementPublicKey,
      identityPublicKey: vault.identityPublicKey,
      keyAgreementPublicKeySignature: vault.keyAgreementPublicKeySignature,
      serverOrigin: serverOrigin,
      vaultSalt: vaultSalt,
      encryptedVault: encryptedVault,
      inviteToken: inviteToken.trim(),
    );
    final session = result.session.copyWith(vaultKey: vaultKey);
    vault = await _cloudCrypto.ensureSignedIdentity(
      vault,
      accountId: session.userId,
      serverOrigin: _cloudSignatureOrigin(session.serverUrl),
    );
    await _activateCloudSession(session, vault);
    await _saveCloudVault();
    await _publishCloudKeyBundle();
    await connectCloud();
  }

  Future<void> loginCloudAccount({
    required String serverUrl,
    required String username,
    required String password,
    required String vaultSecret,
  }) async {
    final normalizedServer = _normalizeCloudServerUrl(serverUrl);
    final serverOrigin = _cloudSignatureOrigin(normalizedServer);
    if (vaultSecret.length < 16) {
      throw ArgumentError('Sekret vaultu musi miec minimum 16 znakow.');
    }
    _validateVaultSecretSeparated(password, vaultSecret);
    final deviceId = _uuid.v4();
    final probe = CloudApiClient(serverUrl: normalizedServer);
    final loginProbe = await probe.login(
      username: username.trim().toLowerCase(),
      password: password,
      deviceId: deviceId,
      deviceName: _genericDeviceName(),
      serverOrigin: serverOrigin,
    );
    final vaultKey = await _cloudCrypto.deriveVaultKey(
      vaultSecret: vaultSecret,
      salt: loginProbe.vaultSalt,
      parameters: loginProbe.vaultKdf,
    );
    CloudVault vault;
    final encryptedVault = loginProbe.encryptedVault;
    if (encryptedVault == null) {
      throw StateError('Konto nie ma vaulta z kluczami.');
    }
    final pinnedVault = await _store.loadCloudVaultPin(loginProbe.userId);
    if (pinnedVault != null) {
      final pinnedEpoch = pinnedVault['epoch'] as int? ?? 0;
      final pinnedHash = pinnedVault['hash']?.toString() ?? '';
      if (loginProbe.vaultEpoch < pinnedEpoch ||
          (loginProbe.vaultEpoch == pinnedEpoch &&
              pinnedHash.isNotEmpty &&
              pinnedHash != loginProbe.vaultHash)) {
        throw StateError(
          'Serwer probuje cofnac lub sforkowac zaszyfrowany vault.',
        );
      }
    }
    vault = await _cloudCrypto.ensureSignedIdentity(
      await _cloudCrypto.decryptVault(encryptedVault, vaultKey),
      accountId: loginProbe.userId,
      serverOrigin: _cloudSignatureOrigin(normalizedServer),
    );
    final signature = await _cloudCrypto.signLoginChallenge(
      vault: vault,
      challenge: loginProbe.challenge,
      userId: loginProbe.userId,
      deviceId: loginProbe.deviceId,
      serverOrigin: serverOrigin,
      issuedAtMs: loginProbe.challengeIssuedAtMs,
      expiresAtMs: loginProbe.challengeExpiresAtMs,
    );
    final completed = await probe.completeLogin(
      pendingToken: loginProbe.pendingToken,
      signature: signature,
    );
    final usesDefaultKdf = mapEquals(
      loginProbe.vaultKdf,
      CloudCrypto.defaultVaultKdf,
    );
    _cloudVaultKdf = Map<String, dynamic>.of(CloudCrypto.defaultVaultKdf);
    final activatedVaultKey = usesDefaultKdf
        ? vaultKey
        : await _cloudCrypto.deriveVaultKey(
            vaultSecret: vaultSecret,
            salt: loginProbe.vaultSalt,
          );
    final session = completed.session.copyWith(vaultKey: activatedVaultKey);
    await _store.saveCloudVaultPin(
      loginProbe.userId,
      loginProbe.vaultEpoch,
      loginProbe.vaultHash,
    );
    await _activateCloudSession(session, vault);
    await _saveCloudVault();
    await _publishCloudKeyBundle();
    await connectCloud();
  }

  Future<void> _activateCloudSession(
    CloudSession session,
    CloudVault vault,
  ) async {
    await _cloudSubscription?.cancel();
    await _cloudClient?.dispose();

    _cloudSession = session;
    _cloudVault = vault;
    _cloudDeviceKey = null;
    _ownCloudDeviceList = null;
    _cloudClient = CloudApiClient(
      serverUrl: session.serverUrl,
      token: session.token,
    );
    _identity = null;
    _contacts.clear();
    _messages.clear();
    _cloudConversations.clear();
    _cloudContactToConversation.clear();
    _cloudLastSeq.clear();
    _pendingCloudReplayMessages.clear();
    _cloudGapFetches.clear();
    _cloudSendQueues.clear();
    await _loadCloudReplayStates();
    _cloudConnected = false;
    await _store.saveCloudSession(session);
    await _persistMessages();
    notifyListeners();
  }

  String _normalizeCloudServerUrl(String value) =>
      normalizeCloudServerUrl(value);

  String _cloudSignatureOrigin(String serverUrl) =>
      canonicalCloudOrigin(serverUrl);

  Future<void> checkForUpdate({bool silent = false}) async {
    final updateServerUrl = _cloudSession?.serverUrl;
    if (updateServerUrl == null) return;
    final platform = _updatePlatform();
    if (platform == null) {
      _updateStatus = 'Aktualizacje nie sa wspierane na tej platformie.';
      notifyListeners();
      return;
    }

    _checkingForUpdate = true;
    _updateStatus = silent ? _updateStatus : 'Sprawdzam aktualizacje...';
    notifyListeners();

    try {
      await _ensurePackageInfoLoaded();
      final manifestUri = _updateManifestUri(updateServerUrl);
      final response = await _readJson(manifestUri);
      await _updateSignatureVerifier.verifyManifest(response);
      final latest = (response['latest'] as Map).cast<String, dynamic>();
      final artifacts =
          (latest['artifacts'] as Map?)?.cast<String, dynamic>() ?? const {};
      final artifactRaw = artifacts[platform];
      if (artifactRaw is! Map) {
        _availableUpdate = null;
        _updateStatus = 'Brak paczki aktualizacji dla tej platformy.';
        return;
      }

      final latestBuild = _asInt(latest['buildNumber']);
      final latestVersion = latest['version']?.toString() ?? '0.0.0';
      if (latestBuild <= _currentBuildNumber) {
        _availableUpdate = null;
        _updateStatus =
            silent ? null : 'Masz najnowsza wersje: $_currentVersionLabel.';
        return;
      }

      final artifact = artifactRaw.cast<String, dynamic>();
      final fileName = artifact['file']?.toString() ?? '';
      if (fileName.isEmpty ||
          !RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(fileName)) {
        _availableUpdate = null;
        _updateStatus = 'Manifest aktualizacji nie zawiera nazwy pliku.';
        return;
      }
      final artifactSize = _asNullableInt(artifact['size']);
      if (artifactSize == null ||
          artifactSize <= 0 ||
          artifactSize > _maxUpdateArtifactBytes) {
        _availableUpdate = null;
        _updateStatus =
            'Manifest aktualizacji zawiera niepoprawny rozmiar paczki.';
        return;
      }

      _availableUpdate = AvailableUpdate(
        version: latestVersion,
        buildNumber: latestBuild,
        releasedAt: latest['releasedAt'] == null
            ? null
            : DateTime.tryParse(latest['releasedAt'].toString()),
        notes: ((latest['notes'] as List?) ?? const [])
            .map((item) => item.toString())
            .toList(growable: false),
        artifact: UpdateArtifact(
          platform: platform,
          fileName: fileName,
          url: _artifactUri(updateServerUrl, artifact, fileName),
          sha256: artifact['sha256']?.toString(),
          size: artifactSize,
        ),
      );
      _updateStatus = 'Dostepna aktualizacja: ${_availableUpdate!.label}.';
    } catch (error) {
      if (!silent) {
        _updateStatus = 'Nie udalo sie sprawdzic aktualizacji: $error';
      }
    } finally {
      _checkingForUpdate = false;
      notifyListeners();
    }
  }

  Future<void> downloadAvailableUpdate() async {
    final update = _availableUpdate;
    if (update == null) {
      await checkForUpdate();
      if (_availableUpdate == null) return;
    }

    final selectedUpdate = _availableUpdate!;
    _downloadingUpdate = true;
    _updateDownloadProgress = 0;
    _downloadedUpdatePath = null;
    _updateStatus = 'Pobieram aktualizacje...';
    notifyListeners();

    try {
      final directory = await _updateDownloadDirectory();
      final file = File(
        '${directory.path}${Platform.pathSeparator}${selectedUpdate.artifact.fileName}',
      );
      final partFile = File('${file.path}.${_uuid.v4()}.part');
      final client = HttpClient();
      var completed = false;
      try {
        final request = await client.getUrl(selectedUpdate.artifact.url);
        final response = await request.close();
        if (response.statusCode != 200) {
          throw StateError('Serwer zwrocil HTTP ${response.statusCode}.');
        }
        final expectedSize = selectedUpdate.artifact.size;
        if (expectedSize == null ||
            expectedSize <= 0 ||
            expectedSize > _maxUpdateArtifactBytes) {
          throw StateError(
            'Manifest aktualizacji ma niepoprawny rozmiar paczki.',
          );
        }
        if (response.contentLength != expectedSize) {
          throw StateError(
            'Rozmiar Content-Length nie zgadza sie z podpisanym manifestem.',
          );
        }

        final sink = partFile.openWrite();
        var received = 0;
        try {
          await for (final chunk in response) {
            received += chunk.length;
            if (received > expectedSize) {
              throw StateError(
                'Pobrany strumien przekroczyl rozmiar z manifestu.',
              );
            }
            sink.add(chunk);
            _updateDownloadProgress = received / expectedSize;
            notifyListeners();
          }
        } finally {
          await sink.close();
        }
        if (received != expectedSize) {
          throw StateError('Pobrany plik ma niepelny rozmiar.');
        }
        await _verifyDownloadedUpdate(partFile, selectedUpdate.artifact.sha256);
        if (await file.exists()) {
          await file.delete();
        }
        await partFile.rename(file.path);
        completed = true;
      } finally {
        client.close(force: true);
        if (!completed && await partFile.exists()) {
          try {
            await partFile.delete();
          } catch (_) {}
        }
      }

      _downloadedUpdatePath = file.path;
      _updateDownloadProgress = 1;
      _updateStatus = 'Pobrano aktualizacje: ${file.path}';
      unawaited(_openDownloadedUpdate(file));
    } catch (error) {
      _updateStatus = 'Nie udalo sie pobrac aktualizacji: $error';
      rethrow;
    } finally {
      _downloadingUpdate = false;
      notifyListeners();
    }
  }

  Future<void> connectCloud() async {
    final session = _cloudSession;
    if (session == null) return;
    await _cloudSubscription?.cancel();
    await _cloudClient?.dispose();
    _cloudClient = CloudApiClient(
      serverUrl: session.serverUrl,
      token: session.token,
    );
    _cloudConnected = false;
    _setStatus('Laczenie z kontem...');

    final encryptedVault = await _cloudClient!.vault();
    if (encryptedVault != null) {
      _cloudVault = await _cloudCrypto.ensureSignedIdentity(
        await _cloudCrypto.decryptVault(encryptedVault, session.vaultKey),
        accountId: session.userId,
        serverOrigin: _cloudSignatureOrigin(session.serverUrl),
      );
      await _saveCloudVault();
      await _publishCloudKeyBundle();
    }
    await refreshCloudUsers();
    await _loadCloudConversations();
    _cloudSubscription = _cloudClient!.events.listen(
      (event) => unawaited(_handleCloudEvent(event)),
    );
    await _cloudClient!.connectEvents();
    _cloudConnected = true;
    _setStatus('Konto polaczone.');
    notifyListeners();
  }

  Future<void> refreshCloudUsers({String? username}) async {
    final client = _cloudClient;
    if (client == null || _cloudSession == null) return;
    final users = await client.users(username: username);
    _cloudUsers
      ..clear()
      ..addAll(users);
    notifyListeners();
  }

  Contact _contactFromCloudUser(CloudPublicUser user) {
    return Contact(
      userId: user.userId,
      displayName: user.displayName,
      identityPublicKey: user.keyAgreementPublicKey,
      signingPublicKey: user.identityPublicKey,
      keyAgreementPublicKeySignature: user.keyAgreementPublicKeySignature,
      identityRotationProof: user.identityRotationProof?.toJson(),
      deviceList: user.deviceList?.toJson(),
    );
  }

  bool _contactHasSignedIdentity(Contact contact) {
    return contact.signingPublicKey?.isNotEmpty == true &&
        contact.keyAgreementPublicKeySignature?.isNotEmpty == true;
  }

  Future<void> _assertCloudUserKeyBundle(CloudPublicUser user) async {
    if (user.identityPublicKey.isEmpty ||
        user.keyAgreementPublicKeySignature.isEmpty) {
      throw StateError(
        'Uzytkownik ${user.displayName} nie ma jeszcze podpisanej tozsamosci. Popros go o aktualizacje aplikacji i ponowne logowanie.',
      );
    }
    final valid = await _cloudCrypto.verifyKeyAgreementSignature(
      accountId: user.userId,
      serverOrigin: _cloudSignatureOrigin(_cloudSession!.serverUrl),
      identityPublicKey: user.identityPublicKey,
      keyAgreementPublicKey: user.keyAgreementPublicKey,
      signature: user.keyAgreementPublicKeySignature,
    );
    if (!valid) {
      throw StateError(
        'Podpis klucza uzytkownika ${user.displayName} jest niepoprawny. Nie rozpoczynam rozmowy.',
      );
    }
    await _verifiedCloudUserDeviceList(user);
  }

  Future<CloudDeviceList?> _verifiedCloudUserDeviceList(
    CloudPublicUser user,
  ) async {
    final list = user.deviceList;
    if (list == null) return null;
    var valid = await _cloudCrypto.verifyDeviceList(
      accountId: user.userId,
      serverOrigin: _cloudSignatureOrigin(_cloudSession!.serverUrl),
      identityPublicKey: user.identityPublicKey,
      deviceList: list,
    );
    final proof = user.identityRotationProof;
    if (!valid && proof?.oldIdentityPublicKey.isNotEmpty == true) {
      valid = await _cloudCrypto.verifyDeviceList(
        accountId: user.userId,
        serverOrigin: _cloudSignatureOrigin(_cloudSession!.serverUrl),
        identityPublicKey: proof!.oldIdentityPublicKey,
        deviceList: list,
      );
    }
    if (!valid) {
      throw StateError(
        'Lista urzadzen uzytkownika ${user.displayName} ma niepoprawny podpis.',
      );
    }
    return list;
  }

  bool _isAcceptableDeviceListUpdate(
    CloudDeviceList? previous,
    CloudDeviceList? next,
  ) {
    if (next == null) return true;
    if (previous == null) return true;
    if (next.deviceListEpoch < previous.deviceListEpoch) return false;
    if (next.deviceListEpoch == previous.deviceListEpoch) {
      return next.deviceListHash == previous.deviceListHash;
    }
    if (next.deviceListEpoch != previous.deviceListEpoch + 1) return false;
    return next.previousDeviceListHash == previous.deviceListHash;
  }

  Future<void> _assertContactKeyBundle(Contact contact) async {
    if (!_contactHasSignedIdentity(contact)) {
      throw StateError(
        'Kontakt ${contact.displayName} nie ma podpisanej tozsamosci. Dodaj go ponownie z listy uzytkownikow po aktualizacji.',
      );
    }
    final valid = await _cloudCrypto.verifyKeyAgreementSignature(
      accountId: contact.userId,
      serverOrigin: _cloudSignatureOrigin(_cloudSession!.serverUrl),
      identityPublicKey: contact.signingPublicKey!,
      keyAgreementPublicKey: contact.identityPublicKey,
      signature: contact.keyAgreementPublicKeySignature!,
    );
    if (!valid) {
      throw StateError(
        'Podpis klucza kontaktu ${contact.displayName} jest niepoprawny.',
      );
    }
    final deviceList = CloudDeviceList.fromOptionalJson(contact.deviceList);
    if (deviceList != null) {
      var listValid = await _cloudCrypto.verifyDeviceList(
        accountId: contact.userId,
        serverOrigin: _cloudSignatureOrigin(_cloudSession!.serverUrl),
        identityPublicKey: contact.signingPublicKey!,
        deviceList: deviceList,
      );
      final proof = IdentityRotationProof.fromOptionalJson(
        contact.identityRotationProof,
      );
      if (!listValid && proof?.oldIdentityPublicKey.isNotEmpty == true) {
        listValid = await _cloudCrypto.verifyDeviceList(
          accountId: contact.userId,
          serverOrigin: _cloudSignatureOrigin(_cloudSession!.serverUrl),
          identityPublicKey: proof!.oldIdentityPublicKey,
          deviceList: deviceList,
        );
      }
      if (!listValid) {
        throw StateError(
          'Lista urzadzen kontaktu ${contact.displayName} jest niepoprawna.',
        );
      }
    }
  }

  Future<void> _mergeVerifiedCloudUserIntoContact(
    Contact existing,
    CloudPublicUser peer,
  ) async {
    await _assertCloudUserKeyBundle(peer);
    final nextDeviceList = await _verifiedCloudUserDeviceList(peer);
    final previousDeviceList = CloudDeviceList.fromOptionalJson(
      existing.deviceList,
    );
    if (!_isAcceptableDeviceListUpdate(previousDeviceList, nextDeviceList)) {
      throw StateError(
        'Serwer zwrocil cofnieta albo rozwidlona liste urzadzen dla ${existing.displayName}.',
      );
    }
    if (existing.signingPublicKey?.isNotEmpty != true &&
        existing.identityPublicKey == peer.keyAgreementPublicKey) {
      final index = _contacts.indexWhere((item) => item.userId == peer.userId);
      if (index >= 0) {
        _contacts[index] = existing.copyWith(
          signingPublicKey: peer.identityPublicKey,
          keyAgreementPublicKeySignature: peer.keyAgreementPublicKeySignature,
          deviceList: nextDeviceList?.toJson(),
        );
        await _store.saveContacts(_contacts);
      }
      return;
    }

    if (nextDeviceList != null &&
        jsonEncode(nextDeviceList.toJson()) !=
            jsonEncode(previousDeviceList?.toJson())) {
      final index = _contacts.indexWhere((item) => item.userId == peer.userId);
      if (index >= 0) {
        _contacts[index] = existing.copyWith(
          displayName: peer.displayName,
          deviceList: nextDeviceList.toJson(),
        );
        await _store.saveContacts(_contacts);
      }
    }

    if (existing.signingPublicKey != peer.identityPublicKey ||
        existing.identityPublicKey != peer.keyAgreementPublicKey) {
      if (await _acceptCloudUserIdentityRotation(existing, peer)) {
        return;
      }
      throw StateError(
        'Ostrzezenie: serwer zwrocil inna podpisana tozsamosc dla ${existing.displayName} bez poprawnej rotacji podpisanej starym kluczem. Rozmowa zostala zablokowana do recznej weryfikacji.',
      );
    }
  }

  Future<bool> _acceptCloudUserIdentityRotation(
    Contact existing,
    CloudPublicUser peer,
  ) async {
    final proof = peer.identityRotationProof;
    if (proof == null || existing.signingPublicKey?.isNotEmpty != true) {
      return false;
    }
    if (proof.oldIdentityPublicKey != existing.signingPublicKey ||
        proof.newIdentityPublicKey != peer.identityPublicKey ||
        proof.newKeyAgreementPublicKey != peer.keyAgreementPublicKey) {
      return false;
    }
    final previousProof = IdentityRotationProof.fromOptionalJson(
      existing.identityRotationProof,
    );
    if (!_cloudCrypto.isNextIdentityRotation(
      previousProof: previousProof,
      nextProof: proof,
    )) {
      return false;
    }
    final valid = await _cloudCrypto.verifyIdentityRotationProof(
      accountId: peer.userId,
      serverOrigin: _cloudSignatureOrigin(_cloudSession!.serverUrl),
      proof: proof,
    );
    if (!valid) return false;

    final index = _contacts.indexWhere((item) => item.userId == peer.userId);
    if (index < 0) return false;
    _contacts[index] = existing.copyWith(
      displayName: peer.displayName,
      identityPublicKey: peer.keyAgreementPublicKey,
      signingPublicKey: peer.identityPublicKey,
      keyAgreementPublicKeySignature: peer.keyAgreementPublicKeySignature,
      identityRotationProof: proof.toJson(),
      deviceList: peer.deviceList?.toJson(),
    );
    await _store.saveContacts(_contacts);
    _setStatus(
      'Tozsamosc ${peer.displayName} zostala zaktualizowana podpisana rotacja.',
    );
    return true;
  }

  Future<bool> _acceptContactIdentityRotation(
    Contact existing,
    Contact contact,
  ) async {
    final proof = IdentityRotationProof.fromOptionalJson(
      contact.identityRotationProof,
    );
    if (proof == null || existing.signingPublicKey?.isNotEmpty != true) {
      return false;
    }
    if (proof.oldIdentityPublicKey != existing.signingPublicKey ||
        proof.newIdentityPublicKey != contact.signingPublicKey ||
        proof.newKeyAgreementPublicKey != contact.identityPublicKey) {
      return false;
    }
    final previousProof = IdentityRotationProof.fromOptionalJson(
      existing.identityRotationProof,
    );
    if (!_cloudCrypto.isNextIdentityRotation(
      previousProof: previousProof,
      nextProof: proof,
    )) {
      return false;
    }
    final valid = await _cloudCrypto.verifyIdentityRotationProof(
      accountId: contact.userId,
      serverOrigin: _cloudSignatureOrigin(_cloudSession!.serverUrl),
      proof: proof,
    );
    if (!valid) return false;

    final index = _contacts.indexWhere((item) => item.userId == contact.userId);
    if (index < 0) return false;
    _contacts[index] = existing.copyWith(
      displayName: contact.displayName,
      identityPublicKey: contact.identityPublicKey,
      signingPublicKey: contact.signingPublicKey,
      keyAgreementPublicKeySignature: contact.keyAgreementPublicKeySignature,
      identityRotationProof: proof.toJson(),
      deviceList: contact.deviceList,
    );
    await _store.saveContacts(_contacts);
    _setStatus(
      'Tozsamosc ${contact.displayName} zostala zaktualizowana podpisana rotacja.',
    );
    return true;
  }

  Future<void> _loadCloudConversations() async {
    final client = _cloudClient;
    final session = _cloudSession;
    if (client == null || session == null) return;
    final conversations = await client.conversations();
    for (final conversation in conversations) {
      await _rememberCloudConversation(conversation);
      await _loadCloudMessages(conversation);
    }
  }

  Future<void> _rememberCloudConversation(
    CloudConversation conversation,
  ) async {
    final session = _cloudSession;
    if (session == null) return;
    _cloudConversations[conversation.conversationId] = conversation;
    String? peerId;
    for (final memberId in conversation.memberIds) {
      if (memberId != session.userId) {
        peerId = memberId;
        break;
      }
    }
    if (peerId == null) return;
    _cloudContactToConversation[peerId] = conversation.conversationId;

    CloudPublicUser? peer;
    for (final user in _cloudUsers) {
      if (user.userId == peerId) {
        peer = user;
        break;
      }
    }
    try {
      final existing = _contactById(peerId);
      if (existing == null && peer != null) {
        await _assertCloudUserKeyBundle(peer);
        _contacts.add(_contactFromCloudUser(peer));
        _contacts.sort((a, b) => a.displayName.compareTo(b.displayName));
        await _store.saveContacts(_contacts);
      } else if (existing != null && peer != null) {
        await _mergeVerifiedCloudUserIntoContact(existing, peer);
      }
    } catch (error) {
      _setStatus(error.toString());
      return;
    }
    try {
      await _ensureCloudConversationKey(conversation);
    } catch (error) {
      _setStatus(error.toString());
    }
  }

  Future<void> _loadCloudMessages(CloudConversation conversation) async {
    final client = _cloudClient;
    if (client == null) return;
    final afterSeq = _cloudLastSeq[conversation.conversationId] ?? 0;
    final messages = await client.messages(
      conversationId: conversation.conversationId,
      afterSeq: afterSeq,
    );
    for (final message in messages) {
      try {
        await _applyCloudMessage(message, notify: false);
      } catch (error) {
        _setStatus(error.toString());
      }
    }
    if (messages.isNotEmpty) {
      await _persistMessages();
      notifyListeners();
    }
  }

  Future<void> _handleCloudEvent(CloudEvent event) async {
    switch (event) {
      case CloudReady():
        _cloudConnected = true;
        _setStatus('Konto polaczone.');
        break;
      case CloudConversationEvent():
        await _rememberCloudConversation(event.conversation);
        notifyListeners();
        break;
      case CloudMessageEvent():
        try {
          await _applyCloudMessage(event.message);
        } catch (error) {
          _setStatus(error.toString());
        }
        break;
      case CloudProblem():
        _cloudConnected = false;
        _setStatus(event.message);
        break;
    }
  }

  Future<void> _saveCloudVault() async {
    final client = _cloudClient;
    final vault = _cloudVault;
    final session = _cloudSession;
    if (client == null || vault == null || session == null) return;
    final encryptedVault = await _cloudCrypto.encryptVault(
      vault,
      session.vaultKey,
    );
    final version = await client.saveVault(
      encryptedVault,
      vaultKdf: _cloudVaultKdf,
    );
    await _store.saveCloudVaultPin(session.userId, version.epoch, version.hash);
  }

  Future<void> _publishCloudKeyBundle() async {
    for (var attempt = 0; attempt < 2; attempt += 1) {
      try {
        await _publishCloudKeyBundleOnce();
        return;
      } catch (error) {
        if (attempt == 0 &&
            error.toString().contains('Lista urzadzen zostala zmieniona')) {
          _ownCloudDeviceList = null;
          continue;
        }
        rethrow;
      }
    }
  }

  Future<void> _publishCloudKeyBundleOnce() async {
    final client = _cloudClient;
    final vault = _cloudVault;
    if (client == null || vault == null) return;
    final deviceKey = await _ensureCloudDeviceKey();
    final deviceListState = await _ensureCloudDeviceList(deviceKey);
    await client.updateKeyBundle(
      keyAgreementPublicKey: vault.keyAgreementPublicKey,
      identityPublicKey: vault.identityPublicKey,
      keyAgreementPublicKeySignature: vault.keyAgreementPublicKeySignature,
      deviceCertificate: deviceKey.certificate.toJson(),
      deviceList: deviceListState.list.toJson(),
      deviceListHash: deviceListState.list.deviceListHash,
      expectedDeviceListEpoch: deviceListState.expectedEpoch,
      expectedDeviceListHash: deviceListState.expectedHash,
      identityRotationProof: vault.identityRotationProof?.toJson(),
    );
    _ownCloudDeviceList = deviceListState.list;
  }

  Future<CloudDeviceKeyMaterial> _ensureCloudDeviceKey() async {
    final session = _cloudSession;
    final vault = _cloudVault;
    if (session == null || vault == null) {
      throw StateError('Najpierw zaloguj sie na konto.');
    }
    final origin = _cloudSignatureOrigin(session.serverUrl);
    final cached = _cloudDeviceKey ?? await _store.loadCloudDeviceKey();
    if (cached != null &&
        cached.accountId == session.userId &&
        cached.serverOrigin == origin &&
        cached.deviceId == session.deviceId &&
        cached.deviceSigningPublicKey ==
            cached.certificate.deviceSigningPublicKey &&
        await _cloudCrypto.verifyDeviceCertificate(
          accountId: session.userId,
          serverOrigin: origin,
          identityPublicKey: vault.identityPublicKey,
          certificate: cached.certificate,
        )) {
      _cloudDeviceKey = cached;
      return cached;
    }

    final created = await _cloudCrypto.createDeviceKeyMaterial(
      vault: vault,
      accountId: session.userId,
      serverOrigin: origin,
      deviceId: session.deviceId,
    );
    _cloudDeviceKey = created;
    await _store.saveCloudDeviceKey(created);
    return created;
  }

  Future<({CloudDeviceList list, int expectedEpoch, String expectedHash})>
      _ensureCloudDeviceList(CloudDeviceKeyMaterial deviceKey) async {
    final session = _cloudSession;
    final vault = _cloudVault;
    final client = _cloudClient;
    if (session == null || vault == null || client == null) {
      throw StateError('Najpierw zaloguj sie na konto.');
    }
    final origin = _cloudSignatureOrigin(session.serverUrl);
    final current = await client.currentUser();
    final previous = current.deviceList;
    var previousSignedByCurrentIdentity = false;
    if (previous != null) {
      previousSignedByCurrentIdentity = await _cloudCrypto.verifyDeviceList(
        accountId: session.userId,
        serverOrigin: origin,
        identityPublicKey: vault.identityPublicKey,
        deviceList: previous,
      );
      var valid = previousSignedByCurrentIdentity;
      final proof = vault.identityRotationProof;
      if (!valid && proof?.oldIdentityPublicKey.isNotEmpty == true) {
        valid = await _cloudCrypto.verifyDeviceList(
          accountId: session.userId,
          serverOrigin: origin,
          identityPublicKey: proof!.oldIdentityPublicKey,
          deviceList: previous,
        );
      }
      if (!valid) {
        throw StateError('Serwer zwrocil niepoprawna liste urzadzen konta.');
      }
    }

    final expectedEpoch = previous?.deviceListEpoch ?? 0;
    final expectedHash = previous?.deviceListHash ?? '';
    final entry = _cloudCrypto.deviceListEntryForCertificate(
      deviceKey.certificate,
    );
    if (previous != null) {
      if (previous.isRevoked(deviceKey.deviceId)) {
        throw StateError('To urzadzenie jest uniewaznione na liscie konta.');
      }
      final existing = previous.activeDevice(deviceKey.deviceId);
      if (existing != null) {
        if (existing.deviceSigningPublicKey != entry.deviceSigningPublicKey ||
            existing.certificateHash != entry.certificateHash) {
          throw StateError(
            'Lista urzadzen zawiera inny klucz dla tego deviceId.',
          );
        }
        if (previousSignedByCurrentIdentity) {
          _ownCloudDeviceList = previous;
          return (
            list: previous,
            expectedEpoch: expectedEpoch,
            expectedHash: expectedHash,
          );
        }
      }
    }

    final devices = <CloudDeviceListEntry>[
      ...?previous?.devices,
      if (previous?.activeDevice(deviceKey.deviceId) == null) entry,
    ]..sort((a, b) => a.deviceId.compareTo(b.deviceId));
    final signed = await _cloudCrypto.signDeviceList(
      vault: vault,
      accountId: session.userId,
      serverOrigin: origin,
      previousList: previous,
      devices: devices,
      revokedDevices: previous?.revokedDevices ?? const [],
    );
    _ownCloudDeviceList = signed;
    return (
      list: signed,
      expectedEpoch: expectedEpoch,
      expectedHash: expectedHash,
    );
  }

  Future<void> rotateCloudIdentity() async {
    final session = _cloudSession;
    final vault = _cloudVault;
    if (session == null || vault == null || _cloudClient == null) {
      throw StateError('Najpierw zaloguj sie na konto.');
    }
    final rotation = await _cloudCrypto.rotateIdentity(
      vault: vault,
      accountId: session.userId,
      serverOrigin: _cloudSignatureOrigin(session.serverUrl),
    );
    _cloudVault = rotation.vault;
    await _saveCloudVault();
    await _publishCloudKeyBundle();
    _setStatus('Tozsamosc konta zostala zrotowana i podpisana starym kluczem.');
    notifyListeners();
  }

  Future<void> revokeCloudDevice(String deviceId) async {
    final session = _cloudSession;
    final vault = _cloudVault;
    final client = _cloudClient;
    if (session == null || vault == null || client == null) {
      throw StateError('Najpierw zaloguj sie na konto.');
    }
    if (deviceId == session.deviceId) {
      throw StateError('Nie mozna uniewaznic aktualnie uzywanego urzadzenia.');
    }

    final deviceKey = await _ensureCloudDeviceKey();
    var current = await client.currentUser();
    if (current.deviceList == null) {
      await _publishCloudKeyBundle();
      current = await client.currentUser();
    }
    final previous = current.deviceList;
    if (previous == null) {
      throw StateError('Konto nie ma jeszcze podpisanej listy urzadzen.');
    }
    final origin = _cloudSignatureOrigin(session.serverUrl);
    var valid = await _cloudCrypto.verifyDeviceList(
      accountId: session.userId,
      serverOrigin: origin,
      identityPublicKey: vault.identityPublicKey,
      deviceList: previous,
    );
    final proof = vault.identityRotationProof;
    if (!valid && proof?.oldIdentityPublicKey.isNotEmpty == true) {
      valid = await _cloudCrypto.verifyDeviceList(
        accountId: session.userId,
        serverOrigin: origin,
        identityPublicKey: proof!.oldIdentityPublicKey,
        deviceList: previous,
      );
    }
    if (!valid) {
      throw StateError('Serwer zwrocil niepoprawna liste urzadzen konta.');
    }

    final target = previous.activeDevice(deviceId);
    if (target == null) {
      if (previous.isRevoked(deviceId)) {
        throw StateError('To urzadzenie jest juz uniewaznione.');
      }
      throw StateError('Nie ma takiego aktywnego urzadzenia na liscie.');
    }
    final devices = previous.devices
        .where((device) => device.deviceId != deviceId)
        .toList(growable: false);
    final revokedDevices = [
      ...previous.revokedDevices,
      CloudRevokedDevice(
        deviceId: target.deviceId,
        deviceSigningPublicKey: target.deviceSigningPublicKey,
        deviceCertificateHash: target.certificateHash,
        revokedDeviceEpoch: target.deviceEpoch,
        revokedAt: DateTime.now().toUtc(),
        reasonCode: 'user',
      ),
    ];
    final signed = await _cloudCrypto.signDeviceList(
      vault: vault,
      accountId: session.userId,
      serverOrigin: origin,
      previousList: previous,
      devices: devices,
      revokedDevices: revokedDevices,
    );
    await client.updateKeyBundle(
      keyAgreementPublicKey: vault.keyAgreementPublicKey,
      identityPublicKey: vault.identityPublicKey,
      keyAgreementPublicKeySignature: vault.keyAgreementPublicKeySignature,
      deviceCertificate: deviceKey.certificate.toJson(),
      deviceList: signed.toJson(),
      deviceListHash: signed.deviceListHash,
      expectedDeviceListEpoch: previous.deviceListEpoch,
      expectedDeviceListHash: previous.deviceListHash,
      identityRotationProof: vault.identityRotationProof?.toJson(),
    );
    _ownCloudDeviceList = signed;
    await _rotateAllCloudConversationKeys();
    _setStatus('Urzadzenie zostalo uniewaznione, a klucze rozmow obrocone.');
    notifyListeners();
  }

  Future<void> _rotateAllCloudConversationKeys() async {
    final session = _cloudSession;
    final vault = _cloudVault;
    final client = _cloudClient;
    if (session == null || vault == null || client == null) return;
    final updatedKeys = Map<String, String>.of(vault.conversationKeys);
    final blockedGroupIds = <String>[];
    for (final conversation in _cloudConversations.values) {
      if (conversation.type != 'direct') {
        blockedGroupIds.add(conversation.conversationId);
        continue;
      }
      final newKey = await _cloudCrypto.newConversationKey();
      final envelopes = <String, dynamic>{};
      for (final memberId in conversation.memberIds) {
        final recipientKey = memberId == session.userId
            ? vault.keyAgreementPublicKey
            : _contactById(memberId)?.identityPublicKey;
        if (recipientKey == null || recipientKey.isEmpty) {
          throw StateError(
            'Brak zweryfikowanego klucza czlonka $memberId do rotacji.',
          );
        }
        envelopes[memberId] = await _cloudCrypto.wrapConversationKey(
          vault: vault,
          conversationId: conversation.conversationId,
          keyEpoch: conversation.keyEpoch + 1,
          senderUserId: session.userId,
          senderDeviceId: session.deviceId,
          recipientUserId: memberId,
          recipientPublicKey: recipientKey,
          conversationKey: newKey,
        );
      }
      final rotated = await client.rotateConversationKey(
        conversationId: conversation.conversationId,
        expectedKeyEpoch: conversation.keyEpoch,
        memberKeys: envelopes,
      );
      _cloudConversations[rotated.conversationId] = rotated;
      updatedKeys[conversation.conversationId] = newKey;
    }
    _cloudVault = vault.copyWith(conversationKeys: updatedKeys);
    await _saveCloudVault();
    if (blockedGroupIds.isNotEmpty) {
      throw StateError(
        'Usunieto urzadzenie i obrocono klucze rozmow 1:1. '
        'Wysylanie do ${blockedGroupIds.length} starych grup cloud pozostaje '
        'zablokowane do migracji bezpiecznego protokolu grupowego.',
      );
    }
  }

  Future<String?> _ensureCloudConversationKey(
    CloudConversation conversation,
  ) async {
    final session = _cloudSession;
    final vault = _cloudVault;
    if (session == null || vault == null) return null;
    final existing = vault.conversationKeys[conversation.conversationId];
    if (existing != null) return existing;
    final envelope = conversation.memberKeys[session.userId];
    if (envelope is! Map) return null;
    final envelopeJson = envelope.cast<String, dynamic>();
    final senderUserId = envelopeJson['senderUserId']?.toString() ?? '';
    final senderPublicKey = envelopeJson['senderPublicKey']?.toString() ?? '';
    final senderIdentityPublicKey =
        envelopeJson['senderIdentityPublicKey']?.toString() ?? '';
    if (envelopeJson['conversationId'] != conversation.conversationId ||
        envelopeJson['keyEpoch'] != conversation.keyEpoch) {
      throw StateError(
        'Serwer podal kopertę klucza z innej rozmowy lub epoki.',
      );
    }
    late final String expectedSenderIdentityPublicKey;
    late final String expectedSenderKeyAgreementPublicKey;
    if (senderUserId == session.userId) {
      expectedSenderIdentityPublicKey = vault.identityPublicKey;
      expectedSenderKeyAgreementPublicKey = vault.keyAgreementPublicKey;
    } else {
      final contact = _contactById(senderUserId);
      if (contact == null || !_contactHasSignedIdentity(contact)) {
        throw StateError(
          'Brak zaufanej, podpisanej tozsamosci nadawcy koperty klucza.',
        );
      }
      expectedSenderIdentityPublicKey = contact.signingPublicKey!;
      expectedSenderKeyAgreementPublicKey = contact.identityPublicKey;
      if (contact.identityPublicKey != senderPublicKey ||
          contact.signingPublicKey != senderIdentityPublicKey) {
        throw StateError(
          'Klucz kontaktu ${contact.displayName} nie zgadza sie z zapisana, podpisana tozsamoscia. Zweryfikuj safety number przed rozmowa.',
        );
      }
    }
    final key = await _cloudCrypto.unwrapConversationKey(
      vault: vault,
      localUserId: session.userId,
      expectedSenderIdentityPublicKey: expectedSenderIdentityPublicKey,
      expectedSenderKeyAgreementPublicKey: expectedSenderKeyAgreementPublicKey,
      envelope: envelopeJson,
    );
    final keys = Map<String, String>.of(vault.conversationKeys);
    keys[conversation.conversationId] = key;
    _cloudVault = vault.copyWith(conversationKeys: keys);
    await _saveCloudVault();
    return key;
  }

  Future<void> _applyCloudMessage(
    CloudStoredMessage stored, {
    bool notify = true,
    bool drainBuffered = true,
  }) async {
    final session = _cloudSession;
    if (session == null) return;
    final conversation = _cloudConversations[stored.conversationId];
    if (conversation == null) return;
    final key = await _ensureCloudConversationKey(conversation);
    if (key == null) return;

    String? peerId;
    for (final memberId in conversation.memberIds) {
      if (memberId != session.userId) {
        peerId = memberId;
        break;
      }
    }
    if (peerId == null) return;

    final payloadAad = asStringKeyMap(stored.payload['aad'], 'aad');
    final aadSenderUserId =
        payloadAad['senderUserId']?.toString() ?? stored.senderUserId;
    final aadSenderDeviceId =
        payloadAad['senderDeviceId']?.toString() ?? stored.senderDeviceId;
    final deviceSignatureVerified = await _verifyCloudMessageDeviceSignature(
      senderUserId: aadSenderUserId,
      senderDeviceId: aadSenderDeviceId,
      payload: stored.payload,
    );
    if (!_cloudCrypto.hasDeviceSignature(stored.payload) ||
        !deviceSignatureVerified) {
      throw StateError(
        'Wiadomosc bez poprawnego certyfikatu i podpisu urzadzenia zostala odrzucona.',
      );
    }
    final existingReplayState = _cloudReplayStateFor(
      conversationId: stored.conversationId,
      senderUserId: stored.senderUserId,
      senderDeviceId: aadSenderDeviceId,
    );
    if ((existingReplayState?.requiresDeviceSignature ?? false) &&
        !deviceSignatureVerified) {
      throw StateError(
        'Wiadomosc cloud nie ma poprawnego podpisu znanego urzadzenia.',
      );
    }

    final decrypted = await _cloudCrypto.decryptMessage(
      conversationId: stored.conversationId,
      expectedKeyEpoch: conversation.keyEpoch,
      conversationKey: key,
      payload: stored.payload,
    );
    if (decrypted.senderUserId.isNotEmpty &&
        decrypted.senderUserId != stored.senderUserId) {
      throw StateError('Nadawca w AAD wiadomosci nie zgadza sie z serwerem.');
    }
    if (decrypted.senderDeviceId.isNotEmpty &&
        stored.senderDeviceId.isNotEmpty &&
        decrypted.senderDeviceId != stored.senderDeviceId) {
      throw StateError(
        'Urzadzenie nadawcy w AAD wiadomosci nie zgadza sie z serwerem.',
      );
    }
    final senderDeviceId = decrypted.senderDeviceId.isNotEmpty
        ? decrypted.senderDeviceId
        : stored.senderDeviceId;
    if (_hasCloudMessage(stored.conversationId, decrypted.messageId)) {
      await _advanceCloudReplayStateForStoredMessage(
        conversationId: stored.conversationId,
        senderUserId: stored.senderUserId,
        senderDeviceId: senderDeviceId,
        messageCounter: decrypted.messageCounter,
        previousMessageHash: decrypted.previousMessageHash,
        messageHash: decrypted.messageHash,
        requiresDeviceSignature: deviceSignatureVerified,
      );
      final currentSeq = _cloudLastSeq[stored.conversationId] ?? 0;
      if (stored.seq > currentSeq) {
        _cloudLastSeq[stored.conversationId] = stored.seq;
      }
      return;
    }

    final replayDecision = _checkCloudMessageReplayState(
      stored: stored,
      conversation: conversation,
      conversationId: stored.conversationId,
      senderUserId: stored.senderUserId,
      senderDeviceId: senderDeviceId,
      messageCounter: decrypted.messageCounter,
      previousMessageHash: decrypted.previousMessageHash,
    );
    if (replayDecision == _CloudReplayDecision.buffer) return;

    final direction = stored.senderUserId == session.userId
        ? MessageDirection.outbound
        : MessageDirection.inbound;
    final handledControlPayload = _applyCloudControlPayload(
      peerId: peerId,
      senderUserId: stored.senderUserId,
      direction: direction,
      payload: decrypted.payload,
      createdAt: decrypted.createdAt,
    );
    if (handledControlPayload) {
      if (replayDecision == _CloudReplayDecision.accept) {
        await _rememberCloudReplayState(
          conversationId: stored.conversationId,
          senderUserId: stored.senderUserId,
          senderDeviceId: senderDeviceId,
          lastCounter: decrypted.messageCounter!,
          lastMessageHash: decrypted.messageHash,
          requiresDeviceSignature: deviceSignatureVerified,
        );
      }
      final currentSeq = _cloudLastSeq[stored.conversationId] ?? 0;
      if (stored.seq > currentSeq) {
        _cloudLastSeq[stored.conversationId] = stored.seq;
      }
      if (drainBuffered && replayDecision == _CloudReplayDecision.accept) {
        await _drainCloudReplayBuffer(
          conversationId: stored.conversationId,
          senderUserId: stored.senderUserId,
          senderDeviceId: senderDeviceId,
        );
      }
      if (notify) notifyListeners();
      return;
    }
    final added = _addMessage(
      ChatMessage(
        id: decrypted.messageId,
        contactId: peerId,
        direction: direction,
        payload: decrypted.payload,
        createdAt: decrypted.createdAt,
        status: direction == MessageDirection.outbound
            ? MessageStatus.sent
            : MessageStatus.delivered,
        senderId: stored.senderUserId,
        transport: 'cloud',
      ),
    );
    if (added) {
      await _persistMessages();
      if (replayDecision == _CloudReplayDecision.accept) {
        await _rememberCloudReplayState(
          conversationId: stored.conversationId,
          senderUserId: stored.senderUserId,
          senderDeviceId: senderDeviceId,
          lastCounter: decrypted.messageCounter!,
          lastMessageHash: decrypted.messageHash,
          requiresDeviceSignature: deviceSignatureVerified,
        );
      }
    }
    final currentSeq = _cloudLastSeq[stored.conversationId] ?? 0;
    if (stored.seq > currentSeq) {
      _cloudLastSeq[stored.conversationId] = stored.seq;
    }
    if (added && direction == MessageDirection.inbound) {
      final contact = _contactById(peerId);
      unawaited(
        DesktopNotifier.instance.notifyIncoming(
          senderName: contact?.displayName ?? peerId,
          payload: decrypted.payload,
        ),
      );
    }
    if (drainBuffered && replayDecision == _CloudReplayDecision.accept) {
      await _drainCloudReplayBuffer(
        conversationId: stored.conversationId,
        senderUserId: stored.senderUserId,
        senderDeviceId: senderDeviceId,
      );
    }
    if (notify) notifyListeners();
  }

  bool _applyCloudControlPayload({
    required String peerId,
    required String senderUserId,
    required MessageDirection direction,
    required PlainPayload payload,
    required DateTime createdAt,
  }) {
    final targetMessageId = payload.targetMessageId;
    switch (payload.type) {
      case PlainPayloadType.text:
        return false;
      case PlainPayloadType.file:
        return false;
      case PlainPayloadType.retraction:
        if (targetMessageId == null) return true;
        _markMessageRetracted(
          peerId,
          targetMessageId,
          allowedDirection: direction,
          fallbackCreatedAt: createdAt,
          fallbackTransport: 'cloud',
        );
        return true;
      case PlainPayloadType.reaction:
        if (targetMessageId == null) return true;
        _applyReaction(
          peerId,
          targetMessageId,
          senderUserId,
          payload.reactionEmoji,
        );
        return true;
      case PlainPayloadType.pin:
        if (targetMessageId == null) return true;
        _applyPin(peerId, targetMessageId, payload.pinPinned == true);
        return true;
      case PlainPayloadType.receipt:
        if (targetMessageId == null) return true;
        if (direction == MessageDirection.inbound) {
          _applyReceipt(
            peerId,
            targetMessageId,
            payload.receiptKind ?? ReceiptKind.delivered,
          );
        }
        return true;
      case PlainPayloadType.edit:
        if (targetMessageId == null) return true;
        _applyEdit(
          peerId,
          targetMessageId,
          payload.editedText ?? '',
          allowedDirection: direction,
          editedAt: createdAt,
        );
        return true;
    }
  }

  Future<void> _sendCloudPayload(Contact contact, PlainPayload payload) async {
    final session = _cloudSession;
    final client = _cloudClient;
    if (session == null || client == null) {
      throw StateError('Najpierw zaloguj sie na konto.');
    }
    await _startCloudDirectContact(contact);
    final conversationId = _cloudContactToConversation[contact.userId];
    if (conversationId == null) {
      throw StateError('Nie mozna utworzyc rozmowy cloud.');
    }
    final queueKey = '$conversationId|${session.userId}|${session.deviceId}';
    await _enqueueCloudSend(
      queueKey,
      () => _sendCloudPayloadLocked(
        contact: contact,
        payload: payload,
        session: session,
        client: client,
        conversationId: conversationId,
        recordLocally: true,
      ),
    );
  }

  Future<void> _sendCloudControlPayload(
    Contact contact,
    PlainPayload payload,
  ) async {
    final session = _cloudSession;
    final client = _cloudClient;
    if (session == null || client == null) {
      throw StateError('Najpierw zaloguj sie na konto.');
    }
    await _startCloudDirectContact(contact);
    final conversationId = _cloudContactToConversation[contact.userId];
    if (conversationId == null) {
      throw StateError('Nie mozna utworzyc rozmowy cloud.');
    }
    final queueKey = '$conversationId|${session.userId}|${session.deviceId}';
    await _enqueueCloudSend(
      queueKey,
      () => _sendCloudPayloadLocked(
        contact: contact,
        payload: payload,
        session: session,
        client: client,
        conversationId: conversationId,
        recordLocally: false,
      ),
    );
  }

  Future<void> _sendCloudPayloadLocked({
    required Contact contact,
    required PlainPayload payload,
    required CloudSession session,
    required CloudApiClient client,
    required String conversationId,
    required bool recordLocally,
  }) async {
    final conversation = _cloudConversations[conversationId];
    if (conversation == null) {
      throw StateError('Brak rozmowy cloud.');
    }
    final key = await _ensureCloudConversationKey(conversation);
    if (key == null) {
      throw StateError('Brak klucza rozmowy cloud.');
    }
    final deviceKey = await _ensureCloudDeviceKey();
    final streamState = _cloudReplayStateFor(
      conversationId: conversationId,
      senderUserId: session.userId,
      senderDeviceId: session.deviceId,
    );
    final messageCounter = (streamState?.lastCounter ?? 0) + 1;
    final previousMessageHash =
        streamState?.lastMessageHash ?? _cloudCrypto.cloudMessageGenesisHash;
    final encrypted = await _cloudCrypto.encryptMessage(
      conversationId: conversationId,
      senderUserId: session.userId,
      senderDeviceId: session.deviceId,
      keyEpoch: conversation.keyEpoch,
      messageCounter: messageCounter,
      previousMessageHash: previousMessageHash,
      conversationKey: key,
      deviceKey: deviceKey,
      payload: payload,
    );
    final messageId = requiredString(encrypted, 'messageId');
    if (recordLocally) {
      _addMessage(
        ChatMessage(
          id: messageId,
          contactId: contact.userId,
          direction: MessageDirection.outbound,
          payload: payload,
          createdAt: DateTime.parse(
            requiredString(
              asStringKeyMap(encrypted['aad'], 'aad'),
              'createdAt',
            ),
          ),
          status: MessageStatus.pending,
          senderId: session.userId,
          transport: 'cloud',
        ),
      );
    }
    final stored = await client.sendMessage(
      conversationId: conversationId,
      messageId: messageId,
      payload: encrypted,
    );
    await _rememberCloudReplayState(
      conversationId: conversationId,
      senderUserId: session.userId,
      senderDeviceId: session.deviceId,
      lastCounter: messageCounter,
      lastMessageHash: _cloudCrypto.cloudMessageHash(encrypted),
      requiresDeviceSignature: true,
    );
    if (recordLocally) {
      _updateMessage(
        contact.userId,
        messageId,
        MessageStatus.sent,
        transport: 'cloud',
      );
    }
    final currentSeq = _cloudLastSeq[conversationId] ?? 0;
    if (stored.seq > currentSeq) _cloudLastSeq[conversationId] = stored.seq;
  }

  Future<void> addContact(Contact contact) async {
    if (cloudMode) {
      await _startCloudDirectContact(contact);
      return;
    }
    final localUserId = _identity?.userId;
    if (contact.userId == localUserId) {
      throw ArgumentError('Nie dodawaj wlasnej tozsamosci jako kontaktu.');
    }
    if (contact.identityPublicKey.isEmpty) {
      throw ArgumentError('Klucz publiczny kontaktu jest pusty.');
    }

    final existing = _contactById(contact.userId);
    _contacts.removeWhere((item) => item.userId == contact.userId);
    _contacts.add(
      Contact(
        userId: contact.userId,
        displayName: contact.displayName,
        identityPublicKey: contact.identityPublicKey,
        signingPublicKey:
            contact.signingPublicKey ?? existing?.signingPublicKey,
        keyAgreementPublicKeySignature:
            contact.keyAgreementPublicKeySignature ??
                existing?.keyAgreementPublicKeySignature,
        identityRotationProof:
            contact.identityRotationProof ?? existing?.identityRotationProof,
        deviceList: contact.deviceList ?? existing?.deviceList,
        avatarMimeType: existing?.avatarMimeType ?? contact.avatarMimeType,
        avatarBytesBase64:
            existing?.avatarBytesBase64 ?? contact.avatarBytesBase64,
        profileUpdatedAt:
            existing?.profileUpdatedAt ?? contact.profileUpdatedAt,
      ),
    );
    _contacts.sort((a, b) => a.displayName.compareTo(b.displayName));
    await _store.saveContacts(_contacts);
    notifyListeners();
  }

  Future<void> startCloudConversation(CloudPublicUser user) async {
    await _assertCloudUserKeyBundle(user);
    await _startCloudDirectContact(_contactFromCloudUser(user));
  }

  Future<void> _startCloudDirectContact(Contact contact) async {
    final session = _cloudSession;
    final vault = _cloudVault;
    final client = _cloudClient;
    if (session == null || vault == null || client == null) {
      throw StateError('Najpierw zaloguj sie na konto.');
    }
    if (contact.userId == session.userId) {
      throw StateError('To jest Twoje konto.');
    }

    final existing = _contactById(contact.userId);
    if (existing == null) {
      await _assertContactKeyBundle(contact);
      _contacts.add(contact);
      _contacts.sort((a, b) => a.displayName.compareTo(b.displayName));
      await _store.saveContacts(_contacts);
    } else if (existing.signingPublicKey?.isNotEmpty != true &&
        existing.identityPublicKey == contact.identityPublicKey &&
        _contactHasSignedIdentity(contact)) {
      final index = _contacts.indexWhere(
        (item) => item.userId == contact.userId,
      );
      if (index >= 0) {
        _contacts[index] = existing.copyWith(
          signingPublicKey: contact.signingPublicKey,
          keyAgreementPublicKeySignature:
              contact.keyAgreementPublicKeySignature,
          identityRotationProof: contact.identityRotationProof,
          deviceList: contact.deviceList,
        );
        await _store.saveContacts(_contacts);
      }
    } else if (existing.identityPublicKey != contact.identityPublicKey ||
        existing.signingPublicKey != contact.signingPublicKey) {
      if (await _acceptContactIdentityRotation(existing, contact)) {
        await _assertContactKeyBundle(_contactById(contact.userId) ?? contact);
      } else {
        throw StateError(
          'Podpisana tozsamosc kontaktu ${existing.displayName} zmienila sie bez poprawnej rotacji podpisanej starym kluczem. Nie wysylam wiadomosci przed reczna weryfikacja.',
        );
      }
    }
    await _assertContactKeyBundle(_contactById(contact.userId) ?? contact);

    final existingConversationId = _cloudContactToConversation[contact.userId];
    if (existingConversationId != null) {
      notifyListeners();
      return;
    }

    final conversationKey = await _cloudCrypto.newConversationKey();
    final conversationId = _uuid.v4();
    final memberKeys = <String, dynamic>{
      session.userId: await _cloudCrypto.wrapConversationKey(
        vault: vault,
        conversationId: conversationId,
        keyEpoch: 1,
        senderUserId: session.userId,
        senderDeviceId: session.deviceId,
        recipientUserId: session.userId,
        recipientPublicKey: vault.keyAgreementPublicKey,
        conversationKey: conversationKey,
      ),
      contact.userId: await _cloudCrypto.wrapConversationKey(
        vault: vault,
        conversationId: conversationId,
        keyEpoch: 1,
        senderUserId: session.userId,
        senderDeviceId: session.deviceId,
        recipientUserId: contact.userId,
        recipientPublicKey: contact.identityPublicKey,
        conversationKey: conversationKey,
      ),
    };
    final conversation = await client.createDirectConversation(
      conversationId: conversationId,
      peerUserId: contact.userId,
      memberKeys: memberKeys,
    );
    await _rememberCloudConversation(conversation);
    notifyListeners();
  }

  Future<void> removeContact(Contact contact) async {
    final removed = _contacts.any((item) => item.userId == contact.userId);
    _contacts.removeWhere((item) => item.userId == contact.userId);
    _messages.remove(contact.userId);

    if (!removed) return;
    await _store.saveContacts(_contacts);
    await _persistMessages();
    notifyListeners();
  }

  Future<void> setProfileImage() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      throw StateError('Nie mozna odczytac obrazu na tej platformie.');
    }
    if (bytes.length > maxProfileImageBytes) {
      throw StateError(
        'Profilowe jest za duze. Limit: ${maxProfileImageBytes ~/ 1024} KB.',
      );
    }

    final mimeType = _guessMimeType(file.name);
    if (mimeType == null || !mimeType.startsWith('image/')) {
      throw StateError(
        'Profilowe musi byc obrazem JPG, PNG, GIF, WEBP albo BMP.',
      );
    }

    _ownProfile = UserProfile(
      avatarMimeType: mimeType,
      avatarBytesBase64: b64(bytes),
      updatedAt: DateTime.now().toUtc(),
    );
    await _store.saveOwnProfile(_ownProfile!);
    notifyListeners();
  }

  Future<void> clearProfileImage() async {
    _ownProfile = UserProfile(updatedAt: DateTime.now().toUtc());
    await _store.saveOwnProfile(_ownProfile!);
    notifyListeners();
  }

  Future<void> sendText(
    Contact contact,
    String text, {
    String? replyToMessageId,
    String? replyPreview,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _sendPlainPayload(
      contact,
      PlainPayload.text(
        trimmed,
        replyToMessageId: replyToMessageId,
        replyPreview: replyPreview,
      ),
    );
  }

  Future<void> markConversationRead(Contact contact) async {
    final list = _messages[contact.userId];
    if (list == null) return;

    final readMessageIds = <String>[];
    var changed = false;
    for (var index = 0; index < list.length; index += 1) {
      final message = list[index];
      if (!_isUnreadIncomingMessage(message)) continue;

      list[index] = message.copyWith(status: MessageStatus.read);
      readMessageIds.add(message.id);
      changed = true;
    }

    if (!changed) return;
    await _persistMessages();
    notifyListeners();

    for (final messageId in readMessageIds) {
      unawaited(_sendReceipt(contact, messageId, ReceiptKind.read));
    }
  }

  Future<void> editMessage(
    Contact contact,
    ChatMessage message,
    String text,
  ) async {
    if (message.contactId != contact.userId) {
      throw ArgumentError('Wiadomosc nie nalezy do tego kontaktu.');
    }
    if (message.direction != MessageDirection.outbound) {
      throw StateError('Mozesz edytowac tylko wlasne wiadomosci.');
    }
    if (message.retracted || message.payload.type != PlainPayloadType.text) {
      throw StateError('Tej wiadomosci nie mozna edytowac.');
    }
    if (message.status == MessageStatus.failed) {
      throw StateError(
        'Ta wiadomosc nie zostala wyslana. Usun ja lokalnie albo wyslij ponownie.',
      );
    }

    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Edytowana wiadomosc nie moze byc pusta.');
    }
    if (trimmed == (message.payload.text ?? '').trim()) return;

    if (!cloudMode) {
      throw StateError(
        'Stary transport relay zostal usuniety. Zaloguj sie do konta cloud.',
      );
    }
    await _sendCloudControlPayload(
      contact,
      PlainPayload.edit(targetMessageId: message.id, editedText: trimmed),
    );
    _applyEdit(
      contact.userId,
      message.id,
      trimmed,
      allowedDirection: MessageDirection.outbound,
    );
  }

  Future<void> retractMessage(Contact contact, ChatMessage message) async {
    if (message.contactId != contact.userId) {
      throw ArgumentError('Wiadomosc nie nalezy do tego kontaktu.');
    }
    if (message.direction != MessageDirection.outbound) {
      throw StateError('Mozesz cofnac tylko wlasna wyslana wiadomosc.');
    }
    if (message.retracted) return;
    if (message.status == MessageStatus.failed) {
      throw StateError(
        'Ta wiadomosc nie zostala dostarczona. Usun ja lokalnie.',
      );
    }

    if (!cloudMode) {
      throw StateError(
        'Stary transport relay zostal usuniety. Zaloguj sie do konta cloud.',
      );
    }
    await _sendCloudControlPayload(
      contact,
      PlainPayload.retraction(targetMessageId: message.id),
    );
    _markMessageRetracted(
      contact.userId,
      message.id,
      allowedDirection: MessageDirection.outbound,
    );
  }

  Future<void> deleteMessageLocally(String contactId, String messageId) async {
    final list = _messages[contactId];
    if (list == null) return;

    final before = list.length;
    list.removeWhere((message) => message.id == messageId);
    if (list.isEmpty) {
      _messages.remove(contactId);
    }
    if (before == list.length) return;

    await _persistMessages();
    notifyListeners();
  }

  Future<void> deleteConversationLocally(String contactId) async {
    if (!_messages.containsKey(contactId)) return;
    _messages.remove(contactId);
    await _persistMessages();
    notifyListeners();
  }

  Future<void> reactToMessage(
    Contact contact,
    ChatMessage message,
    String? emoji,
  ) async {
    if (message.contactId != contact.userId) {
      throw ArgumentError('Wiadomosc nie nalezy do tego kontaktu.');
    }
    if (message.direction == MessageDirection.system || message.retracted) {
      throw StateError('Nie mozna zareagowac na te wiadomosc.');
    }

    final normalizedEmoji = emoji?.trim();
    if (!cloudMode) {
      throw StateError(
        'Stary transport relay zostal usuniety. Zaloguj sie do konta cloud.',
      );
    }
    final senderId = ownUserId ?? _requireIdentity().userId;
    await _sendCloudControlPayload(
      contact,
      PlainPayload.reaction(
        targetMessageId: message.id,
        reactionEmoji: normalizedEmoji == null || normalizedEmoji.isEmpty
            ? null
            : normalizedEmoji,
      ),
    );
    _applyReaction(contact.userId, message.id, senderId, normalizedEmoji);
  }

  Future<void> setMessagePinned(
    Contact contact,
    ChatMessage message,
    bool pinned,
  ) async {
    if (message.contactId != contact.userId) {
      throw ArgumentError('Wiadomosc nie nalezy do tego kontaktu.');
    }
    if (message.direction == MessageDirection.system || message.retracted) {
      return;
    }

    if (!cloudMode) {
      throw StateError(
        'Stary transport relay zostal usuniety. Zaloguj sie do konta cloud.',
      );
    }
    await _sendCloudControlPayload(
      contact,
      PlainPayload.pin(targetMessageId: message.id, pinPinned: pinned),
    );
    _applyPin(contact.userId, message.id, pinned);
  }

  Future<void> sendFile(
    Contact contact, {
    String? replyToMessageId,
    String? replyPreview,
  }) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      throw StateError('Nie mozna odczytac pliku na tej platformie.');
    }
    await sendFileBytes(
      contact,
      fileName: file.name,
      bytes: bytes,
      mimeType: _guessMimeType(file.name),
      replyToMessageId: replyToMessageId,
      replyPreview: replyPreview,
    );
  }

  Future<void> sendFileBytes(
    Contact contact, {
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
    String? replyToMessageId,
    String? replyPreview,
  }) async {
    final effectiveLimit =
        cloudMode ? maxCloudPlainFileBytes : maxPlainFileBytes;
    if (bytes.length > effectiveLimit) {
      throw StateError(
        'Plik jest za duzy. Limit: ${_fileLimitLabel(effectiveLimit)}.',
      );
    }

    await _sendPlainPayload(
      contact,
      PlainPayload.file(
        fileName: fileName,
        mimeType: mimeType ?? _guessMimeType(fileName),
        fileSize: bytes.length,
        fileBytesBase64: b64(bytes),
        replyToMessageId: replyToMessageId,
        replyPreview: replyPreview,
      ),
    );
  }

  Future<void> wipeLocalData() async {
    await _cloudSubscription?.cancel();
    await _cloudClient?.dispose();
    await _store.wipeLocalSecrets();
    _identity = null;
    _cloudSession = null;
    _cloudVault = null;
    _cloudDeviceKey = null;
    _ownCloudDeviceList = null;
    _cloudClient = null;
    _ownProfile = null;
    _contacts.clear();
    _messages.clear();
    _cloudConversations.clear();
    _cloudContactToConversation.clear();
    _cloudLastSeq.clear();
    _cloudReplayStates.clear();
    _pendingCloudReplayMessages.clear();
    _cloudGapFetches.clear();
    _cloudSendQueues.clear();
    _cloudDeviceKey = null;
    _ownCloudDeviceList = null;
    _cloudUsers.clear();
    _presenceTimer?.cancel();
    _cloudConnected = false;
    _privacyScreenEnabled = true;
    _privacyLocked = false;
    _appLock = null;
    _appLockFailures = 0;
    _appLockBlockedUntil = null;
    await _refreshScreenSecurity();
    await _messageArchive.delete();
    _setStatus('Wyczyszczono lokalne dane.');
  }

  Future<void> _sendPlainPayload(Contact contact, PlainPayload payload) async {
    if (cloudMode) {
      await _sendCloudPayload(contact, payload);
      return;
    }
    throw StateError(
      'Stary transport relay zostal usuniety. Zaloguj sie do konta cloud.',
    );
  }

  Future<void> _sendReceipt(
    Contact contact,
    String messageId,
    ReceiptKind kind,
  ) async {
    await _sendControlPayload(
      contact,
      PlainPayload.receipt(targetMessageId: messageId, receiptKind: kind),
    );
  }

  Future<void> _sendControlPayload(
    Contact contact,
    PlainPayload payload,
  ) async {
    if (cloudMode) {
      await _sendCloudControlPayload(contact, payload);
    }
  }

  bool _addMessage(ChatMessage message) {
    final list = _messages.putIfAbsent(
      message.contactId,
      () => <ChatMessage>[],
    );
    if (list.any((item) => item.id == message.id)) return false;
    list.add(message);
    _sortMessages(list);
    unawaited(_persistMessages());
    notifyListeners();
    return true;
  }

  void _sortMessages(List<ChatMessage> messages) {
    messages.sort((left, right) {
      final byTime = left.createdAt.compareTo(right.createdAt);
      if (byTime != 0) return byTime;
      return left.id.compareTo(right.id);
    });
  }

  bool _markMessageRetracted(
    String contactId,
    String messageId, {
    required MessageDirection allowedDirection,
    DateTime? fallbackCreatedAt,
    String? fallbackTransport,
  }) {
    final list = _messages.putIfAbsent(contactId, () => <ChatMessage>[]);
    final index = list.indexWhere((message) => message.id == messageId);
    if (index >= 0) {
      final message = list[index];
      if (message.direction != allowedDirection) return false;
      if (message.retracted) return true;

      list[index] = message.copyWith(
        payload: const PlainPayload.text(''),
        retracted: true,
        pinned: false,
        reactions: const {},
        clearEditedAt: true,
      );
      unawaited(_persistMessages());
      notifyListeners();
      return true;
    }

    if (allowedDirection != MessageDirection.inbound) return false;
    final placeholder = ChatMessage(
      id: messageId,
      contactId: contactId,
      direction: MessageDirection.inbound,
      payload: const PlainPayload.text(''),
      createdAt: fallbackCreatedAt ?? DateTime.now().toUtc(),
      status: MessageStatus.delivered,
      retracted: true,
      transport: fallbackTransport,
    );
    list.add(placeholder);
    unawaited(_persistMessages());
    notifyListeners();
    return true;
  }

  bool _applyEdit(
    String contactId,
    String messageId,
    String text, {
    required MessageDirection allowedDirection,
    DateTime? editedAt,
  }) {
    final list = _messages[contactId];
    if (list == null) return false;
    final index = list.indexWhere((message) => message.id == messageId);
    if (index < 0) return false;

    final message = list[index];
    if (message.direction != allowedDirection ||
        message.retracted ||
        message.payload.type != PlainPayloadType.text) {
      return false;
    }

    final normalizedText = text.trim();
    if (normalizedText.isEmpty) return false;

    list[index] = message.copyWith(
      payload: PlainPayload.text(
        normalizedText,
        replyToMessageId: message.payload.replyToMessageId,
        replyPreview: message.payload.replyPreview,
      ),
      editedAt: editedAt ?? DateTime.now().toUtc(),
    );
    unawaited(_persistMessages());
    notifyListeners();
    return true;
  }

  bool _applyReceipt(String contactId, String messageId, ReceiptKind kind) {
    final list = _messages[contactId];
    if (list == null) return false;
    final index = list.indexWhere((message) => message.id == messageId);
    if (index < 0) return false;

    final message = list[index];
    if (message.direction != MessageDirection.outbound) return false;

    final nextStatus = switch (kind) {
      ReceiptKind.delivered => MessageStatus.delivered,
      ReceiptKind.read => MessageStatus.read,
    };
    final promotedStatus = _promoteStatus(message.status, nextStatus);
    if (promotedStatus == message.status) return true;

    list[index] = message.copyWith(status: promotedStatus);
    unawaited(_persistMessages());
    notifyListeners();
    return true;
  }

  bool _applyReaction(
    String contactId,
    String messageId,
    String reactorId,
    String? emoji,
  ) {
    final list = _messages[contactId];
    if (list == null) return false;
    final index = list.indexWhere((message) => message.id == messageId);
    if (index < 0) return false;

    final message = list[index];
    if (message.direction == MessageDirection.system || message.retracted) {
      return false;
    }

    final reactions = Map<String, String>.of(message.reactions);
    final normalizedEmoji = emoji?.trim();
    if (normalizedEmoji == null || normalizedEmoji.isEmpty) {
      reactions.remove(reactorId);
    } else {
      reactions[reactorId] = normalizedEmoji;
    }

    list[index] = message.copyWith(reactions: reactions);
    unawaited(_persistMessages());
    notifyListeners();
    return true;
  }

  bool _applyPin(String contactId, String messageId, bool pinned) {
    final list = _messages[contactId];
    if (list == null) return false;
    final index = list.indexWhere((message) => message.id == messageId);
    if (index < 0) return false;

    final message = list[index];
    if (message.direction == MessageDirection.system || message.retracted) {
      return false;
    }

    if (message.pinned == pinned) return true;
    list[index] = message.copyWith(pinned: pinned);
    unawaited(_persistMessages());
    notifyListeners();
    return true;
  }

  void _updateMessage(
    String contactId,
    String messageId,
    MessageStatus status, {
    String? transport,
    String? error,
  }) {
    final list = _messages[contactId];
    if (list == null) return;
    final index = list.indexWhere((message) => message.id == messageId);
    if (index < 0) return;
    list[index] = list[index].copyWith(
      status: _promoteStatus(list[index].status, status),
      transport: transport,
      error: error,
    );
    unawaited(_persistMessages());
    notifyListeners();
  }

  bool _isUnreadIncomingMessage(ChatMessage message) {
    return message.direction == MessageDirection.inbound &&
        message.status != MessageStatus.read &&
        !message.retracted &&
        (message.payload.type == PlainPayloadType.text ||
            message.payload.type == PlainPayloadType.file);
  }

  MessageStatus _promoteStatus(MessageStatus current, MessageStatus incoming) {
    if (incoming == MessageStatus.failed) {
      return current == MessageStatus.delivered || current == MessageStatus.read
          ? current
          : MessageStatus.failed;
    }
    if (current == MessageStatus.failed) return incoming;
    return _statusRank(incoming) > _statusRank(current) ? incoming : current;
  }

  int _statusRank(MessageStatus status) {
    return switch (status) {
      MessageStatus.pending => 0,
      MessageStatus.sent => 1,
      MessageStatus.delivered => 2,
      MessageStatus.read => 3,
      MessageStatus.failed => -1,
    };
  }

  List<ChatMessage> _allMessagesSnapshot() {
    final snapshot =
        _messages.values.expand((messages) => messages).toList(growable: false);
    snapshot.sort((left, right) {
      final byContact = left.contactId.compareTo(right.contactId);
      if (byContact != 0) return byContact;
      final byTime = left.createdAt.compareTo(right.createdAt);
      if (byTime != 0) return byTime;
      return left.id.compareTo(right.id);
    });
    return snapshot;
  }

  Future<void> _loadPackageInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _currentBuildNumber = int.tryParse(info.buildNumber) ?? 0;
      _currentVersionLabel = '${info.version}+${info.buildNumber}';
    } catch (_) {
      _currentBuildNumber = 0;
      _currentVersionLabel = 'nieznana';
    }
  }

  Future<void> _ensurePackageInfoLoaded() async {
    if (_currentVersionLabel.isEmpty) {
      await _loadPackageInfo();
      await cleanupTempMediaFiles(maxAge: Duration.zero);
    }
  }

  String? _updatePlatform() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isAndroid) return 'android';
    return null;
  }

  String _genericDeviceName() {
    if (Platform.isWindows) return 'Windows device';
    if (Platform.isLinux) return 'Linux device';
    if (Platform.isAndroid) return 'Android device';
    return 'Device';
  }

  void _validateVaultSecretSeparated(String password, String vaultSecret) {
    if (!cloudAccountPasswordSeparatedFromVaultSecret(password, vaultSecret)) {
      throw ArgumentError(
        'Sekret vaultu musi byc inny niz haslo konta. Haslo konta jest przekazywane serwerowi.',
      );
    }
  }

  Uri _updateManifestUri(String serverUrl) {
    final serverUri = Uri.parse(serverUrl);
    final scheme = switch (serverUri.scheme) {
      'wss' => 'https',
      'ws' => 'http',
      '' => 'https',
      _ => serverUri.scheme,
    };
    return serverUri.replace(
      scheme: scheme,
      path: '/updates/manifest.json',
      query: null,
      fragment: null,
    );
  }

  Uri _artifactUri(
    String serverUrl,
    Map<String, dynamic> artifact,
    String fileName,
  ) {
    final explicitUrl = artifact['url']?.toString();
    if (explicitUrl != null && explicitUrl.isNotEmpty) {
      final uri = Uri.parse(explicitUrl);
      if (uri.hasScheme) return uri;
    }

    final manifestUri = _updateManifestUri(serverUrl);
    return manifestUri.replace(
      pathSegments: ['updates', 'files', fileName],
      query: null,
      fragment: null,
    );
  }

  Future<Directory> _updateDownloadDirectory() async {
    if (Platform.isAndroid) {
      return getApplicationDocumentsDirectory();
    }
    try {
      return await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
    } catch (_) {
      return getApplicationDocumentsDirectory();
    }
  }

  Future<Map<String, dynamic>> _readJson(Uri uri) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw StateError('HTTP ${response.statusCode}');
      }
      final raw = await _readLimitedUtf8(response, _maxUpdateManifestBytes);
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _readLimitedUtf8(
    Stream<List<int>> stream,
    int maxBytes,
  ) async {
    final chunks = <int>[];
    await for (final chunk in stream) {
      chunks.addAll(chunk);
      if (chunks.length > maxBytes) {
        throw StateError('Odpowiedz serwera jest za duza.');
      }
    }
    return utf8.decode(chunks);
  }

  int _asInt(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  int? _asNullableInt(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    return int.tryParse(value.toString());
  }

  Future<void> _verifyDownloadedUpdate(
    File file,
    String? expectedSha256,
  ) async {
    final expected = expectedSha256?.trim().toLowerCase();
    if (expected == null || expected.isEmpty) return;

    final actual =
        crypto_hash.sha256.convert(await file.readAsBytes()).toString();
    if (actual != expected) {
      try {
        await file.delete();
      } catch (_) {}
      throw StateError(
        'Suma SHA-256 pobranego pliku nie zgadza sie z manifestem.',
      );
    }
  }

  Future<void> _openDownloadedUpdate(File file) async {
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', file.path]);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [file.path]);
      }
    } catch (_) {
      // Otwieranie pliku jest dodatkiem. Pobieranie jest juz zakonczone.
    }
  }

  Future<void> _loadArchivedMessages() async {
    final archived = await _messageArchive.load();
    _messages.clear();
    for (final message in archived) {
      final list = _messages.putIfAbsent(
        message.contactId,
        () => <ChatMessage>[],
      );
      if (!list.any((item) => item.id == message.id)) {
        list.add(message);
      }
    }
    for (final list in _messages.values) {
      _sortMessages(list);
    }
  }

  Future<void> _clearLegacySessions() {
    return _store.clearLegacySessions();
  }

  Future<void> _loadCloudReplayStates() async {
    _cloudReplayStates.clear();
    final session = _cloudSession;
    if (session == null) return;
    final states = await _store.loadCloudMessageReplayStates();
    for (final state in states) {
      if (state.accountId == session.userId) {
        _cloudReplayStates[state.key] = state;
      }
    }
  }

  Future<void> _saveCloudReplayStates() {
    return _store.saveCloudMessageReplayStates(_cloudReplayStates.values);
  }

  String _cloudReplayKey({
    required String conversationId,
    required String senderUserId,
    required String senderDeviceId,
  }) {
    final accountId = _cloudSession?.userId ?? '';
    return '$accountId|$conversationId|$senderUserId|$senderDeviceId';
  }

  CloudMessageReplayState? _cloudReplayStateFor({
    required String conversationId,
    required String senderUserId,
    required String senderDeviceId,
  }) {
    return _cloudReplayStates[_cloudReplayKey(
      conversationId: conversationId,
      senderUserId: senderUserId,
      senderDeviceId: senderDeviceId,
    )];
  }

  Future<bool> _verifyCloudMessageDeviceSignature({
    required String senderUserId,
    required String senderDeviceId,
    required Map<String, dynamic> payload,
  }) async {
    if (!_cloudCrypto.hasDeviceSignature(payload) || senderDeviceId.isEmpty) {
      return false;
    }
    final session = _cloudSession;
    if (session == null) return false;

    final identityPublicKeys = <String>[];
    CloudDeviceList? deviceList;
    if (senderUserId == session.userId) {
      final key = _cloudVault?.identityPublicKey ?? '';
      if (key.isNotEmpty) identityPublicKeys.add(key);
      deviceList = _ownCloudDeviceList;
    } else {
      final contact = _contactById(senderUserId);
      final key = contact?.signingPublicKey ?? '';
      if (key.isNotEmpty) identityPublicKeys.add(key);
      final proof = IdentityRotationProof.fromOptionalJson(
        contact?.identityRotationProof,
      );
      if (proof?.oldIdentityPublicKey.isNotEmpty == true) {
        identityPublicKeys.add(proof!.oldIdentityPublicKey);
      }
      deviceList = CloudDeviceList.fromOptionalJson(contact?.deviceList);
      if (identityPublicKeys.isEmpty) {
        for (final user in _cloudUsers) {
          if (user.userId == senderUserId) {
            if (user.identityPublicKey.isNotEmpty) {
              identityPublicKeys.add(user.identityPublicKey);
            }
            deviceList = user.deviceList;
            break;
          }
        }
      }
    }
    if (identityPublicKeys.isEmpty) return false;
    var signatureValid = false;
    for (final identityPublicKey in identityPublicKeys.toSet()) {
      signatureValid = await _cloudCrypto.verifyDeviceMessageSignature(
        accountId: senderUserId,
        serverOrigin: _cloudSignatureOrigin(session.serverUrl),
        identityPublicKey: identityPublicKey,
        senderDeviceId: senderDeviceId,
        payload: payload,
      );
      if (signatureValid) break;
    }
    if (!signatureValid) return false;

    if (deviceList != null) {
      final rawCertificate = payload['deviceCertificate'];
      if (rawCertificate is! Map) return false;
      final certificate = CloudDeviceCertificate.fromJson(
        rawCertificate.cast<String, dynamic>(),
      );
      final activeDevice = deviceList.activeDevice(senderDeviceId);
      if (activeDevice == null || deviceList.isRevoked(senderDeviceId)) {
        return false;
      }
      if (activeDevice.deviceSigningPublicKey !=
              certificate.deviceSigningPublicKey ||
          activeDevice.certificateHash != certificate.certificateHash) {
        return false;
      }
    }
    return true;
  }

  _CloudReplayDecision _checkCloudMessageReplayState({
    required CloudStoredMessage stored,
    required CloudConversation conversation,
    required String conversationId,
    required String senderUserId,
    required String senderDeviceId,
    required int? messageCounter,
    required String previousMessageHash,
  }) {
    final session = _cloudSession;
    if (session == null || messageCounter == null || senderDeviceId.isEmpty) {
      throw StateError(
        'Wiadomosc legacy bez licznika lub urzadzenia zostala odrzucona.',
      );
    }
    if (messageCounter < 1) {
      throw StateError('Niepoprawny licznik wiadomosci cloud.');
    }
    final existing = _cloudReplayStateFor(
      conversationId: conversationId,
      senderUserId: senderUserId,
      senderDeviceId: senderDeviceId,
    );
    if (existing != null) {
      if (messageCounter <= existing.lastCounter) {
        throw StateError('Wykryto powtorzona wiadomosc cloud.');
      }
      if (messageCounter > existing.lastCounter + 1) {
        return _bufferCloudReplayMessage(
          stored: stored,
          conversation: conversation,
          senderUserId: senderUserId,
          senderDeviceId: senderDeviceId,
          messageCounter: messageCounter,
        );
      }
      if (previousMessageHash != existing.lastMessageHash) {
        throw StateError(
          'Wykryto przerwanie albo zmiane kolejnosci strumienia wiadomosci cloud.',
        );
      }
      return _CloudReplayDecision.accept;
    }

    if (messageCounter > 1) {
      return _bufferCloudReplayMessage(
        stored: stored,
        conversation: conversation,
        senderUserId: senderUserId,
        senderDeviceId: senderDeviceId,
        messageCounter: messageCounter,
      );
    }
    if (previousMessageHash != _cloudCrypto.cloudMessageGenesisHash) {
      throw StateError('Pierwsza wiadomosc cloud ma niepoprawny genesis hash.');
    }
    return _CloudReplayDecision.accept;
  }

  Future<void> _advanceCloudReplayStateForStoredMessage({
    required String conversationId,
    required String senderUserId,
    required String senderDeviceId,
    required int? messageCounter,
    required String previousMessageHash,
    required String messageHash,
    required bool requiresDeviceSignature,
  }) async {
    if (messageCounter == null || senderDeviceId.isEmpty) return;
    final existing = _cloudReplayStateFor(
      conversationId: conversationId,
      senderUserId: senderUserId,
      senderDeviceId: senderDeviceId,
    );
    if (existing == null) {
      if (messageCounter == 1 &&
          previousMessageHash == _cloudCrypto.cloudMessageGenesisHash) {
        await _rememberCloudReplayState(
          conversationId: conversationId,
          senderUserId: senderUserId,
          senderDeviceId: senderDeviceId,
          lastCounter: messageCounter,
          lastMessageHash: messageHash,
          requiresDeviceSignature: requiresDeviceSignature,
        );
      }
      return;
    }
    if (messageCounter != existing.lastCounter + 1 ||
        previousMessageHash != existing.lastMessageHash) {
      return;
    }
    await _rememberCloudReplayState(
      conversationId: conversationId,
      senderUserId: senderUserId,
      senderDeviceId: senderDeviceId,
      lastCounter: messageCounter,
      lastMessageHash: messageHash,
      requiresDeviceSignature: requiresDeviceSignature,
    );
  }

  _CloudReplayDecision _bufferCloudReplayMessage({
    required CloudStoredMessage stored,
    required CloudConversation conversation,
    required String senderUserId,
    required String senderDeviceId,
    required int messageCounter,
  }) {
    final streamKey = _cloudReplayKey(
      conversationId: stored.conversationId,
      senderUserId: senderUserId,
      senderDeviceId: senderDeviceId,
    );
    final pending = _pendingCloudReplayMessages.putIfAbsent(
      streamKey,
      () => {},
    );
    pending.putIfAbsent(messageCounter, () => stored);
    _setStatus('Wykryto luke w strumieniu wiadomosci, pobieram brakujace.');
    _requestCloudGapFill(streamKey, conversation);
    return _CloudReplayDecision.buffer;
  }

  void _requestCloudGapFill(String streamKey, CloudConversation conversation) {
    if (!_cloudGapFetches.add(streamKey)) return;
    unawaited(
      _loadCloudMessages(
        conversation,
      ).whenComplete(() => _cloudGapFetches.remove(streamKey)),
    );
  }

  Future<void> _drainCloudReplayBuffer({
    required String conversationId,
    required String senderUserId,
    required String senderDeviceId,
  }) async {
    final streamKey = _cloudReplayKey(
      conversationId: conversationId,
      senderUserId: senderUserId,
      senderDeviceId: senderDeviceId,
    );
    final pending = _pendingCloudReplayMessages[streamKey];
    if (pending == null || pending.isEmpty) return;

    while (true) {
      final state = _cloudReplayStateFor(
        conversationId: conversationId,
        senderUserId: senderUserId,
        senderDeviceId: senderDeviceId,
      );
      final nextCounter = (state?.lastCounter ?? 0) + 1;
      final next = pending.remove(nextCounter);
      if (pending.isEmpty) _pendingCloudReplayMessages.remove(streamKey);
      if (next == null) return;
      await _applyCloudMessage(next, notify: false, drainBuffered: false);
    }
  }

  Future<void> _rememberCloudReplayState({
    required String conversationId,
    required String senderUserId,
    required String senderDeviceId,
    required int lastCounter,
    required String lastMessageHash,
    bool requiresDeviceSignature = false,
  }) async {
    final session = _cloudSession;
    if (session == null || senderDeviceId.isEmpty) return;
    final existing = _cloudReplayStateFor(
      conversationId: conversationId,
      senderUserId: senderUserId,
      senderDeviceId: senderDeviceId,
    );
    final state = CloudMessageReplayState(
      accountId: session.userId,
      conversationId: conversationId,
      senderUserId: senderUserId,
      senderDeviceId: senderDeviceId,
      lastCounter: lastCounter,
      lastMessageHash: lastMessageHash,
      requiresDeviceSignature: requiresDeviceSignature ||
          (existing?.requiresDeviceSignature ?? false),
    );
    _cloudReplayStates[state.key] = state;
    await _saveCloudReplayStates();
  }

  Future<void> _enqueueCloudSend(
    String queueKey,
    Future<void> Function() task,
  ) {
    final previous = _cloudSendQueues[queueKey] ?? Future<void>.value();
    late Future<void> queued;
    queued = previous.catchError((_) {}).then((_) => task()).whenComplete(() {
      if (identical(_cloudSendQueues[queueKey], queued)) {
        _cloudSendQueues.remove(queueKey);
      }
    });
    _cloudSendQueues[queueKey] = queued;
    return queued;
  }

  bool _hasCloudMessage(String conversationId, String messageId) {
    String? contactId;
    for (final entry in _cloudContactToConversation.entries) {
      if (entry.value == conversationId) {
        contactId = entry.key;
        break;
      }
    }
    if (contactId == null) return false;
    return (_messages[contactId] ?? const <ChatMessage>[]).any(
      (message) => message.id == messageId,
    );
  }

  Future<void> _persistMessages() {
    final snapshot = _allMessagesSnapshot();
    _persistQueue = _persistQueue
        .then((_) => _messageArchive.save(snapshot))
        .catchError((_) {});
    return _persistQueue;
  }

  Contact? _contactById(String userId) {
    for (final contact in _contacts) {
      if (contact.userId == userId) return contact;
    }
    return null;
  }

  IdentityKeyMaterial _requireIdentity() {
    final identity = _identity;
    if (identity == null) throw StateError('Brak lokalnej tozsamosci.');
    return identity;
  }

  _AppLockConfig? _appLockFromStore(Map<String, String>? raw) {
    if (raw == null) return null;
    final salt = raw['salt'] ?? '';
    final hash = raw['hash'] ?? '';
    if (salt.isEmpty || hash.isEmpty) return null;
    final algorithm = raw['algorithm'] ?? _legacyAppLockPinAlgorithm;
    final iterations = int.tryParse(raw['iterations'] ?? '') ??
        (algorithm == _appLockPinAlgorithm ? _appLockPinIterations : 1);
    if (algorithm != _appLockPinAlgorithm &&
        algorithm != _legacyAppLockPinAlgorithm) {
      return null;
    }
    if (algorithm == _appLockPinAlgorithm && iterations < 100000) {
      return null;
    }
    return _AppLockConfig(
      algorithm: algorithm,
      iterations: iterations,
      salt: salt,
      hash: hash,
    );
  }

  void _restoreAppLockState(Map<String, dynamic>? raw) {
    _appLockFailures = 0;
    _appLockBlockedUntil = null;
    if (raw == null) return;
    final failedAttempts = raw['failedAttempts'];
    if (failedAttempts is int && failedAttempts > 0) {
      _appLockFailures = failedAttempts;
    }
    final blockedUntilMs = raw['blockedUntilMs'];
    if (blockedUntilMs is int && blockedUntilMs > 0) {
      final blockedUntil = DateTime.fromMillisecondsSinceEpoch(
        blockedUntilMs,
        isUtc: true,
      ).toLocal();
      if (DateTime.now().isBefore(blockedUntil)) {
        _appLockBlockedUntil = blockedUntil;
      }
    }
  }

  void _lockPrivacy() {
    if (!_privacyScreenEnabled && !appLockEnabled) return;
    if (_privacyLocked) return;
    _privacyLocked = true;
    notifyListeners();
  }

  Future<void> _refreshScreenSecurity() {
    return ScreenSecurity.setSecureScreen(
      _privacyScreenEnabled || appLockEnabled,
    );
  }

  String _normalizePin(String pin) {
    return pin.replaceAll(RegExp(r'\s+'), '');
  }

  void _validatePinFormat(String pin) {
    if (!RegExp(r'^\d{6,12}$').hasMatch(pin)) {
      throw ArgumentError('PIN musi miec od 6 do 12 cyfr.');
    }
  }

  Future<String> _hashAppLockPin(
    String pin,
    String salt,
    int iterations,
  ) async {
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: _appLockPinBits,
    ).deriveKey(secretKey: SecretKey(utf8Bytes(pin)), nonce: unb64(salt));
    return b64(await key.extractBytes());
  }

  String _hashLegacyAppLockPin(String pin, String salt) {
    return crypto_hash.sha256.convert(utf8Bytes('$salt:$pin')).toString();
  }

  Future<bool> _verifyAppLockPin(String pin, _AppLockConfig config) async {
    final normalizedPin = _normalizePin(pin);
    final actual = config.algorithm == _appLockPinAlgorithm
        ? await _hashAppLockPin(normalizedPin, config.salt, config.iterations)
        : _hashLegacyAppLockPin(normalizedPin, config.salt);
    return _constantTimeEquals(actual, config.hash);
  }

  bool _appLockNeedsUpgrade(_AppLockConfig config) {
    return config.algorithm != _appLockPinAlgorithm ||
        config.iterations < _appLockPinIterations;
  }

  Future<void> _replaceAppLockPin(String normalizedPin) async {
    final salt = b64(secureRandomBytes(16));
    final hash = await _hashAppLockPin(
      normalizedPin,
      salt,
      _appLockPinIterations,
    );
    await _store.saveAppLockPin(
      algorithm: _appLockPinAlgorithm,
      iterations: _appLockPinIterations,
      salt: salt,
      hash: hash,
    );
    _appLock = _AppLockConfig(
      algorithm: _appLockPinAlgorithm,
      iterations: _appLockPinIterations,
      salt: salt,
      hash: hash,
    );
  }

  Duration _appLockLockDuration(int failedAttempts) {
    if (failedAttempts >= 15) return const Duration(minutes: 30);
    if (failedAttempts >= 10) return const Duration(minutes: 5);
    if (failedAttempts >= 5) return const Duration(seconds: 30);
    return Duration.zero;
  }

  Future<void> _persistAppLockState() {
    return _store.saveAppLockState(
      failedAttempts: _appLockFailures,
      blockedUntil: _appLockBlockedUntil,
    );
  }

  bool _constantTimeEquals(String left, String right) {
    if (left.length != right.length) return false;
    var diff = 0;
    for (var index = 0; index < left.length; index += 1) {
      diff |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
    }
    return diff == 0;
  }

  void _setStatus(String message) {
    _status = message;
    notifyListeners();
  }

  String? _guessMimeType(String fileName) {
    final ext =
        fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'bmp' => 'image/bmp',
      'mp3' => 'audio/mpeg',
      'wav' => 'audio/wav',
      'ogg' => 'audio/ogg',
      'm4a' => 'audio/mp4',
      'aac' => 'audio/aac',
      'flac' => 'audio/flac',
      'mp4' => 'video/mp4',
      'mov' => 'video/quicktime',
      'webm' => 'video/webm',
      'mkv' => 'video/x-matroska',
      'avi' => 'video/x-msvideo',
      'txt' => 'text/plain',
      'pdf' => 'application/pdf',
      'zip' => 'application/zip',
      _ => null,
    };
  }

  String _fileLimitLabel(int bytes) => bytes < 1024 * 1024
      ? '${bytes ~/ 1024} KiB'
      : '${bytes ~/ (1024 * 1024)} MiB';

  @override
  void dispose() {
    _presenceTimer?.cancel();
    unawaited(_cloudSubscription?.cancel());
    unawaited(_cloudClient?.dispose());
    super.dispose();
  }
}
