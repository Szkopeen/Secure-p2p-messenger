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
import 'crypto/crypto_service.dart';
import 'crypto/safety_number.dart';
import 'models/cloud_account.dart';
import 'models/contact.dart';
import 'models/contact_invite.dart';
import 'models/directory_entry.dart';
import 'models/encrypted_packet.dart';
import 'models/group.dart';
import 'models/identity.dart';
import 'models/message.dart';
import 'models/session.dart';
import 'models/update_info.dart';
import 'models/user_profile.dart';
import 'network/relay_client.dart';
import 'platform/file_exporter.dart';
import 'security/update_signature_verifier.dart';
import 'services/cloud_api_client.dart';
import 'services/desktop_notifier.dart';
import 'storage/message_archive.dart';
import 'storage/secure_store.dart';

class AppState extends ChangeNotifier {
  AppState({
    SecureStore? store,
    CryptoService? crypto,
  })  : _store = store ?? SecureStore(),
        _crypto = crypto ?? CryptoService() {
    _messageArchive = MessageArchive(secureStore: _store);
  }

  static const maxPlainFileBytes = 8 * 1024 * 1024;
  static const maxProfileImageBytes = 1024 * 1024;
  static const _accountExportIterations = 310000;
  static const _accountExportAad = 'secure-p2p-account-transfer/v1';
  static const _deviceSyncProtocol = 'secure-p2p-device-sync/v1';
  static const _deviceSyncAad = 'secure-p2p-device-sync-message/v1';

  final SecureStore _store;
  final CryptoService _crypto;
  final CloudCrypto _cloudCrypto = CloudCrypto();
  final UpdateSignatureVerifier _updateSignatureVerifier =
      const UpdateSignatureVerifier();
  late final MessageArchive _messageArchive;
  final Uuid _uuid = const Uuid();
  final AesGcm _accountExportAead = AesGcm.with256bits();
  final AesGcm _deviceSyncAead = AesGcm.with256bits();
  Future<void> _persistQueue = Future<void>.value();
  final List<Contact> _contacts = [];
  final List<ContactInvite> _contactInvites = [];
  final List<GroupConversation> _groups = [];
  final List<DirectoryEntry> _directoryEntries = [];
  final Map<String, List<ChatMessage>> _messages = {};
  final Map<String, SessionState> _sessions = {};
  final Map<String, PendingSession> _pendingSessions = {};
  final Map<String, String> _relayEnvelopeToMessage = {};
  final Map<String, String> _signalEnvelopeToContact = {};
  final Map<String, bool> _relayPresence = {};
  final Map<String, ChatMessage> _pendingDeviceSyncMessages = {};
  final Map<String, CloudConversation> _cloudConversations = {};
  final Map<String, String> _cloudContactToConversation = {};
  final Map<String, int> _cloudLastSeq = {};
  final Map<String, CloudMessageReplayState> _cloudReplayStates = {};
  final List<CloudPublicUser> _cloudUsers = [];
  final Set<String> _pendingInviteHandshakeContacts = {};

  IdentityKeyMaterial? _identity;
  CloudSession? _cloudSession;
  CloudVault? _cloudVault;
  CloudApiClient? _cloudClient;
  StreamSubscription<CloudEvent>? _cloudSubscription;
  UserProfile? _ownProfile;
  RelaySettings? _relaySettings;
  RelayClient? _relay;
  StreamSubscription<RelayEvent>? _relaySubscription;
  Timer? _presenceTimer;
  bool _relayConnected = false;
  bool _initializing = true;
  bool _retryingGroupInvites = false;
  bool _applyingDeviceSync = false;
  bool _sentDeviceSyncSnapshotThisRun = false;
  bool _directoryEnabled = false;
  bool _loadingDirectory = false;
  Timer? _deviceSyncTimer;
  String? _status;
  String? _directoryStatus;
  String _currentVersionLabel = '';
  int _currentBuildNumber = 0;
  AvailableUpdate? _availableUpdate;
  bool _checkingForUpdate = false;
  bool _downloadingUpdate = false;
  double? _updateDownloadProgress;
  String? _updateStatus;
  String? _downloadedUpdatePath;
  int _relayMaxPayloadBytes = 16 * 1024 * 1024;

  bool get initializing => _initializing;
  bool get hasIdentity => _identity != null;
  bool get cloudMode => _cloudSession != null;
  bool get hasAccount => cloudMode;
  bool get relayConnected => _relayConnected;
  String? get status => _status;
  String? get ownUserId => _cloudSession?.userId ?? _identity?.userId;
  String? get ownDisplayName =>
      _cloudSession?.displayName ??
      _cloudSession?.username ??
      _identity?.userId;
  String? get ownPublicKey =>
      _cloudVault?.identityPublicKey ??
      (_identity == null ? null : b64(_identity!.publicKey.bytes));
  UserProfile? get ownProfile => _ownProfile;
  RelaySettings? get relaySettings => _relaySettings;
  List<Contact> get contacts => List.unmodifiable(_contacts);
  List<ContactInvite> get contactInvites => List.unmodifiable(_contactInvites);
  List<GroupConversation> get groups => List.unmodifiable(_groups);
  List<DirectoryEntry> get directoryEntries =>
      List.unmodifiable(_directoryEntries);
  List<CloudPublicUser> get cloudUsers => List.unmodifiable(_cloudUsers);
  bool get directoryEnabled => _directoryEnabled;
  bool get loadingDirectory => _loadingDirectory;
  String? get directoryStatus => _directoryStatus;
  String get currentVersionLabel => _currentVersionLabel;
  AvailableUpdate? get availableUpdate => _availableUpdate;
  bool get checkingForUpdate => _checkingForUpdate;
  bool get downloadingUpdate => _downloadingUpdate;
  double? get updateDownloadProgress => _updateDownloadProgress;
  String? get updateStatus => _updateStatus;
  String? get downloadedUpdatePath => _downloadedUpdatePath;

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

  bool isContactOnline(String contactId) {
    if (cloudMode) return true;
    return _relayPresence[contactId] == true;
  }

  static String? accountTransferPassphraseError(String passphrase) {
    final value = passphrase.trim();
    if (value.length < 8) return 'Minimum 8 znakow.';
    if (!RegExp(r'[A-Z]').hasMatch(value)) {
      return 'Dodaj przynajmniej jedna duza litere.';
    }
    if (!RegExp(r'[0-9]').hasMatch(value)) {
      return 'Dodaj przynajmniej jedna liczbe.';
    }
    if (!RegExp(r'[^A-Za-z0-9]').hasMatch(value)) {
      return 'Dodaj przynajmniej jeden znak specjalny.';
    }
    return null;
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
      _cloudSession = await _store.loadCloudSession();
      _identity = null;
      _ownProfile = await _store.loadOwnProfile();
      _relaySettings = null;
      _contacts
        ..clear()
        ..addAll(await _store.loadContacts());
      _contactInvites
        ..clear()
        ..addAll(await _store.loadContactInvites());
      _groups
        ..clear()
        ..addAll(await _store.loadGroups());
      _directoryEnabled = await _store.loadDirectoryEnabled();
      await _loadArchivedMessages();
      await _loadSessions();
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

  Future<void> createIdentityAndConnect({
    required String userId,
    required String serverUrl,
    required String relayToken,
  }) async {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.length < 3) {
      throw ArgumentError('Identyfikator musi miec minimum 3 znaki.');
    }

    _identity ??= await _crypto.createIdentity(normalizedUserId);
    await _store.saveIdentity(_identity!);

    _relaySettings = RelaySettings(
      serverUrl: serverUrl.trim(),
      relayToken: relayToken.trim(),
    );
    await _store.saveRelaySettings(_relaySettings!);
    await connectRelay();
    unawaited(checkForUpdate(silent: true));
  }

  Future<void> registerCloudAccount({
    required String serverUrl,
    required String username,
    required String password,
    required String vaultSecret,
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

    final vaultSalt = b64(secureRandomBytes(16));
    final vaultKey = await _cloudCrypto.deriveVaultKey(
      vaultSecret: vaultSecret,
      salt: vaultSalt,
    );
    final serverOrigin = _cloudSignatureOrigin(normalizedServer);
    var vault = await _cloudCrypto.createVault(serverOrigin: serverOrigin);
    final encryptedVault = await _cloudCrypto.encryptVault(vault, vaultKey);
    final deviceId = _uuid.v4();
    final client = CloudApiClient(serverUrl: normalizedServer);
    final result = await client.register(
      username: normalizedUsername,
      password: password,
      deviceId: deviceId,
      deviceName: Platform.localHostname,
      keyAgreementPublicKey: vault.keyAgreementPublicKey,
      identityPublicKey: vault.identityPublicKey,
      keyAgreementPublicKeySignature: vault.keyAgreementPublicKeySignature,
      vaultSalt: vaultSalt,
      vaultKey: vaultKey,
      encryptedVault: encryptedVault,
    );
    vault = await _cloudCrypto.ensureSignedIdentity(
      vault,
      accountId: result.session.userId,
      serverOrigin: _cloudSignatureOrigin(result.session.serverUrl),
    );
    await _activateCloudSession(result.session, vault);
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
    if (vaultSecret.length < 16) {
      throw ArgumentError('Sekret vaultu musi miec minimum 16 znakow.');
    }
    final deviceId = _uuid.v4();
    final probe = CloudApiClient(serverUrl: normalizedServer);
    final loginProbe = await probe.login(
      username: username.trim().toLowerCase(),
      password: password,
      deviceId: deviceId,
      deviceName: Platform.localHostname,
      vaultKey: '',
    );
    final vaultKey = await _cloudCrypto.deriveVaultKey(
      vaultSecret: vaultSecret,
      salt: loginProbe.session.vaultSalt,
    );
    final session = CloudSession(
      serverUrl: loginProbe.session.serverUrl,
      token: loginProbe.session.token,
      userId: loginProbe.session.userId,
      username: loginProbe.session.username,
      displayName: loginProbe.session.displayName,
      deviceId: loginProbe.session.deviceId,
      vaultSalt: loginProbe.session.vaultSalt,
      vaultKey: vaultKey,
    );
    final encryptedVault = loginProbe.encryptedVault;
    if (encryptedVault == null) {
      throw StateError('Konto nie ma vaulta z kluczami.');
    }
    final vault = await _cloudCrypto.ensureSignedIdentity(
      await _cloudCrypto.decryptVault(encryptedVault, vaultKey),
      accountId: session.userId,
      serverOrigin: _cloudSignatureOrigin(session.serverUrl),
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
    await _relaySubscription?.cancel();
    await _relay?.dispose();
    await _cloudSubscription?.cancel();
    await _cloudClient?.dispose();

    _cloudSession = session;
    _cloudVault = vault;
    _cloudClient = CloudApiClient(
      serverUrl: session.serverUrl,
      token: session.token,
    );
    _identity = null;
    _relaySettings = null;
    _relay = null;
    _contacts.clear();
    _groups.clear();
    _contactInvites.clear();
    _directoryEntries.clear();
    _messages.clear();
    _sessions.clear();
    _pendingSessions.clear();
    _cloudConversations.clear();
    _cloudContactToConversation.clear();
    _cloudLastSeq.clear();
    await _loadCloudReplayStates();
    _relayConnected = false;
    await _store.saveCloudSession(session);
    await _persistMessages();
    notifyListeners();
  }

  String _normalizeCloudServerUrl(String value) =>
      normalizeCloudServerUrl(value);

  String _cloudSignatureOrigin(String serverUrl) =>
      canonicalCloudOrigin(serverUrl);

  Future<void> exportAccountPackage(String passphrase) async {
    final identity = _requireIdentity();
    final settings = _relaySettings;
    if (settings == null) {
      throw StateError('Brak ustawien relay do eksportu.');
    }
    final normalizedPassphrase = passphrase.trim();
    _validateAccountTransferPassphrase(normalizedPassphrase);

    final privateKeyBytes = await identity.keyPair.extractPrivateKeyBytes();
    final localArchiveKey = await _localArchiveKeyBase64();
    final clearJson = jsonEncode({
      'v': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'identity': {
        'userId': identity.userId,
        'privateKey': b64(privateKeyBytes),
        'publicKey': b64(identity.publicKey.bytes),
      },
      'relaySettings': settings.toJson(),
      'contacts': _contacts.map((contact) => contact.toJson()).toList(),
      'groups': _groups.map((group) => group.toJson()).toList(),
      'directoryEnabled': _directoryEnabled,
      'ownProfile': _ownProfile?.toJson(),
      'localArchiveKey': localArchiveKey,
      'messages':
          _allMessagesSnapshot().map((message) => message.toJson()).toList(),
    });

    final salt = secureRandomBytes(16);
    final nonce = secureRandomBytes(12);
    final key = await _deriveAccountExportKey(normalizedPassphrase, salt);
    final box = await _accountExportAead.encrypt(
      utf8Bytes(clearJson),
      secretKey: key,
      nonce: nonce,
      aad: utf8Bytes(_accountExportAad),
    );
    final envelope = jsonEncode({
      'v': 1,
      'type': 'secure-p2p-account-transfer',
      'algorithm': 'AES-256-GCM',
      'kdf': 'PBKDF2-HMAC-SHA256',
      'iterations': _accountExportIterations,
      'salt': b64(salt),
      'nonce': b64(box.nonce),
      'ciphertext': b64(box.cipherText),
      'mac': b64(box.mac.bytes),
    });

    await saveReceivedFile(
      fileName: 'secure-p2p-account-${identity.userId}.sp2p',
      bytes: utf8Bytes(envelope),
      mimeType: 'application/json',
    );
  }

  Future<void> importAccountPackageFromFile(String passphrase) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: true,
      type: FileType.any,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.single.bytes;
    if (bytes == null) {
      throw StateError('Nie mozna odczytac pliku konta na tej platformie.');
    }
    await importAccountPackage(bytes: bytes, passphrase: passphrase);
  }

  Future<void> importAccountPackage({
    required Uint8List bytes,
    required String passphrase,
  }) async {
    final normalizedPassphrase = passphrase.trim();
    _validateAccountTransferPassphrase(normalizedPassphrase);

    final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (envelope['type'] != 'secure-p2p-account-transfer') {
      throw const FormatException('To nie jest pakiet konta Secure Chat.');
    }
    final salt = unb64(envelope['salt'] as String);
    final key = await _deriveAccountExportKey(normalizedPassphrase, salt);
    final box = SecretBox(
      unb64(envelope['ciphertext'] as String),
      nonce: unb64(envelope['nonce'] as String),
      mac: Mac(unb64(envelope['mac'] as String)),
    );
    final clearBytes = await _accountExportAead.decrypt(
      box,
      secretKey: key,
      aad: utf8Bytes(_accountExportAad),
    );
    final clear = jsonDecode(utf8.decode(clearBytes)) as Map<String, dynamic>;
    final identityJson = (clear['identity'] as Map).cast<String, dynamic>();
    final publicKey = SimplePublicKey(
      unb64(identityJson['publicKey'] as String),
      type: KeyPairType.ed25519,
    );
    final importedIdentity = IdentityKeyMaterial(
      userId: identityJson['userId'] as String,
      deviceId: _uuid.v4(),
      keyPair: SimpleKeyPairData(
        unb64(identityJson['privateKey'] as String),
        publicKey: publicKey,
        type: KeyPairType.ed25519,
      ),
      publicKey: publicKey,
    );
    final importedRelaySettings = RelaySettings.fromJson(
      (clear['relaySettings'] as Map).cast<String, dynamic>(),
    );
    final importedContacts = ((clear['contacts'] as List?) ?? const [])
        .map((item) => Contact.fromJson((item as Map).cast<String, dynamic>()))
        .toList(growable: false);
    final importedGroups = ((clear['groups'] as List?) ?? const [])
        .map((item) =>
            GroupConversation.fromJson((item as Map).cast<String, dynamic>()))
        .toList(growable: false);
    final importedDirectoryEnabled = clear['directoryEnabled'] == true;
    final profileJson = clear['ownProfile'];
    final importedProfile = profileJson == null
        ? null
        : UserProfile.fromJson((profileJson as Map).cast<String, dynamic>());
    final importedLocalArchiveKey = clear['localArchiveKey'] as String?;
    final importedMessages = ((clear['messages'] as List?) ?? const [])
        .map((item) =>
            ChatMessage.fromJson((item as Map).cast<String, dynamic>()))
        .toList(growable: false);

    await _relaySubscription?.cancel();
    await _relay?.dispose();
    await _store.wipeLocalSecrets();
    await _messageArchive.delete();

    _identity = importedIdentity;
    _relaySettings = importedRelaySettings;
    _ownProfile = importedProfile;
    _contacts
      ..clear()
      ..addAll(importedContacts);
    _groups
      ..clear()
      ..addAll(importedGroups);
    _contactInvites.clear();
    _directoryEntries.clear();
    _directoryEnabled = importedDirectoryEnabled;
    _messages.clear();
    _sessions.clear();
    _pendingSessions.clear();
    _relayEnvelopeToMessage.clear();
    _signalEnvelopeToContact.clear();
    _relayPresence.clear();
    _pendingDeviceSyncMessages.clear();
    _deviceSyncTimer?.cancel();
    _pendingInviteHandshakeContacts.clear();
    _relayConnected = false;
    _retryingGroupInvites = false;
    _sentDeviceSyncSnapshotThisRun = false;

    await _store.saveIdentity(importedIdentity);
    if (_isValidArchiveKey(importedLocalArchiveKey)) {
      await _store.saveLocalArchiveKey(importedLocalArchiveKey!);
    }
    await _store.saveRelaySettings(importedRelaySettings);
    await _store.saveContacts(_contacts);
    await _store.saveGroups(_groups);
    await _store.saveContactInvites(_contactInvites);
    await _store.saveDirectoryEnabled(_directoryEnabled);
    if (importedProfile != null) {
      await _store.saveOwnProfile(importedProfile);
    }
    _mergeSyncedMessages(importedMessages);
    await _persistMessages();
    notifyListeners();
    await connectRelay();
    unawaited(checkForUpdate(silent: true));
  }

  Future<void> checkForUpdate({bool silent = false}) async {
    final updateServerUrl =
        _cloudSession?.serverUrl ?? _relaySettings?.serverUrl;
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
      if (fileName.isEmpty) {
        _availableUpdate = null;
        _updateStatus = 'Manifest aktualizacji nie zawiera nazwy pliku.';
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
          size: _asNullableInt(artifact['size']),
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
      final client = HttpClient();
      try {
        final request = await client.getUrl(selectedUpdate.artifact.url);
        final response = await request.close();
        if (response.statusCode != 200) {
          throw StateError('Serwer zwrocil HTTP ${response.statusCode}.');
        }

        final sink = file.openWrite();
        var received = 0;
        final total = response.contentLength;
        await for (final chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          if (total > 0) {
            _updateDownloadProgress = received / total;
            notifyListeners();
          }
        }
        await sink.close();
      } finally {
        client.close(force: true);
      }

      await _verifyDownloadedUpdate(file, selectedUpdate.artifact.sha256);
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

  Future<void> connectRelay() async {
    final identity = _identity;
    final settings = _relaySettings;
    if (identity == null || settings == null) return;

    await _relaySubscription?.cancel();
    await _relay?.disconnect();

    _relayConnected = false;
    _relayPresence.clear();
    _presenceTimer?.cancel();
    _sentDeviceSyncSnapshotThisRun = false;
    _relay = RelayClient(settings: settings, identity: identity);

    _relaySubscription = _relay!.events.listen(
      (event) => unawaited(_handleRelayEvent(event)),
    );
    await _relay!.connect();
    _setStatus('Laczenie z relay...');
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
    _relayConnected = false;
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
    _relayConnected = true;
    _setStatus('Konto polaczone.');
    notifyListeners();
  }

  Future<void> refreshCloudUsers() async {
    final client = _cloudClient;
    if (client == null || _cloudSession == null) return;
    final users = await client.users();
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
  }

  Future<void> _mergeVerifiedCloudUserIntoContact(
    Contact existing,
    CloudPublicUser peer,
  ) async {
    await _assertCloudUserKeyBundle(peer);
    if (existing.signingPublicKey?.isNotEmpty != true &&
        existing.identityPublicKey == peer.keyAgreementPublicKey) {
      final index = _contacts.indexWhere((item) => item.userId == peer.userId);
      if (index >= 0) {
        _contacts[index] = existing.copyWith(
          signingPublicKey: peer.identityPublicKey,
          keyAgreementPublicKeySignature: peer.keyAgreementPublicKeySignature,
        );
        await _store.saveContacts(_contacts);
      }
      return;
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
    final previousProof =
        IdentityRotationProof.fromOptionalJson(existing.identityRotationProof);
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
    final proof =
        IdentityRotationProof.fromOptionalJson(contact.identityRotationProof);
    if (proof == null || existing.signingPublicKey?.isNotEmpty != true) {
      return false;
    }
    if (proof.oldIdentityPublicKey != existing.signingPublicKey ||
        proof.newIdentityPublicKey != contact.signingPublicKey ||
        proof.newKeyAgreementPublicKey != contact.identityPublicKey) {
      return false;
    }
    final previousProof =
        IdentityRotationProof.fromOptionalJson(existing.identityRotationProof);
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
        _contacts.add(
          _contactFromCloudUser(peer),
        );
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
        _relayConnected = true;
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
        _relayConnected = false;
        _setStatus(event.message);
        break;
    }
  }

  Future<void> _saveCloudVault() async {
    final client = _cloudClient;
    final vault = _cloudVault;
    final session = _cloudSession;
    if (client == null || vault == null || session == null) return;
    final encryptedVault =
        await _cloudCrypto.encryptVault(vault, session.vaultKey);
    await client.saveVault(encryptedVault);
  }

  Future<void> _publishCloudKeyBundle() async {
    final client = _cloudClient;
    final vault = _cloudVault;
    if (client == null || vault == null) return;
    await client.updateKeyBundle(
      keyAgreementPublicKey: vault.keyAgreementPublicKey,
      identityPublicKey: vault.identityPublicKey,
      keyAgreementPublicKeySignature: vault.keyAgreementPublicKeySignature,
      identityRotationProof: vault.identityRotationProof?.toJson(),
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
    if (senderUserId.isNotEmpty && senderUserId != session.userId) {
      final contact = _contactById(senderUserId);
      if (contact != null &&
          (contact.identityPublicKey != senderPublicKey ||
              !_contactHasSignedIdentity(contact))) {
        throw StateError(
          'Klucz kontaktu ${contact.displayName} nie zgadza sie z zapisana, podpisana tozsamoscia. Zweryfikuj safety number przed rozmowa.',
        );
      }
    }
    final key = await _cloudCrypto.unwrapConversationKey(
      vault: vault,
      localUserId: session.userId,
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

    final decrypted = await _cloudCrypto.decryptMessage(
      conversationId: stored.conversationId,
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
    if (_hasCloudMessage(stored.conversationId, decrypted.messageId)) {
      final senderDeviceId = decrypted.senderDeviceId.isNotEmpty
          ? decrypted.senderDeviceId
          : stored.senderDeviceId;
      final existingReplayState = _cloudReplayStateFor(
        conversationId: stored.conversationId,
        senderUserId: stored.senderUserId,
        senderDeviceId: senderDeviceId,
      );
      if (decrypted.messageCounter != null &&
          (existingReplayState == null ||
              decrypted.messageCounter! > existingReplayState.lastCounter)) {
        await _acceptCloudMessageReplayState(
          conversationId: stored.conversationId,
          senderUserId: stored.senderUserId,
          senderDeviceId: senderDeviceId,
          messageCounter: decrypted.messageCounter,
          previousMessageHash: decrypted.previousMessageHash,
          messageHash: decrypted.messageHash,
        );
      }
      final currentSeq = _cloudLastSeq[stored.conversationId] ?? 0;
      if (stored.seq > currentSeq) {
        _cloudLastSeq[stored.conversationId] = stored.seq;
      }
      return;
    }
    await _acceptCloudMessageReplayState(
      conversationId: stored.conversationId,
      senderUserId: stored.senderUserId,
      senderDeviceId: decrypted.senderDeviceId.isNotEmpty
          ? decrypted.senderDeviceId
          : stored.senderDeviceId,
      messageCounter: decrypted.messageCounter,
      previousMessageHash: decrypted.previousMessageHash,
      messageHash: decrypted.messageHash,
    );
    final direction = stored.senderUserId == session.userId
        ? MessageDirection.outbound
        : MessageDirection.inbound;
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
    if (notify) notifyListeners();
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
    final conversation = _cloudConversations[conversationId];
    if (conversation == null) {
      throw StateError('Brak rozmowy cloud.');
    }
    final key = await _ensureCloudConversationKey(conversation);
    if (key == null) {
      throw StateError('Brak klucza rozmowy cloud.');
    }
    final streamState = _cloudReplayStateFor(
      conversationId: conversationId,
      senderUserId: session.userId,
      senderDeviceId: session.deviceId,
    );
    final messageCounter = (streamState?.lastCounter ?? 0) + 1;
    final previousMessageHash = streamState?.lastMessageHash ?? '';
    final encrypted = await _cloudCrypto.encryptMessage(
      conversationId: conversationId,
      senderUserId: session.userId,
      senderDeviceId: session.deviceId,
      messageCounter: messageCounter,
      previousMessageHash: previousMessageHash,
      conversationKey: key,
      payload: payload,
    );
    final messageId = requiredString(encrypted, 'messageId');
    _addMessage(
      ChatMessage(
        id: messageId,
        contactId: contact.userId,
        direction: MessageDirection.outbound,
        payload: payload,
        createdAt: DateTime.parse(
          requiredString(asStringKeyMap(encrypted['aad'], 'aad'), 'createdAt'),
        ),
        status: MessageStatus.pending,
        senderId: session.userId,
        transport: 'cloud',
      ),
    );
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
    );
    _updateMessage(
      contact.userId,
      messageId,
      MessageStatus.sent,
      transport: 'cloud',
    );
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
        avatarMimeType: existing?.avatarMimeType ?? contact.avatarMimeType,
        avatarBytesBase64:
            existing?.avatarBytesBase64 ?? contact.avatarBytesBase64,
        profileUpdatedAt:
            existing?.profileUpdatedAt ?? contact.profileUpdatedAt,
      ),
    );
    _contacts.sort((a, b) => a.displayName.compareTo(b.displayName));
    _contactInvites.removeWhere((item) => item.userId == contact.userId);
    _directoryEntries.removeWhere((item) => item.userId == contact.userId);
    await _store.saveContacts(_contacts);
    await _store.saveContactInvites(_contactInvites);
    if (_relayConnected) _relay?.queryProfiles([contact.userId]);
    notifyListeners();
  }

  Future<void> startCloudConversation(CloudPublicUser user) async {
    await _assertCloudUserKeyBundle(user);
    await _startCloudDirectContact(
      _contactFromCloudUser(user),
    );
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
      final index =
          _contacts.indexWhere((item) => item.userId == contact.userId);
      if (index >= 0) {
        _contacts[index] = existing.copyWith(
          signingPublicKey: contact.signingPublicKey,
          keyAgreementPublicKeySignature:
              contact.keyAgreementPublicKeySignature,
          identityRotationProof: contact.identityRotationProof,
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
    final memberKeys = <String, dynamic>{
      session.userId: await _cloudCrypto.wrapConversationKey(
        vault: vault,
        senderUserId: session.userId,
        recipientUserId: session.userId,
        recipientPublicKey: vault.keyAgreementPublicKey,
        conversationKey: conversationKey,
      ),
      contact.userId: await _cloudCrypto.wrapConversationKey(
        vault: vault,
        senderUserId: session.userId,
        recipientUserId: contact.userId,
        recipientPublicKey: contact.identityPublicKey,
        conversationKey: conversationKey,
      ),
    };
    final conversation = await client.createDirectConversation(
      peerUserId: contact.userId,
      memberKeys: memberKeys,
    );
    await _rememberCloudConversation(conversation);
    notifyListeners();
  }

  Future<void> setDirectoryEnabled(bool enabled) async {
    _directoryEnabled = enabled;
    await _store.saveDirectoryEnabled(enabled);
    _syncDirectoryVisibility();
    if (enabled) {
      refreshDirectory();
    } else {
      _directoryEntries.clear();
      _directoryStatus = 'Ukryto z globalnej listy uzytkownikow.';
      notifyListeners();
    }
  }

  void refreshDirectory() {
    final relay = _relay;
    if (!_relayConnected || relay == null) {
      _directoryStatus = 'Najpierw polacz sie z relay.';
      notifyListeners();
      return;
    }
    _loadingDirectory = true;
    _directoryStatus = 'Odswiezam globalna liste...';
    notifyListeners();
    relay.queryDirectory();
  }

  Future<void> sendContactInvite(DirectoryEntry entry) async {
    final identity = _requireIdentity();
    final relay = _requireRelay();
    if (!_relayConnected) {
      throw StateError('Najpierw polacz sie z relay.');
    }
    if (entry.userId == identity.userId) {
      throw StateError('To jest Twoje konto.');
    }

    await addContact(
      Contact(
        userId: entry.userId,
        displayName: entry.displayName,
        identityPublicKey: entry.identityPublicKey,
      ),
    );
    relay.sendContactRequest(
      to: entry.userId,
      displayName: identity.userId,
    );
    _directoryStatus =
        'Wyslano zaproszenie do ${entry.displayName}. Jesli jest offline, poczeka na serwerze.';
    notifyListeners();
  }

  Future<void> acceptContactInvite(ContactInvite invite) async {
    await addContact(
      Contact(
        userId: invite.userId,
        displayName: invite.displayName,
        identityPublicKey: invite.identityPublicKey,
      ),
    );
    _contactInvites.removeWhere((item) => item.requestId == invite.requestId);
    await _store.saveContactInvites(_contactInvites);
    _setStatus('Dodano kontakt ${invite.displayName}.');
    notifyListeners();
  }

  Future<void> rejectContactInvite(ContactInvite invite) async {
    _contactInvites.removeWhere((item) => item.requestId == invite.requestId);
    await _store.saveContactInvites(_contactInvites);
    notifyListeners();
  }

  Future<void> removeContact(Contact contact) async {
    final removed = _contacts.any((item) => item.userId == contact.userId);
    _contacts.removeWhere((item) => item.userId == contact.userId);
    _contactInvites.removeWhere((item) => item.userId == contact.userId);
    _directoryEntries.removeWhere((item) => item.userId == contact.userId);
    _sessions.remove(contact.userId);
    _pendingSessions.remove(contact.userId);
    _relayEnvelopeToMessage.removeWhere((_, to) => to == contact.userId);
    _signalEnvelopeToContact.removeWhere((_, to) => to == contact.userId);
    _relayPresence.remove(contact.userId);
    _pendingInviteHandshakeContacts.remove(contact.userId);
    _messages.remove(contact.userId);

    if (!removed) return;
    await _store.saveContacts(_contacts);
    await _store.saveContactInvites(_contactInvites);
    await _saveSessions();
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
          'Profilowe jest za duze. Limit: ${maxProfileImageBytes ~/ 1024} KB.');
    }

    final mimeType = _guessMimeType(file.name);
    if (mimeType == null || !mimeType.startsWith('image/')) {
      throw StateError(
          'Profilowe musi byc obrazem JPG, PNG, GIF, WEBP albo BMP.');
    }

    _ownProfile = UserProfile(
      avatarMimeType: mimeType,
      avatarBytesBase64: b64(bytes),
      updatedAt: DateTime.now().toUtc(),
    );
    await _store.saveOwnProfile(_ownProfile!);
    if (_relayConnected) _relay?.updateProfile(_ownProfile!);
    notifyListeners();
  }

  Future<void> clearProfileImage() async {
    _ownProfile = UserProfile(updatedAt: DateTime.now().toUtc());
    await _store.saveOwnProfile(_ownProfile!);
    if (_relayConnected) _relay?.updateProfile(_ownProfile!);
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

  Future<GroupConversation> createGroup({
    required String name,
    required List<Contact> members,
  }) async {
    final identity = _requireIdentity();
    final groupName = name.trim().isEmpty ? 'Nowa grupa' : name.trim();
    final selectedMembers = members
        .where((contact) => contact.userId != identity.userId)
        .fold<Map<String, Contact>>({}, (map, contact) {
          map[contact.userId] = contact;
          return map;
        })
        .values
        .toList(growable: false);

    if (selectedMembers.isEmpty) {
      throw ArgumentError('Wybierz przynajmniej jednego kontaktu.');
    }

    final memberIds = <String>{
      identity.userId,
      for (final member in selectedMembers) member.userId,
    }.toList(growable: false);
    final group = GroupConversation(
      groupId: _uuid.v4(),
      name: groupName,
      memberIds: memberIds,
      acceptedMemberIds: [identity.userId],
      createdAt: DateTime.now().toUtc(),
    );

    _groups.add(group);
    await _store.saveGroups(_groups);
    _addSystemMessage(
      group.groupId,
      'Utworzono grupe "$groupName". Zaproszenia beda wysylane automatycznie.',
    );
    notifyListeners();

    var sentInvites = 0;
    for (final member in selectedMembers) {
      if (await _trySendGroupInvite(group.groupId, member.userId)) {
        sentInvites += 1;
      }
    }
    final waiting = selectedMembers.length - sentInvites;
    if (waiting > 0) {
      _addSystemMessage(
        group.groupId,
        'Zaproszenia dla $waiting osob czekaja na wyslanie.',
      );
    }

    return group;
  }

  Future<void> inviteContactsToGroup({
    required GroupConversation group,
    required List<Contact> contacts,
  }) async {
    final identity = _requireIdentity();
    if (group.pendingInvite || !group.isAcceptedBy(identity.userId)) {
      throw StateError('Nie mozesz zapraszac do niezaakceptowanej grupy.');
    }

    final selected = contacts
        .where((contact) =>
            contact.userId != identity.userId &&
            !group.memberIds.contains(contact.userId))
        .fold<Map<String, Contact>>({}, (map, contact) {
          map[contact.userId] = contact;
          return map;
        })
        .values
        .toList(growable: false);

    if (selected.isEmpty) {
      throw ArgumentError('Wybierz przynajmniej jeden nowy kontakt.');
    }

    final index = _groups.indexWhere((item) => item.groupId == group.groupId);
    if (index < 0) return;

    final updatedMemberIds = <String>{
      ..._groups[index].memberIds,
      for (final contact in selected) contact.userId,
    }.toList(growable: false);
    _groups[index] = _groups[index].copyWith(memberIds: updatedMemberIds);
    await _store.saveGroups(_groups);
    _addSystemMessage(
      group.groupId,
      'Dodano ${selected.length} osob do zaproszen grupy.',
    );

    for (final contact in selected) {
      await _trySendGroupInvite(group.groupId, contact.userId);
    }
    await _broadcastGroupRoster(_groups[index]);
    notifyListeners();
  }

  Future<void> respondToGroupInvite(
    GroupConversation group,
    bool accepted,
  ) async {
    final identity = _requireIdentity();
    final inviterId = group.invitedBy;
    if (inviterId == null) return;
    final inviter = _contactById(inviterId);
    if (inviter == null) {
      throw StateError('Nie znaleziono kontaktu, ktory zaprosil do grupy.');
    }

    await _sendHiddenPayload(
      inviter,
      PlainPayload.groupInviteResponse(
        groupId: group.groupId,
        groupAccepted: accepted,
      ),
    );

    final index = _groups.indexWhere((item) => item.groupId == group.groupId);
    if (index < 0) return;
    if (!accepted) {
      _groups.removeAt(index);
      _messages.remove(group.groupId);
      await _store.saveGroups(_groups);
      await _persistMessages();
      notifyListeners();
      return;
    }

    final acceptedIds = <String>{
      ..._groups[index].acceptedMemberIds,
      identity.userId,
    }.toList(growable: false);
    _groups[index] = _groups[index].copyWith(
      acceptedMemberIds: acceptedIds,
      pendingInvite: false,
    );
    await _store.saveGroups(_groups);
    _addSystemMessage(group.groupId, 'Dolaczyles do grupy.');
    notifyListeners();
  }

  Future<void> sendGroupText(
    GroupConversation group,
    String text, {
    String? replyToMessageId,
    String? replyPreview,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _sendGroupVisiblePayload(
      group,
      visiblePayload: PlainPayload.text(
        trimmed,
        replyToMessageId: replyToMessageId,
        replyPreview: replyPreview,
      ),
      wirePayload: (messageId) => PlainPayload.groupText(
        groupId: group.groupId,
        groupMessageId: messageId,
        text: trimmed,
        replyToMessageId: replyToMessageId,
        replyPreview: replyPreview,
      ),
    );
  }

  Future<void> sendGroupFile(
    GroupConversation group, {
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
    await sendGroupFileBytes(
      group,
      fileName: file.name,
      bytes: bytes,
      mimeType: _guessMimeType(file.name),
      replyToMessageId: replyToMessageId,
      replyPreview: replyPreview,
    );
  }

  Future<void> sendGroupFileBytes(
    GroupConversation group, {
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
    String? replyToMessageId,
    String? replyPreview,
  }) async {
    final relayAwareLimit = (_relayMaxPayloadBytes * 0.45).floor();
    final effectiveLimit = relayAwareLimit < maxPlainFileBytes
        ? relayAwareLimit
        : maxPlainFileBytes;
    if (bytes.length > effectiveLimit) {
      throw StateError(
          'Plik jest za duzy. Limit: ${effectiveLimit ~/ (1024 * 1024)} MB.');
    }

    final payload = PlainPayload.file(
      fileName: fileName,
      mimeType: mimeType ?? _guessMimeType(fileName),
      fileSize: bytes.length,
      fileBytesBase64: b64(bytes),
      replyToMessageId: replyToMessageId,
      replyPreview: replyPreview,
    );
    await _sendGroupVisiblePayload(
      group,
      visiblePayload: payload,
      wirePayload: (messageId) => PlainPayload.file(
        fileName: fileName,
        mimeType: mimeType ?? _guessMimeType(fileName),
        fileSize: bytes.length,
        fileBytesBase64: b64(bytes),
        groupId: group.groupId,
        groupMessageId: messageId,
        replyToMessageId: replyToMessageId,
        replyPreview: replyPreview,
      ),
    );
  }

  Future<void> _sendGroupVisiblePayload(
    GroupConversation group, {
    required PlainPayload visiblePayload,
    required PlainPayload Function(String messageId) wirePayload,
  }) async {
    final identity = _requireIdentity();
    final currentGroup = _groupById(group.groupId) ?? group;
    if (currentGroup.pendingInvite ||
        !currentGroup.isAcceptedBy(identity.userId)) {
      throw StateError('Najpierw zaakceptuj zaproszenie do grupy.');
    }

    final messageId = _uuid.v4();
    _addMessage(
      ChatMessage(
        id: messageId,
        contactId: currentGroup.groupId,
        direction: MessageDirection.outbound,
        payload: visiblePayload,
        createdAt: DateTime.now().toUtc(),
        status: MessageStatus.pending,
        senderId: identity.userId,
      ),
    );

    var sent = 0;
    final recipientIds = currentGroup.acceptedMemberIds
        .where((userId) => userId != identity.userId)
        .toList(growable: false);
    for (final userId in recipientIds) {
      final contact = _contactById(userId);
      if (contact == null) continue;
      await _sendHiddenPayload(contact, wirePayload(messageId));
      sent += 1;
    }

    _updateMessage(
      currentGroup.groupId,
      messageId,
      sent > 0 || recipientIds.isEmpty
          ? MessageStatus.sent
          : MessageStatus.failed,
      transport: 'group',
      error: sent > 0 || recipientIds.isEmpty
          ? null
          : 'Brak zaakceptowanych odbiorcow.',
    );
  }

  Future<void> markGroupRead(GroupConversation group) async {
    final list = _messages[group.groupId];
    if (list == null) return;

    var changed = false;
    final changedMessages = <ChatMessage>[];
    for (var index = 0; index < list.length; index += 1) {
      final message = list[index];
      if (!_isUnreadIncomingMessage(message)) continue;
      list[index] = message.copyWith(status: MessageStatus.read);
      changedMessages.add(list[index]);
      changed = true;
    }
    if (!changed) return;
    await _persistMessages();
    _scheduleDeviceSyncForMany(changedMessages);
    notifyListeners();
  }

  Future<void> leaveGroup(GroupConversation group) async {
    final identity = _requireIdentity();
    if (group.pendingInvite) {
      await respondToGroupInvite(group, false);
      return;
    }

    final recipients = group.memberIds
        .where((userId) => userId != identity.userId)
        .toList(growable: false);
    for (final userId in recipients) {
      final contact = _contactById(userId);
      if (contact == null) continue;
      try {
        await _sendHiddenPayload(
          contact,
          PlainPayload.groupLeave(groupId: group.groupId),
        );
      } catch (_) {
        // Wyjscie z grupy ma zadzialac lokalnie nawet gdy czesc osob jest offline.
      }
    }
    await deleteGroupLocally(group);
  }

  Future<void> deleteGroupLocally(GroupConversation group) async {
    _groups.removeWhere((item) => item.groupId == group.groupId);
    _messages.remove(group.groupId);
    await _store.saveGroups(_groups);
    await _persistMessages();
    notifyListeners();
  }

  Future<void> markConversationRead(Contact contact) async {
    final list = _messages[contact.userId];
    if (list == null) return;

    final readMessageIds = <String>[];
    final changedMessages = <ChatMessage>[];
    var changed = false;
    for (var index = 0; index < list.length; index += 1) {
      final message = list[index];
      if (!_isUnreadIncomingMessage(message)) continue;

      list[index] = message.copyWith(status: MessageStatus.read);
      changedMessages.add(list[index]);
      readMessageIds.add(message.id);
      changed = true;
    }

    if (!changed) return;
    await _persistMessages();
    _scheduleDeviceSyncForMany(changedMessages);
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
          'Ta wiadomosc nie zostala wyslana. Usun ja lokalnie albo wyslij ponownie.');
    }

    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Edytowana wiadomosc nie moze byc pusta.');
    }
    if (trimmed == (message.payload.text ?? '').trim()) return;

    final identity = _requireIdentity();
    final session = await _ensureSession(contact);
    final packet = await _crypto.encryptPayload(
      session: session,
      from: identity.userId,
      to: contact.userId,
      payload: PlainPayload.edit(
        targetMessageId: message.id,
        editedText: trimmed,
      ),
    );
    await _sendEncryptedPacket(contact, packet);
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
          'Ta wiadomosc nie zostala dostarczona. Usun ja lokalnie.');
    }

    final identity = _requireIdentity();
    final session = await _ensureSession(contact);
    final packet = await _crypto.encryptPayload(
      session: session,
      from: identity.userId,
      to: contact.userId,
      payload: PlainPayload.retraction(targetMessageId: message.id),
    );
    await _sendEncryptedPacket(contact, packet);
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

    final identity = _requireIdentity();
    final normalizedEmoji = emoji?.trim();
    final session = await _ensureSession(contact);
    final packet = await _crypto.encryptPayload(
      session: session,
      from: identity.userId,
      to: contact.userId,
      payload: PlainPayload.reaction(
        targetMessageId: message.id,
        reactionEmoji: normalizedEmoji == null || normalizedEmoji.isEmpty
            ? null
            : normalizedEmoji,
      ),
    );
    await _sendEncryptedPacket(contact, packet);
    _applyReaction(
      contact.userId,
      message.id,
      identity.userId,
      normalizedEmoji,
    );
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

    final identity = _requireIdentity();
    final session = await _ensureSession(contact);
    final packet = await _crypto.encryptPayload(
      session: session,
      from: identity.userId,
      to: contact.userId,
      payload: PlainPayload.pin(
        targetMessageId: message.id,
        pinPinned: pinned,
      ),
    );
    await _sendEncryptedPacket(contact, packet);
    _applyPin(contact.userId, message.id, pinned);
  }

  Future<void> editGroupMessage(
    GroupConversation group,
    ChatMessage message,
    String text,
  ) async {
    final identity = _requireIdentity();
    if (message.contactId != group.groupId) {
      throw ArgumentError('Wiadomosc nie nalezy do tej grupy.');
    }
    if (message.direction != MessageDirection.outbound ||
        message.senderId != identity.userId) {
      throw StateError('Mozesz edytowac tylko wlasne wiadomosci.');
    }
    if (message.retracted || message.payload.type != PlainPayloadType.text) {
      throw StateError('Tej wiadomosci nie mozna edytowac.');
    }
    if (message.status == MessageStatus.failed) {
      throw StateError(
          'Ta wiadomosc nie zostala wyslana. Usun ja lokalnie albo wyslij ponownie.');
    }

    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Edytowana wiadomosc nie moze byc pusta.');
    }
    if (trimmed == (message.payload.text ?? '').trim()) return;

    await _sendGroupControlPayload(
      group,
      PlainPayload.edit(
        targetMessageId: message.id,
        editedText: trimmed,
        groupId: group.groupId,
      ),
    );
    _applyGroupEdit(group.groupId, message.id, trimmed, identity.userId);
  }

  Future<void> retractGroupMessage(
    GroupConversation group,
    ChatMessage message,
  ) async {
    final identity = _requireIdentity();
    if (message.contactId != group.groupId) {
      throw ArgumentError('Wiadomosc nie nalezy do tej grupy.');
    }
    if (message.direction != MessageDirection.outbound ||
        message.senderId != identity.userId) {
      throw StateError('Mozesz cofnac tylko wlasna wyslana wiadomosc.');
    }
    if (message.retracted) return;
    if (message.status == MessageStatus.failed) {
      throw StateError(
          'Ta wiadomosc nie zostala dostarczona. Usun ja lokalnie.');
    }

    await _sendGroupControlPayload(
      group,
      PlainPayload.retraction(
        targetMessageId: message.id,
        groupId: group.groupId,
      ),
    );
    _markGroupMessageRetracted(group.groupId, message.id, identity.userId);
  }

  Future<void> reactToGroupMessage(
    GroupConversation group,
    ChatMessage message,
    String? emoji,
  ) async {
    final identity = _requireIdentity();
    if (message.contactId != group.groupId) {
      throw ArgumentError('Wiadomosc nie nalezy do tej grupy.');
    }
    if (message.direction == MessageDirection.system || message.retracted) {
      throw StateError('Nie mozna zareagowac na te wiadomosc.');
    }

    final normalizedEmoji = emoji?.trim();
    await _sendGroupControlPayload(
      group,
      PlainPayload.reaction(
        targetMessageId: message.id,
        reactionEmoji: normalizedEmoji == null || normalizedEmoji.isEmpty
            ? null
            : normalizedEmoji,
        groupId: group.groupId,
      ),
    );
    _applyReaction(
      group.groupId,
      message.id,
      identity.userId,
      normalizedEmoji,
    );
  }

  Future<void> setGroupMessagePinned(
    GroupConversation group,
    ChatMessage message,
    bool pinned,
  ) async {
    if (message.contactId != group.groupId) {
      throw ArgumentError('Wiadomosc nie nalezy do tej grupy.');
    }
    if (message.direction == MessageDirection.system || message.retracted) {
      return;
    }

    await _sendGroupControlPayload(
      group,
      PlainPayload.pin(
        targetMessageId: message.id,
        pinPinned: pinned,
        groupId: group.groupId,
      ),
    );
    _applyPin(group.groupId, message.id, pinned);
  }

  Future<void> _sendGroupControlPayload(
    GroupConversation group,
    PlainPayload payload,
  ) async {
    final identity = _requireIdentity();
    final currentGroup = _groupById(group.groupId) ?? group;
    if (currentGroup.pendingInvite ||
        !currentGroup.isAcceptedBy(identity.userId)) {
      throw StateError('Najpierw zaakceptuj zaproszenie do grupy.');
    }

    for (final userId in currentGroup.acceptedMemberIds) {
      if (userId == identity.userId) continue;
      final contact = _contactById(userId);
      if (contact == null) continue;
      await _sendHiddenPayload(contact, payload);
    }
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
    final relayAwareLimit = (_relayMaxPayloadBytes * 0.45).floor();
    final effectiveLimit = relayAwareLimit < maxPlainFileBytes
        ? relayAwareLimit
        : maxPlainFileBytes;
    if (bytes.length > effectiveLimit) {
      throw StateError(
          'Plik jest za duzy. Limit: ${effectiveLimit ~/ (1024 * 1024)} MB.');
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
    await _relaySubscription?.cancel();
    await _relay?.dispose();
    await _cloudSubscription?.cancel();
    await _cloudClient?.dispose();
    await _store.wipeLocalSecrets();
    _identity = null;
    _cloudSession = null;
    _cloudVault = null;
    _cloudClient = null;
    _ownProfile = null;
    _relaySettings = null;
    _relay = null;
    _contacts.clear();
    _contactInvites.clear();
    _groups.clear();
    _directoryEntries.clear();
    _messages.clear();
    _sessions.clear();
    _pendingSessions.clear();
    _relayEnvelopeToMessage.clear();
    _signalEnvelopeToContact.clear();
    _relayPresence.clear();
    _pendingDeviceSyncMessages.clear();
    _cloudConversations.clear();
    _cloudContactToConversation.clear();
    _cloudLastSeq.clear();
    _cloudReplayStates.clear();
    _cloudUsers.clear();
    _deviceSyncTimer?.cancel();
    _pendingInviteHandshakeContacts.clear();
    _presenceTimer?.cancel();
    _relayConnected = false;
    _retryingGroupInvites = false;
    _sentDeviceSyncSnapshotThisRun = false;
    _directoryEnabled = false;
    _loadingDirectory = false;
    _directoryStatus = null;
    await _messageArchive.delete();
    _setStatus('Wyczyszczono lokalne dane.');
  }

  Future<void> _sendPlainPayload(Contact contact, PlainPayload payload) async {
    if (cloudMode) {
      await _sendCloudPayload(contact, payload);
      return;
    }
    final identity = _requireIdentity();
    final session = await _ensureSession(contact);
    final packet = await _crypto.encryptPayload(
      session: session,
      from: identity.userId,
      to: contact.userId,
      payload: payload,
    );

    _addMessage(
      ChatMessage(
        id: packet.messageId,
        contactId: contact.userId,
        direction: MessageDirection.outbound,
        payload: payload,
        createdAt: DateTime.now().toUtc(),
        status: MessageStatus.pending,
      ),
    );

    await _sendEncryptedPacket(contact, packet,
        visibleMessageId: packet.messageId);
  }

  Future<void> _sendEncryptedPacket(
    Contact contact,
    EncryptedPacket packet, {
    String? visibleMessageId,
  }) async {
    final relay = _requireRelay();
    final relayEnvelopeId = relay.sendRelay(
      to: contact.userId,
      payload: packet.toJson(),
    );
    if (visibleMessageId != null) {
      _relayEnvelopeToMessage[relayEnvelopeId] = visibleMessageId;
    }
  }

  Future<void> _sendReceipt(
    Contact contact,
    String messageId,
    ReceiptKind kind,
  ) async {
    await _sendControlPayload(
      contact,
      PlainPayload.receipt(
        targetMessageId: messageId,
        receiptKind: kind,
      ),
    );
  }

  Future<void> _sendHiddenPayload(
    Contact contact,
    PlainPayload payload,
  ) async {
    final identity = _requireIdentity();
    final session = await _ensureSession(contact);
    final packet = await _crypto.encryptPayload(
      session: session,
      from: identity.userId,
      to: contact.userId,
      payload: payload,
    );
    await _sendEncryptedPacket(contact, packet);
  }

  Future<void> _retryPendingGroupInvites() async {
    final identity = _identity;
    if (identity == null || !_relayConnected) return;
    if (_retryingGroupInvites) return;
    _retryingGroupInvites = true;

    try {
      for (final group in List<GroupConversation>.of(_groups)) {
        if (group.pendingInvite || !group.isAcceptedBy(identity.userId)) {
          continue;
        }
        final pendingMemberIds = group.memberIds.where((userId) {
          return userId != identity.userId &&
              !group.acceptedMemberIds.contains(userId) &&
              !group.invitedMemberIds.contains(userId);
        }).toList(growable: false);

        for (final memberId in pendingMemberIds) {
          await _trySendGroupInvite(group.groupId, memberId);
        }
      }
    } finally {
      _retryingGroupInvites = false;
    }
  }

  Future<bool> _trySendGroupInvite(String groupId, String memberId) async {
    final group = _groupById(groupId);
    final contact = _contactById(memberId);
    final identity = _identity;
    if (group == null || contact == null || identity == null) return false;
    if (group.invitedMemberIds.contains(memberId) ||
        group.acceptedMemberIds.contains(memberId) ||
        memberId == identity.userId) {
      return true;
    }

    if (!_sessions.containsKey(memberId)) {
      if (!isContactOnline(memberId)) {
        _beginSessionForPendingInvite(contact);
        return false;
      }
      try {
        await _ensureSession(contact);
      } catch (_) {
        return false;
      }
    }

    try {
      await _sendHiddenPayload(
        contact,
        PlainPayload.groupInvite(
          groupId: group.groupId,
          groupName: group.name,
          groupMemberIds: group.memberIds,
          groupAcceptedMemberIds: group.acceptedMemberIds,
          groupMemberInfos: _groupMemberInfos(group),
        ),
      );
      _markGroupInviteSent(groupId, memberId);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _broadcastAcceptedGroupRosters() async {
    final identity = _identity;
    if (identity == null || !_relayConnected) return;
    for (final group in List<GroupConversation>.of(_groups)) {
      if (group.pendingInvite || !group.isAcceptedBy(identity.userId)) {
        continue;
      }
      await _broadcastGroupRoster(group);
    }
  }

  Future<void> _broadcastGroupRoster(
    GroupConversation group, {
    String? exceptUserId,
  }) async {
    final identity = _identity;
    if (identity == null) return;
    final payload = PlainPayload.groupInvite(
      groupId: group.groupId,
      groupName: group.name,
      groupMemberIds: group.memberIds,
      groupAcceptedMemberIds: group.acceptedMemberIds,
      groupMemberInfos: _groupMemberInfos(group),
    );

    for (final userId in group.acceptedMemberIds) {
      if (userId == identity.userId || userId == exceptUserId) continue;
      final contact = _contactById(userId);
      if (contact == null) continue;
      try {
        await _sendHiddenPayload(contact, payload);
      } catch (_) {
        // Aktualna lista grupy zostanie ponowiona przy kolejnym polaczeniu.
      }
    }
  }

  List<GroupMemberInfo> _groupMemberInfos(GroupConversation group) {
    final identity = _identity;
    final result = <String, GroupMemberInfo>{};
    if (identity != null && group.memberIds.contains(identity.userId)) {
      result[identity.userId] = GroupMemberInfo(
        userId: identity.userId,
        displayName: identity.userId,
        identityPublicKey: b64(identity.publicKey.bytes),
      );
    }

    for (final userId in group.memberIds) {
      final contact = _contactById(userId);
      if (contact == null) continue;
      result[userId] = GroupMemberInfo(
        userId: contact.userId,
        displayName: contact.displayName,
        identityPublicKey: contact.identityPublicKey,
      );
    }
    return result.values.toList(growable: false);
  }

  Future<void> _mergeGroupMemberInfos(
    Iterable<GroupMemberInfo> memberInfos,
  ) async {
    final identity = _identity;
    var changed = false;

    for (final info in memberInfos) {
      if (info.userId.isEmpty || info.identityPublicKey.isEmpty) continue;
      if (identity != null && info.userId == identity.userId) continue;
      final existing = _contactById(info.userId);
      if (existing != null) {
        // Nie nadpisujemy istniejacego klucza publicznego, zeby nie robic
        // cichej podmiany tozsamosci przez zaproszenie grupowe.
        continue;
      }

      _contacts.add(
        Contact(
          userId: info.userId,
          displayName:
              info.displayName.trim().isEmpty ? info.userId : info.displayName,
          identityPublicKey: info.identityPublicKey,
        ),
      );
      changed = true;
    }

    if (!changed) return;
    _contacts.sort((a, b) => a.displayName.compareTo(b.displayName));
    await _store.saveContacts(_contacts);
    if (_relayConnected) {
      _relay
          ?.queryProfiles(_contacts.map((contact) => contact.userId).toList());
    }
  }

  void _beginSessionForPendingInvite(Contact contact) {
    if (_sessions.containsKey(contact.userId) ||
        _pendingSessions.containsKey(contact.userId) ||
        _pendingInviteHandshakeContacts.contains(contact.userId)) {
      return;
    }
    _pendingInviteHandshakeContacts.add(contact.userId);

    unawaited(
      _ensureSession(contact).then((_) {
        _pendingInviteHandshakeContacts.remove(contact.userId);
        unawaited(_retryPendingGroupInvites());
      }).catchError((_) {
        // Zaproszenie pozostaje oczekujace i zostanie ponowione przy obecnosci.
      }),
    );
  }

  void _markGroupInviteSent(String groupId, String memberId) {
    final index = _groups.indexWhere((group) => group.groupId == groupId);
    if (index < 0) return;
    final group = _groups[index];
    if (group.invitedMemberIds.contains(memberId)) return;

    _groups[index] = group.copyWith(
      invitedMemberIds: <String>{
        ...group.invitedMemberIds,
        memberId,
      }.toList(growable: false),
    );
    unawaited(_store.saveGroups(_groups));
    notifyListeners();
  }

  Future<void> _sendControlPayload(
    Contact contact,
    PlainPayload payload,
  ) async {
    final identity = _identity;
    final session = _sessions[contact.userId];
    if (identity == null || session == null || _relay == null) return;
    if (!_relayConnected) return;

    try {
      final packet = await _crypto.encryptPayload(
        session: session,
        from: identity.userId,
        to: contact.userId,
        payload: payload,
      );
      await _sendEncryptedPacket(contact, packet);
    } catch (_) {
      // Potwierdzenia i edycje sterujace nie moga blokowac odbioru wiadomosci.
    }
  }

  Future<SessionState> _ensureSession(Contact contact) async {
    final existing = _sessions[contact.userId];
    if (existing != null) return existing;

    final pending = _pendingSessions[contact.userId];
    if (pending != null) {
      return pending.completer.future.timeout(const Duration(seconds: 20));
    }

    final identity = _requireIdentity();
    final relay = _requireRelay();
    final init =
        await _crypto.createHandshakeInit(identity: identity, contact: contact);
    _pendingSessions[contact.userId] = init.pendingSession;
    final signalId = relay.sendSignal(
      to: contact.userId,
      signalType: 'crypto-handshake-init',
      payload: init.wirePayload,
    );
    _signalEnvelopeToContact[signalId] = contact.userId;
    _addSystemMessage(contact.userId, 'Rozpoczeto nowa sesje E2EE.');

    return init.pendingSession.completer.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _pendingSessions.remove(contact.userId);
        throw TimeoutException('Kontakt nie odpowiedzial na handshake E2EE.');
      },
    );
  }

  Future<void> _handleRelayEvent(RelayEvent event) async {
    switch (event) {
      case RelayReady():
        _relayConnected = true;
        _relayMaxPayloadBytes = event.maxPayloadBytes;
        _setStatus('Relay polaczony.');
        _relay?.updateProfile(
            _ownProfile ?? UserProfile(updatedAt: DateTime.now().toUtc()));
        final contactIds = _contacts.map((contact) => contact.userId).toList();
        _relay?.queryPresence(contactIds);
        _relay?.queryProfiles(contactIds);
        _syncDirectoryVisibility();
        _relay?.queryDirectory();
        _startPresencePolling();
        unawaited(_retryPendingGroupInvites());
        unawaited(_broadcastAcceptedGroupRosters());
        unawaited(_flushDeviceSyncMessages());
        if (!_sentDeviceSyncSnapshotThisRun) {
          _sentDeviceSyncSnapshotThisRun = true;
          unawaited(_broadcastDeviceSyncSnapshot());
        }
        break;
      case RelayDeliver():
        if (event.kind == 'signal') {
          await _handleSignal(event);
        } else if (event.kind == 'relay') {
          if (event.from == _identity?.userId &&
              _isDeviceSyncPayload(event.payload)) {
            await _handleDeviceSyncPayload(event.payload);
          } else {
            await _handleEncryptedPacket(event.from, event.payload,
                transport: 'relay');
          }
        }
        break;
      case RelaySent():
        final messageId = _relayEnvelopeToMessage.remove(event.id);
        if (messageId != null) {
          final accepted = event.deliveredConnections > 0 || event.queued;
          _updateMessage(
            event.to,
            messageId,
            accepted ? MessageStatus.sent : MessageStatus.failed,
            transport: event.queued ? 'relay queued' : 'relay',
            error: accepted ? null : 'Kontakt offline.',
          );
        }
        final signalContactId = _signalEnvelopeToContact.remove(event.id);
        if (signalContactId != null &&
            event.deliveredConnections == 0 &&
            !event.queued) {
          final pending = _pendingSessions.remove(signalContactId);
          pending?.completer.completeError(
            StateError(
                'Kontakt $signalContactId jest offline albo ma inny identyfikator.'),
          );
          _setStatus(
              'Nie dostarczono handshake do $signalContactId. Sprawdz dokladny userId kontaktu.');
        }
        break;
      case RelayPresence():
        _relayPresence
          ..clear()
          ..addAll(event.contacts);
        notifyListeners();
        unawaited(_retryPendingGroupInvites());
        break;
      case RelayProfile():
        await _applyContactProfile(event.userId, event.profile);
        break;
      case RelayDirectory():
        _directoryEntries
          ..clear()
          ..addAll(event.entries.where((entry) {
            return entry.userId != _identity?.userId &&
                _contactById(entry.userId) == null;
          }));
        _loadingDirectory = false;
        _directoryStatus =
            'Lista zawiera ${_directoryEntries.length} publicznych uzytkownikow spoza kontaktow.';
        notifyListeners();
        break;
      case RelayContactRequest():
        await _handleContactRequest(event);
        break;
      case RelayProblem():
        _relayConnected = false;
        _relayPresence.clear();
        _presenceTimer?.cancel();
        _setStatus(event.message);
        break;
    }
  }

  void _startPresencePolling() {
    _presenceTimer?.cancel();
    _presenceTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_relayConnected) return;
      _relay
          ?.queryPresence(_contacts.map((contact) => contact.userId).toList());
    });
  }

  void _syncDirectoryVisibility() {
    final identity = _identity;
    final relay = _relay;
    if (identity == null || relay == null || !_relayConnected) return;
    relay.updateDirectory(
      enabled: _directoryEnabled,
      displayName: identity.userId,
    );
  }

  Future<void> _handleContactRequest(RelayContactRequest event) async {
    final identity = _identity;
    if (identity == null || event.from == identity.userId) return;
    if (_contactById(event.from) != null) return;

    final existingIndex =
        _contactInvites.indexWhere((invite) => invite.userId == event.from);
    final invite = ContactInvite(
      requestId: event.id,
      userId: event.from,
      displayName: event.displayName.trim().isEmpty
          ? event.from
          : event.displayName.trim(),
      identityPublicKey: event.identityPublicKey,
      createdAt: event.sentAt,
    );
    if (existingIndex >= 0) {
      _contactInvites[existingIndex] = invite;
    } else {
      _contactInvites.add(invite);
    }
    await _store.saveContactInvites(_contactInvites);
    _setStatus('Masz nowe zaproszenie do kontaktow od ${invite.displayName}.');
    notifyListeners();
  }

  Future<void> _handleSignal(RelayDeliver event) async {
    final contact = _contactById(event.from);
    if (contact == null) {
      _setStatus('Odrzucono sygnal od nieznanego kontaktu: ${event.from}.');
      return;
    }

    switch (event.signalType) {
      case 'crypto-handshake-init':
        final identity = _requireIdentity();
        final pending = _pendingSessions[contact.userId];
        final localInitiatedSessionWins =
            identity.userId.compareTo(contact.userId) < 0;
        if (pending != null && localInitiatedSessionWins) {
          _setStatus(
              'Odebrano rownolegly handshake od ${contact.userId}; kontynuujemy lokalna sesje.');
          return;
        }
        final accept = await _crypto.acceptHandshakeInit(
          identity: identity,
          contact: contact,
          wirePayload: event.payload,
        );
        _sessions[contact.userId] = accept.session;
        _pendingInviteHandshakeContacts.remove(contact.userId);
        await _saveSessions();
        final abandonedPending = _pendingSessions.remove(contact.userId);
        abandonedPending?.completer.complete(accept.session);
        final signalId = _requireRelay().sendSignal(
          to: contact.userId,
          signalType: 'crypto-handshake-accept',
          payload: accept.wirePayload,
        );
        _signalEnvelopeToContact[signalId] = contact.userId;
        _addSystemMessage(contact.userId, 'Utworzono nowa sesje E2EE.');
        unawaited(_retryPendingGroupInvites());
        break;
      case 'crypto-handshake-accept':
        final pending = _pendingSessions.remove(contact.userId);
        if (pending == null) return;
        final identity = _requireIdentity();
        final session = await _crypto.finishHandshakeAccept(
          identity: identity,
          contact: contact,
          pending: pending,
          wirePayload: event.payload,
        );
        _sessions[contact.userId] = session;
        _pendingInviteHandshakeContacts.remove(contact.userId);
        await _saveSessions();
        pending.completer.complete(session);
        _addSystemMessage(contact.userId, 'Sesja E2EE jest gotowa.');
        unawaited(_retryPendingGroupInvites());
        break;
    }
  }

  Future<void> _handleEncryptedPacket(
    String from,
    Map<String, dynamic> packetJson, {
    required String transport,
  }) async {
    final identity = _requireIdentity();
    final contact = _contactById(from);
    final session = _sessions[from];
    if (contact == null || session == null) {
      _setStatus('Nie mozna odszyfrowac pakietu od $from bez aktywnej sesji.');
      return;
    }

    try {
      final packet = EncryptedPacket.fromJson(packetJson);
      final decrypted = await _crypto.decryptPayload(
        session: session,
        expectedFrom: from,
        expectedTo: identity.userId,
        packet: packet,
      );
      if (decrypted.payload.type == PlainPayloadType.retraction) {
        final groupId = decrypted.payload.groupId;
        if (groupId != null && groupId.isNotEmpty) {
          _markGroupMessageRetracted(
            groupId,
            decrypted.payload.targetMessageId!,
            from,
            fallbackCreatedAt: decrypted.createdAt,
            fallbackTransport: transport,
          );
          return;
        }
        _markMessageRetracted(
          from,
          decrypted.payload.targetMessageId!,
          allowedDirection: MessageDirection.inbound,
          fallbackCreatedAt: decrypted.createdAt,
          fallbackTransport: transport,
        );
        return;
      }
      if (decrypted.payload.type == PlainPayloadType.reaction) {
        final groupId = decrypted.payload.groupId;
        if (groupId != null && groupId.isNotEmpty) {
          _applyReaction(
            groupId,
            decrypted.payload.targetMessageId!,
            from,
            decrypted.payload.reactionEmoji,
          );
          return;
        }
        _applyReaction(
          from,
          decrypted.payload.targetMessageId!,
          from,
          decrypted.payload.reactionEmoji,
        );
        return;
      }
      if (decrypted.payload.type == PlainPayloadType.pin) {
        final groupId = decrypted.payload.groupId;
        if (groupId != null && groupId.isNotEmpty) {
          _applyPin(
            groupId,
            decrypted.payload.targetMessageId!,
            decrypted.payload.pinPinned == true,
          );
          return;
        }
        _applyPin(
          from,
          decrypted.payload.targetMessageId!,
          decrypted.payload.pinPinned == true,
        );
        return;
      }
      if (decrypted.payload.type == PlainPayloadType.receipt) {
        _applyReceipt(
          from,
          decrypted.payload.targetMessageId!,
          decrypted.payload.receiptKind ?? ReceiptKind.delivered,
        );
        return;
      }
      if (decrypted.payload.type == PlainPayloadType.edit) {
        final groupId = decrypted.payload.groupId;
        if (groupId != null && groupId.isNotEmpty) {
          _applyGroupEdit(
            groupId,
            decrypted.payload.targetMessageId!,
            decrypted.payload.editedText ?? '',
            from,
            editedAt: decrypted.createdAt,
          );
          return;
        }
        _applyEdit(
          from,
          decrypted.payload.targetMessageId!,
          decrypted.payload.editedText ?? '',
          allowedDirection: MessageDirection.inbound,
          editedAt: decrypted.createdAt,
        );
        return;
      }
      if (decrypted.payload.type == PlainPayloadType.groupInvite) {
        await _handleGroupInvite(from, decrypted.payload);
        return;
      }
      if (decrypted.payload.type == PlainPayloadType.groupInviteResponse) {
        await _handleGroupInviteResponse(from, decrypted.payload);
        return;
      }
      if (decrypted.payload.type == PlainPayloadType.groupLeave) {
        await _handleGroupLeave(from, decrypted.payload);
        return;
      }
      if (decrypted.payload.type == PlainPayloadType.groupText) {
        _handleGroupText(
            from, decrypted.payload, decrypted.createdAt, transport);
        return;
      }
      if (decrypted.payload.type == PlainPayloadType.file &&
          decrypted.payload.groupId != null) {
        _handleGroupFile(
            from, decrypted.payload, decrypted.createdAt, transport);
        return;
      }
      final added = _addMessage(
        ChatMessage(
          id: decrypted.messageId,
          contactId: from,
          direction: MessageDirection.inbound,
          payload: decrypted.payload,
          createdAt: decrypted.createdAt,
          status: MessageStatus.delivered,
          transport: transport,
        ),
      );
      if (added) {
        unawaited(
            _sendReceipt(contact, decrypted.messageId, ReceiptKind.delivered));
        unawaited(
          DesktopNotifier.instance.notifyIncoming(
            senderName: contact.displayName,
            payload: decrypted.payload,
          ),
        );
      }
    } catch (error) {
      _setStatus('Odrzucono pakiet: $error');
    }
  }

  Future<void> _handleGroupInvite(String from, PlainPayload payload) async {
    final identity = _requireIdentity();
    final groupId = payload.groupId;
    if (groupId == null || groupId.isEmpty) return;
    await _mergeGroupMemberInfos(payload.groupMemberInfos ?? const []);
    final memberIds = <String>{
      ...?payload.groupMemberIds,
      from,
      identity.userId,
    }.toList(growable: false);
    final acceptedMemberIds = <String>{
      from,
      ...?payload.groupAcceptedMemberIds,
    }.where((userId) => memberIds.contains(userId)).toList(growable: false);
    if (!memberIds.contains(identity.userId)) return;

    final existingIndex =
        _groups.indexWhere((group) => group.groupId == groupId);
    if (existingIndex >= 0) {
      final existing = _groups[existingIndex];
      final nextMemberIds = <String>{
        ...existing.memberIds,
        ...memberIds,
      }.toList(growable: false);
      final nextAcceptedIds = <String>{
        ...existing.acceptedMemberIds,
        ...acceptedMemberIds,
      }
          .where((userId) => nextMemberIds.contains(userId))
          .toList(growable: false);
      final wasAccepted = existing.isAcceptedBy(identity.userId);
      final membershipChanged =
          !setEquals(existing.memberIds.toSet(), nextMemberIds.toSet()) ||
              !setEquals(
                  existing.acceptedMemberIds.toSet(), nextAcceptedIds.toSet());
      _groups[existingIndex] = existing.copyWith(
        name: payload.groupName ?? existing.name,
        memberIds: nextMemberIds,
        acceptedMemberIds: nextAcceptedIds,
        invitedBy: existing.invitedBy ?? from,
        pendingInvite: wasAccepted ? false : true,
      );
      await _store.saveGroups(_groups);
      if (wasAccepted && membershipChanged) {
        _addSystemMessage(groupId, 'Zaktualizowano sklad grupy.');
      }
      notifyListeners();
      return;
    }

    final group = GroupConversation(
      groupId: groupId,
      name: payload.groupName ?? 'Grupa',
      memberIds: memberIds,
      acceptedMemberIds: acceptedMemberIds.isEmpty ? [from] : acceptedMemberIds,
      createdAt: DateTime.now().toUtc(),
      invitedBy: from,
      pendingInvite: true,
    );
    _groups.add(group);
    await _store.saveGroups(_groups);
    _addSystemMessage(
      groupId,
      'Zaproszenie do grupy "${group.name}" od ${displayNameForUser(from)}.',
    );
    unawaited(
      DesktopNotifier.instance.notifyIncoming(
        senderName: displayNameForUser(from),
        payload: PlainPayload.groupInvite(
          groupId: group.groupId,
          groupName: group.name,
          groupMemberIds: group.memberIds,
          groupAcceptedMemberIds: group.acceptedMemberIds,
          groupMemberInfos: payload.groupMemberInfos ?? const [],
        ),
      ),
    );
    notifyListeners();
  }

  Future<void> _handleGroupInviteResponse(
    String from,
    PlainPayload payload,
  ) async {
    final groupId = payload.groupId;
    if (groupId == null || groupId.isEmpty) return;
    final index = _groups.indexWhere((group) => group.groupId == groupId);
    if (index < 0) return;

    final group = _groups[index];
    if (!group.memberIds.contains(from)) return;

    if (payload.groupAccepted == true) {
      final acceptedIds = <String>{
        ...group.acceptedMemberIds,
        from,
      }.toList(growable: false);
      _groups[index] = group.copyWith(acceptedMemberIds: acceptedIds);
      _addSystemMessage(
          groupId, '${displayNameForUser(from)} dolaczyl do grupy.');
      await _store.saveGroups(_groups);
      await _broadcastGroupRoster(_groups[index]);
    } else {
      final acceptedIds = group.acceptedMemberIds
          .where((userId) => userId != from)
          .toList(growable: false);
      _groups[index] = group.copyWith(acceptedMemberIds: acceptedIds);
      _addSystemMessage(
        groupId,
        '${displayNameForUser(from)} odrzucil zaproszenie do grupy.',
      );
    }
    await _store.saveGroups(_groups);
    notifyListeners();
  }

  Future<void> _handleGroupLeave(String from, PlainPayload payload) async {
    final groupId = payload.groupId;
    if (groupId == null || groupId.isEmpty) return;
    final index = _groups.indexWhere((group) => group.groupId == groupId);
    if (index < 0) return;

    final group = _groups[index];
    if (!group.memberIds.contains(from)) return;
    final acceptedIds = group.acceptedMemberIds
        .where((userId) => userId != from)
        .toList(growable: false);
    _groups[index] = group.copyWith(acceptedMemberIds: acceptedIds);
    _addSystemMessage(groupId, '${displayNameForUser(from)} wyszedl z grupy.');
    await _store.saveGroups(_groups);
    notifyListeners();
  }

  void _handleGroupText(
    String from,
    PlainPayload payload,
    DateTime createdAt,
    String transport,
  ) {
    final groupId = payload.groupId;
    final messageId = payload.groupMessageId;
    if (groupId == null ||
        groupId.isEmpty ||
        messageId == null ||
        messageId.isEmpty) {
      return;
    }
    final group = _groupById(groupId);
    final identity = _identity;
    if (group == null ||
        identity == null ||
        group.pendingInvite ||
        !group.isAcceptedBy(identity.userId) ||
        !group.acceptedMemberIds.contains(from)) {
      return;
    }

    final added = _addMessage(
      ChatMessage(
        id: messageId,
        contactId: groupId,
        direction: MessageDirection.inbound,
        payload: PlainPayload.text(
          payload.text ?? '',
          replyToMessageId: payload.replyToMessageId,
          replyPreview: payload.replyPreview,
        ),
        createdAt: createdAt,
        status: MessageStatus.delivered,
        senderId: from,
        transport: transport,
      ),
    );
    if (!added) return;
    final contact = _contactById(from);
    if (contact != null) {
      unawaited(
        DesktopNotifier.instance.notifyIncoming(
          senderName: '${group.name} / ${contact.displayName}',
          payload: PlainPayload.text(payload.text ?? ''),
        ),
      );
    }
  }

  void _handleGroupFile(
    String from,
    PlainPayload payload,
    DateTime createdAt,
    String transport,
  ) {
    final groupId = payload.groupId;
    final messageId = payload.groupMessageId;
    if (groupId == null ||
        groupId.isEmpty ||
        messageId == null ||
        messageId.isEmpty) {
      return;
    }
    final group = _groupById(groupId);
    final identity = _identity;
    if (group == null ||
        identity == null ||
        group.pendingInvite ||
        !group.isAcceptedBy(identity.userId) ||
        !group.acceptedMemberIds.contains(from)) {
      return;
    }

    final added = _addMessage(
      ChatMessage(
        id: messageId,
        contactId: groupId,
        direction: MessageDirection.inbound,
        payload: PlainPayload.file(
          fileName: payload.fileName ?? 'plik',
          mimeType: payload.mimeType,
          fileSize: payload.fileSize ?? 0,
          fileBytesBase64: payload.fileBytesBase64 ?? '',
          replyToMessageId: payload.replyToMessageId,
          replyPreview: payload.replyPreview,
        ),
        createdAt: createdAt,
        status: MessageStatus.delivered,
        senderId: from,
        transport: transport,
      ),
    );
    if (!added) return;
    unawaited(
      DesktopNotifier.instance.notifyIncoming(
        senderName: '${group.name} / ${displayNameForUser(from)}',
        payload: PlainPayload.file(
          fileName: payload.fileName ?? 'plik',
          mimeType: payload.mimeType,
          fileSize: payload.fileSize ?? 0,
          fileBytesBase64: payload.fileBytesBase64 ?? '',
        ),
      ),
    );
  }

  bool _addMessage(ChatMessage message) {
    final list =
        _messages.putIfAbsent(message.contactId, () => <ChatMessage>[]);
    if (list.any((item) => item.id == message.id)) return false;
    list.add(message);
    _sortMessages(list);
    unawaited(_persistMessages());
    _scheduleDeviceSyncFor(message);
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
      _scheduleDeviceSyncFor(list[index]);
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
    _scheduleDeviceSyncFor(placeholder);
    notifyListeners();
    return true;
  }

  bool _markGroupMessageRetracted(
    String groupId,
    String messageId,
    String senderId, {
    DateTime? fallbackCreatedAt,
    String? fallbackTransport,
  }) {
    final list = _messages.putIfAbsent(groupId, () => <ChatMessage>[]);
    final index = list.indexWhere((message) => message.id == messageId);
    if (index >= 0) {
      final message = list[index];
      if (message.senderId != senderId || message.retracted) {
        return message.retracted;
      }

      list[index] = message.copyWith(
        payload: const PlainPayload.text(''),
        retracted: true,
        pinned: false,
        reactions: const {},
        clearEditedAt: true,
      );
      unawaited(_persistMessages());
      _scheduleDeviceSyncFor(list[index]);
      notifyListeners();
      return true;
    }

    final placeholder = ChatMessage(
      id: messageId,
      contactId: groupId,
      direction: MessageDirection.inbound,
      payload: const PlainPayload.text(''),
      createdAt: fallbackCreatedAt ?? DateTime.now().toUtc(),
      status: MessageStatus.delivered,
      retracted: true,
      senderId: senderId,
      transport: fallbackTransport,
    );
    list.add(placeholder);
    _sortMessages(list);
    unawaited(_persistMessages());
    _scheduleDeviceSyncFor(placeholder);
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
    _scheduleDeviceSyncFor(list[index]);
    notifyListeners();
    return true;
  }

  bool _applyGroupEdit(
    String groupId,
    String messageId,
    String text,
    String editorId, {
    DateTime? editedAt,
  }) {
    final list = _messages[groupId];
    if (list == null) return false;
    final index = list.indexWhere((message) => message.id == messageId);
    if (index < 0) return false;

    final message = list[index];
    if (message.senderId != editorId ||
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
    _scheduleDeviceSyncFor(list[index]);
    notifyListeners();
    return true;
  }

  bool _applyReceipt(
    String contactId,
    String messageId,
    ReceiptKind kind,
  ) {
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
    _scheduleDeviceSyncFor(list[index]);
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
    _scheduleDeviceSyncFor(list[index]);
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
    _scheduleDeviceSyncFor(list[index]);
    notifyListeners();
    return true;
  }

  void _addSystemMessage(String contactId, String text) {
    _addMessage(
      ChatMessage(
        id: '${DateTime.now().microsecondsSinceEpoch}-$contactId',
        contactId: contactId,
        direction: MessageDirection.system,
        payload: PlainPayload.text(text),
        createdAt: DateTime.now().toUtc(),
        status: MessageStatus.delivered,
      ),
    );
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
    _scheduleDeviceSyncFor(list[index]);
    notifyListeners();
  }

  bool _isUnreadIncomingMessage(ChatMessage message) {
    return message.direction == MessageDirection.inbound &&
        message.status != MessageStatus.read &&
        !message.retracted &&
        (message.payload.type == PlainPayloadType.text ||
            message.payload.type == PlainPayloadType.file);
  }

  MessageStatus _promoteStatus(
    MessageStatus current,
    MessageStatus incoming,
  ) {
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

  void _scheduleDeviceSyncFor(ChatMessage message) {
    if (_applyingDeviceSync || _identity == null) return;
    _pendingDeviceSyncMessages['${message.contactId}/${message.id}'] = message;
    _deviceSyncTimer?.cancel();
    _deviceSyncTimer = Timer(const Duration(milliseconds: 700), () {
      unawaited(_flushDeviceSyncMessages());
    });
  }

  void _scheduleDeviceSyncForMany(Iterable<ChatMessage> messages) {
    for (final message in messages) {
      if (_applyingDeviceSync || _identity == null) return;
      _pendingDeviceSyncMessages['${message.contactId}/${message.id}'] =
          message;
    }
    if (_pendingDeviceSyncMessages.isEmpty) return;
    _deviceSyncTimer?.cancel();
    _deviceSyncTimer = Timer(const Duration(milliseconds: 700), () {
      unawaited(_flushDeviceSyncMessages());
    });
  }

  Future<void> _flushDeviceSyncMessages() async {
    if (_pendingDeviceSyncMessages.isEmpty) return;
    if (!_relayConnected || _relay == null || _identity == null) return;

    final messages = _pendingDeviceSyncMessages.values.toList(growable: false);
    _pendingDeviceSyncMessages.clear();
    await _sendDeviceSyncMessages(messages, syncType: 'messages');
  }

  Future<void> _broadcastDeviceSyncSnapshot() async {
    if (!_relayConnected || _relay == null || _identity == null) return;
    await _sendDeviceSyncMessages(_allMessagesSnapshot(), syncType: 'snapshot');
  }

  Future<void> _sendDeviceSyncMessages(
    List<ChatMessage> messages, {
    required String syncType,
  }) async {
    final identity = _identity;
    final relay = _relay;
    if (identity == null || relay == null || !_relayConnected) return;

    final maxPayloadBytes = (_relayMaxPayloadBytes * 0.9).floor();
    var index = 0;
    var sentEmptySnapshot = false;

    while (index < messages.length ||
        (messages.isEmpty && syncType == 'snapshot' && !sentEmptySnapshot)) {
      var end = messages.isEmpty
          ? 0
          : index + 25 > messages.length
              ? messages.length
              : index + 25;
      Map<String, dynamic>? payload;
      var payloadSize = 0;

      while (true) {
        final batch = messages.isEmpty
            ? const <ChatMessage>[]
            : messages.sublist(index, end);
        payload = await _buildDeviceSyncPayload(
          identity: identity,
          syncType: syncType,
          messages: batch,
        );
        payloadSize = utf8.encode(jsonEncode(payload)).length;
        if (payloadSize <= maxPayloadBytes ||
            messages.isEmpty ||
            end <= index + 1) {
          break;
        }
        final nextSize = ((end - index) / 2).floor();
        end = index + (nextSize < 1 ? 1 : nextSize);
      }

      if (payloadSize > maxPayloadBytes) {
        _setStatus(
            'Pominieto synchronizacje jednej duzej wiadomosci miedzy urzadzeniami.');
        if (messages.isEmpty) {
          sentEmptySnapshot = true;
        } else {
          index += 1;
        }
        continue;
      }

      try {
        relay.sendRelay(to: identity.userId, payload: payload);
      } catch (_) {
        if (messages.isNotEmpty) {
          for (var i = index; i < end; i += 1) {
            _pendingDeviceSyncMessages[
                '${messages[i].contactId}/${messages[i].id}'] = messages[i];
          }
        }
        return;
      }

      if (messages.isEmpty) {
        sentEmptySnapshot = true;
      } else {
        index = end;
      }
    }
  }

  Future<Map<String, dynamic>> _buildDeviceSyncPayload({
    required IdentityKeyMaterial identity,
    required String syncType,
    required List<ChatMessage> messages,
  }) async {
    final clearJson = jsonEncode({
      'v': 1,
      'type': syncType,
      'senderDeviceId': identity.deviceId,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'contacts': _contacts.map((contact) => contact.toJson()).toList(),
      'groups': _groups.map((group) => group.toJson()).toList(),
      'directoryEnabled': _directoryEnabled,
      'ownProfile': _ownProfile?.toJson(),
      'messages': messages.map((message) => message.toJson()).toList(),
    });
    final nonce = secureRandomBytes(12);
    final box = await _deviceSyncAead.encrypt(
      utf8Bytes(clearJson),
      secretKey: await _localArchiveSecretKey(),
      nonce: nonce,
      aad: utf8Bytes(_deviceSyncAad),
    );

    return {
      'v': 1,
      'protocol': _deviceSyncProtocol,
      'senderDeviceId': identity.deviceId,
      'nonce': b64(box.nonce),
      'ciphertext': b64(box.cipherText),
      'mac': b64(box.mac.bytes),
    };
  }

  bool _isDeviceSyncPayload(Map<String, dynamic> payload) {
    return payload['protocol'] == _deviceSyncProtocol;
  }

  Future<void> _handleDeviceSyncPayload(Map<String, dynamic> payload) async {
    final identity = _identity;
    if (identity == null) return;
    if (payload['senderDeviceId'] == identity.deviceId) return;

    try {
      final box = SecretBox(
        unb64(payload['ciphertext'] as String),
        nonce: unb64(payload['nonce'] as String),
        mac: Mac(unb64(payload['mac'] as String)),
      );
      final clearBytes = await _deviceSyncAead.decrypt(
        box,
        secretKey: await _localArchiveSecretKey(),
        aad: utf8Bytes(_deviceSyncAad),
      );
      final clear = jsonDecode(utf8.decode(clearBytes)) as Map<String, dynamic>;
      if (clear['senderDeviceId'] == identity.deviceId) return;

      _applyingDeviceSync = true;
      var changed = false;
      changed = _mergeSyncedContacts(clear['contacts'] as List?) || changed;
      changed = _mergeSyncedGroups(clear['groups'] as List?) || changed;
      changed = await _mergeSyncedProfile(clear['ownProfile']) || changed;
      final directoryEnabled = clear['directoryEnabled'];
      if (directoryEnabled is bool && directoryEnabled != _directoryEnabled) {
        _directoryEnabled = directoryEnabled;
        await _store.saveDirectoryEnabled(_directoryEnabled);
        changed = true;
      }
      final syncedMessages = ((clear['messages'] as List?) ?? const [])
          .map((item) =>
              ChatMessage.fromJson((item as Map).cast<String, dynamic>()))
          .toList(growable: false);
      changed = _mergeSyncedMessages(syncedMessages) || changed;

      if (!changed) return;
      await _store.saveContacts(_contacts);
      await _store.saveGroups(_groups);
      await _persistMessages();
      notifyListeners();
    } catch (_) {
      _setStatus(
          'Nie udalo sie odszyfrowac synchronizacji z innego urzadzenia.');
    } finally {
      _applyingDeviceSync = false;
    }
  }

  bool _mergeSyncedContacts(List<dynamic>? rawContacts) {
    if (rawContacts == null) return false;
    final identity = _identity;
    var changed = false;
    for (final item in rawContacts) {
      final contact = Contact.fromJson((item as Map).cast<String, dynamic>());
      if (identity != null && contact.userId == identity.userId) continue;
      final index =
          _contacts.indexWhere((existing) => existing.userId == contact.userId);
      if (index < 0) {
        _contacts.add(contact);
        changed = true;
        continue;
      }

      final existing = _contacts[index];
      if (existing.identityPublicKey != contact.identityPublicKey) continue;
      if (existing.signingPublicKey?.isNotEmpty == true &&
          contact.signingPublicKey?.isNotEmpty == true &&
          existing.signingPublicKey != contact.signingPublicKey) {
        continue;
      }
      final incomingProfileDate = contact.profileUpdatedAt;
      final currentProfileDate = existing.profileUpdatedAt;
      final useIncomingProfile = incomingProfileDate != null &&
          (currentProfileDate == null ||
              incomingProfileDate.isAfter(currentProfileDate));
      final merged = Contact(
        userId: existing.userId,
        displayName: contact.displayName.isNotEmpty
            ? contact.displayName
            : existing.displayName,
        identityPublicKey: existing.identityPublicKey,
        signingPublicKey: existing.signingPublicKey?.isNotEmpty == true
            ? existing.signingPublicKey
            : contact.signingPublicKey,
        keyAgreementPublicKeySignature:
            existing.keyAgreementPublicKeySignature?.isNotEmpty == true
                ? existing.keyAgreementPublicKeySignature
                : contact.keyAgreementPublicKeySignature,
        identityRotationProof:
            existing.identityRotationProof ?? contact.identityRotationProof,
        avatarMimeType: useIncomingProfile
            ? contact.avatarMimeType
            : existing.avatarMimeType,
        avatarBytesBase64: useIncomingProfile
            ? contact.avatarBytesBase64
            : existing.avatarBytesBase64,
        profileUpdatedAt: useIncomingProfile
            ? contact.profileUpdatedAt
            : existing.profileUpdatedAt,
      );
      if (jsonEncode(merged.toJson()) != jsonEncode(existing.toJson())) {
        _contacts[index] = merged;
        changed = true;
      }
    }
    if (changed) {
      _contacts.sort((a, b) => a.displayName.compareTo(b.displayName));
    }
    return changed;
  }

  bool _mergeSyncedGroups(List<dynamic>? rawGroups) {
    if (rawGroups == null) return false;
    var changed = false;
    for (final item in rawGroups) {
      final incoming =
          GroupConversation.fromJson((item as Map).cast<String, dynamic>());
      final index =
          _groups.indexWhere((group) => group.groupId == incoming.groupId);
      if (index < 0) {
        _groups.add(incoming);
        changed = true;
        continue;
      }

      final existing = _groups[index];
      final merged = existing.copyWith(
        name: incoming.name,
        memberIds: <String>{
          ...existing.memberIds,
          ...incoming.memberIds,
        }.toList(growable: false),
        acceptedMemberIds: <String>{
          ...existing.acceptedMemberIds,
          ...incoming.acceptedMemberIds,
        }.toList(growable: false),
        invitedMemberIds: <String>{
          ...existing.invitedMemberIds,
          ...incoming.invitedMemberIds,
        }.toList(growable: false),
        invitedBy: existing.invitedBy ?? incoming.invitedBy,
        pendingInvite: existing.pendingInvite && incoming.pendingInvite,
      );
      if (jsonEncode(merged.toJson()) != jsonEncode(existing.toJson())) {
        _groups[index] = merged;
        changed = true;
      }
    }
    return changed;
  }

  Future<bool> _mergeSyncedProfile(Object? rawProfile) async {
    if (rawProfile == null) return false;
    final incoming =
        UserProfile.fromJson((rawProfile as Map).cast<String, dynamic>());
    final incomingDate = incoming.updatedAt;
    final currentDate = _ownProfile?.updatedAt;
    if (incomingDate != null &&
        currentDate != null &&
        !incomingDate.isAfter(currentDate)) {
      return false;
    }
    _ownProfile = incoming;
    await _store.saveOwnProfile(incoming);
    if (_relayConnected) _relay?.updateProfile(incoming);
    return true;
  }

  bool _mergeSyncedMessages(List<ChatMessage> incomingMessages) {
    var changed = false;
    for (final incoming in incomingMessages) {
      final list =
          _messages.putIfAbsent(incoming.contactId, () => <ChatMessage>[]);
      final index = list.indexWhere((message) => message.id == incoming.id);
      if (index < 0) {
        list.add(incoming);
        _sortMessages(list);
        changed = true;
        continue;
      }

      final merged = _mergeMessageVersions(list[index], incoming);
      if (jsonEncode(merged.toJson()) != jsonEncode(list[index].toJson())) {
        list[index] = merged;
        _sortMessages(list);
        changed = true;
      }
    }
    return changed;
  }

  ChatMessage _mergeMessageVersions(
    ChatMessage existing,
    ChatMessage incoming,
  ) {
    final existingEditedAt = existing.editedAt;
    final incomingEditedAt = incoming.editedAt;
    final useIncomingBody = incoming.retracted ||
        (incomingEditedAt != null &&
            (existingEditedAt == null ||
                incomingEditedAt.isAfter(existingEditedAt)));
    final base = useIncomingBody ? incoming : existing;
    final reactions = <String, String>{
      ...existing.reactions,
      ...incoming.reactions,
    };

    return base.copyWith(
      status: _promoteStatus(existing.status, incoming.status),
      retracted: existing.retracted || incoming.retracted,
      pinned: incoming.pinned,
      reactions: reactions,
      editedAt: _newestDate(existing.editedAt, incoming.editedAt),
      transport: incoming.transport ?? existing.transport,
      error: incoming.error ?? existing.error,
    );
  }

  DateTime? _newestDate(DateTime? left, DateTime? right) {
    if (left == null) return right;
    if (right == null) return left;
    return right.isAfter(left) ? right : left;
  }

  Future<String> _localArchiveKeyBase64() async {
    final existing = await _store.loadLocalArchiveKey();
    if (_isValidArchiveKey(existing)) return existing!;

    final keyBytes = secureRandomBytes(32);
    final encoded = b64(keyBytes);
    await _store.saveLocalArchiveKey(encoded);
    return encoded;
  }

  Future<SecretKey> _localArchiveSecretKey() async {
    return SecretKey(unb64(await _localArchiveKeyBase64()));
  }

  bool _isValidArchiveKey(String? value) {
    if (value == null || value.isEmpty) return false;
    try {
      return unb64(value).length == 32;
    } catch (_) {
      return false;
    }
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
    }
  }

  String? _updatePlatform() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isAndroid) return 'android';
    return null;
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
      final raw = await utf8.decodeStream(response);
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } finally {
      client.close(force: true);
    }
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
      File file, String? expectedSha256) async {
    final expected = expectedSha256?.trim().toLowerCase();
    if (expected == null || expected.isEmpty) return;

    final actual =
        crypto_hash.sha256.convert(await file.readAsBytes()).toString();
    if (actual != expected) {
      try {
        await file.delete();
      } catch (_) {}
      throw StateError(
          'Suma SHA-256 pobranego pliku nie zgadza sie z manifestem.');
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

  Future<SecretKey> _deriveAccountExportKey(
    String passphrase,
    List<int> salt,
  ) {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _accountExportIterations,
      bits: 256,
    );
    return kdf.deriveKey(
      secretKey: SecretKey(utf8Bytes(passphrase)),
      nonce: salt,
    );
  }

  void _validateAccountTransferPassphrase(String passphrase) {
    final error = accountTransferPassphraseError(passphrase);
    if (error != null) {
      throw ArgumentError(error);
    }
  }

  Future<void> _loadArchivedMessages() async {
    final archived = await _messageArchive.load();
    _messages.clear();
    for (final message in archived) {
      final list =
          _messages.putIfAbsent(message.contactId, () => <ChatMessage>[]);
      if (!list.any((item) => item.id == message.id)) {
        list.add(message);
      }
    }
    for (final list in _messages.values) {
      _sortMessages(list);
    }
  }

  Future<void> _loadSessions() async {
    _sessions.clear();
    final storedSessions = await _store.loadSessions();
    for (final session in storedSessions) {
      _sessions[session.contactId] = session;
    }
  }

  Future<void> _saveSessions() {
    return _store.saveSessions(_sessions.values);
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

  Future<void> _acceptCloudMessageReplayState({
    required String conversationId,
    required String senderUserId,
    required String senderDeviceId,
    required int? messageCounter,
    required String previousMessageHash,
    required String messageHash,
  }) async {
    final session = _cloudSession;
    if (session == null || messageCounter == null || senderDeviceId.isEmpty) {
      return;
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
      if (messageCounter != existing.lastCounter + 1 ||
          previousMessageHash != existing.lastMessageHash) {
        throw StateError(
          'Wykryto przerwanie albo zmiane kolejnosci strumienia wiadomosci cloud.',
        );
      }
    }
    await _rememberCloudReplayState(
      conversationId: conversationId,
      senderUserId: senderUserId,
      senderDeviceId: senderDeviceId,
      lastCounter: messageCounter,
      lastMessageHash: messageHash,
    );
  }

  Future<void> _rememberCloudReplayState({
    required String conversationId,
    required String senderUserId,
    required String senderDeviceId,
    required int lastCounter,
    required String lastMessageHash,
  }) async {
    final session = _cloudSession;
    if (session == null || senderDeviceId.isEmpty) return;
    final state = CloudMessageReplayState(
      accountId: session.userId,
      conversationId: conversationId,
      senderUserId: senderUserId,
      senderDeviceId: senderDeviceId,
      lastCounter: lastCounter,
      lastMessageHash: lastMessageHash,
    );
    _cloudReplayStates[state.key] = state;
    await _saveCloudReplayStates();
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
    return (_messages[contactId] ?? const <ChatMessage>[])
        .any((message) => message.id == messageId);
  }

  Future<void> _applyContactProfile(String userId, UserProfile profile) async {
    final index = _contacts.indexWhere((contact) => contact.userId == userId);
    if (index < 0) return;

    final contact = _contacts[index];
    final incomingUpdatedAt = profile.updatedAt;
    final currentUpdatedAt = contact.profileUpdatedAt;
    if (incomingUpdatedAt != null &&
        currentUpdatedAt != null &&
        !incomingUpdatedAt.isAfter(currentUpdatedAt)) {
      return;
    }

    _contacts[index] = Contact(
      userId: contact.userId,
      displayName: contact.displayName,
      identityPublicKey: contact.identityPublicKey,
      signingPublicKey: contact.signingPublicKey,
      keyAgreementPublicKeySignature: contact.keyAgreementPublicKeySignature,
      identityRotationProof: contact.identityRotationProof,
      avatarMimeType: profile.avatarMimeType,
      avatarBytesBase64: profile.avatarBytesBase64,
      profileUpdatedAt: incomingUpdatedAt ?? DateTime.now().toUtc(),
    );
    await _store.saveContacts(_contacts);
    notifyListeners();
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

  GroupConversation? _groupById(String groupId) {
    for (final group in _groups) {
      if (group.groupId == groupId) return group;
    }
    return null;
  }

  IdentityKeyMaterial _requireIdentity() {
    final identity = _identity;
    if (identity == null) throw StateError('Brak lokalnej tozsamosci.');
    return identity;
  }

  RelayClient _requireRelay() {
    final relay = _relay;
    if (relay == null || !_relayConnected) {
      throw StateError('Relay nie jest polaczony.');
    }
    return relay;
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

  @override
  void dispose() {
    _presenceTimer?.cancel();
    unawaited(_relaySubscription?.cancel());
    unawaited(_relay?.dispose());
    unawaited(_cloudSubscription?.cancel());
    unawaited(_cloudClient?.dispose());
    super.dispose();
  }
}
