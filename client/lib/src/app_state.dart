import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'crypto/codec.dart';
import 'crypto/crypto_service.dart';
import 'models/contact.dart';
import 'models/encrypted_packet.dart';
import 'models/identity.dart';
import 'models/message.dart';
import 'models/session.dart';
import 'models/user_profile.dart';
import 'network/relay_client.dart';
import 'p2p/webrtc_transport.dart';
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

  final SecureStore _store;
  final CryptoService _crypto;
  late final MessageArchive _messageArchive;
  Future<void> _persistQueue = Future<void>.value();
  final List<Contact> _contacts = [];
  final Map<String, List<ChatMessage>> _messages = {};
  final Map<String, SessionState> _sessions = {};
  final Map<String, PendingSession> _pendingSessions = {};
  final Map<String, String> _relayEnvelopeToMessage = {};
  final Map<String, String> _signalEnvelopeToContact = {};
  final Map<String, bool> _p2pConnected = {};
  final Map<String, bool> _relayPresence = {};

  IdentityKeyMaterial? _identity;
  UserProfile? _ownProfile;
  RelaySettings? _relaySettings;
  RelayClient? _relay;
  StreamSubscription<RelayEvent>? _relaySubscription;
  Timer? _presenceTimer;
  WebRtcTransport? _p2p;
  bool _relayConnected = false;
  bool _initializing = true;
  String? _status;
  int _relayMaxPayloadBytes = 16 * 1024 * 1024;

  bool get initializing => _initializing;
  bool get hasIdentity => _identity != null;
  bool get relayConnected => _relayConnected;
  String? get status => _status;
  String? get ownUserId => _identity?.userId;
  String? get ownPublicKey =>
      _identity == null ? null : b64(_identity!.publicKey.bytes);
  UserProfile? get ownProfile => _ownProfile;
  RelaySettings? get relaySettings => _relaySettings;
  List<Contact> get contacts => List.unmodifiable(_contacts);

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

  bool isP2pConnected(String contactId) => _p2pConnected[contactId] == true;

  bool isContactOnline(String contactId) {
    return _p2pConnected[contactId] == true ||
        _relayPresence[contactId] == true;
  }

  Future<void> initialize() async {
    try {
      _identity = await _store.loadIdentity();
      _ownProfile = await _store.loadOwnProfile();
      _relaySettings = await _store.loadRelaySettings();
      _contacts
        ..clear()
        ..addAll(await _store.loadContacts());
      await _loadArchivedMessages();
      await _loadSessions();
      _initializing = false;
      notifyListeners();

      if (_identity != null && _relaySettings != null) {
        await connectRelay();
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
  }

  Future<void> connectRelay() async {
    final identity = _identity;
    final settings = _relaySettings;
    if (identity == null || settings == null) return;

    await _relaySubscription?.cancel();
    await _relay?.disconnect();
    await _p2p?.dispose();

    _relayConnected = false;
    _p2pConnected.clear();
    _relayPresence.clear();
    _presenceTimer?.cancel();
    _relay = RelayClient(settings: settings, identity: identity);
    _p2p = WebRtcTransport(
      localUserId: identity.userId,
      sendSignal: (to, signalType, payload) {
        _relay?.sendSignal(to: to, signalType: signalType, payload: payload);
      },
      onSecurePacket: (from, packet) =>
          _handleEncryptedPacket(from, packet, transport: 'p2p'),
      onPeerStateChanged: (peerId, connected) {
        _p2pConnected[peerId] = connected;
        notifyListeners();
      },
    );

    _relaySubscription = _relay!.events.listen(
      (event) => unawaited(_handleRelayEvent(event)),
    );
    await _relay!.connect();
    _setStatus('Laczenie z relay...');
  }

  Future<void> addContact(Contact contact) async {
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
        avatarMimeType: existing?.avatarMimeType ?? contact.avatarMimeType,
        avatarBytesBase64:
            existing?.avatarBytesBase64 ?? contact.avatarBytesBase64,
        profileUpdatedAt:
            existing?.profileUpdatedAt ?? contact.profileUpdatedAt,
      ),
    );
    _contacts.sort((a, b) => a.displayName.compareTo(b.displayName));
    await _store.saveContacts(_contacts);
    if (_relayConnected) _relay?.queryProfiles([contact.userId]);
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

  Future<void> sendText(Contact contact, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _sendPlainPayload(contact, PlainPayload.text(trimmed));
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

  Future<void> sendFile(Contact contact) async {
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
    );
  }

  Future<void> sendFileBytes(
    Contact contact, {
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
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
      ),
    );
  }

  Future<void> wipeLocalData() async {
    await _relaySubscription?.cancel();
    await _relay?.dispose();
    await _p2p?.dispose();
    await _store.wipeLocalSecrets();
    _identity = null;
    _ownProfile = null;
    _relaySettings = null;
    _relay = null;
    _p2p = null;
    _contacts.clear();
    _messages.clear();
    _sessions.clear();
    _pendingSessions.clear();
    _relayEnvelopeToMessage.clear();
    _signalEnvelopeToContact.clear();
    _p2pConnected.clear();
    _relayPresence.clear();
    _presenceTimer?.cancel();
    _relayConnected = false;
    await _messageArchive.delete();
    _setStatus('Wyczyszczono lokalne dane.');
  }

  Future<void> _sendPlainPayload(Contact contact, PlainPayload payload) async {
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
    final sentP2p =
        await _p2p?.sendEncryptedPacket(contact.userId, packet.toJson()) ??
            false;
    if (sentP2p) {
      if (visibleMessageId != null) {
        _updateMessage(contact.userId, visibleMessageId, MessageStatus.sent,
            transport: 'p2p');
      }
      return;
    }

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
        _startPresencePolling();
        break;
      case RelayDeliver():
        if (event.kind == 'signal') {
          await _handleSignal(event);
        } else if (event.kind == 'relay') {
          await _handleEncryptedPacket(event.from, event.payload,
              transport: 'relay');
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
        break;
      case RelayProfile():
        await _applyContactProfile(event.userId, event.profile);
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
        await _startP2pIfNeeded(contact);
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
        await _saveSessions();
        pending.completer.complete(session);
        _addSystemMessage(contact.userId, 'Sesja E2EE jest gotowa.');
        await _startP2pIfNeeded(contact);
        break;
      case 'webrtc-offer':
      case 'webrtc-answer':
      case 'webrtc-candidate':
        await _p2p?.handleSignal(event.from, event.signalType!, event.payload);
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
        _applyReaction(
          from,
          decrypted.payload.targetMessageId!,
          from,
          decrypted.payload.reactionEmoji,
        );
        return;
      }
      if (decrypted.payload.type == PlainPayloadType.pin) {
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
        _applyEdit(
          from,
          decrypted.payload.targetMessageId!,
          decrypted.payload.editedText ?? '',
          allowedDirection: MessageDirection.inbound,
          editedAt: decrypted.createdAt,
        );
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

  Future<void> _startP2pIfNeeded(Contact contact) async {
    final identity = _identity;
    if (identity == null || _p2p == null) return;
    final shouldInitiate = identity.userId.compareTo(contact.userId) < 0;
    await _p2p!.ensureStarted(contact.userId, initiator: shouldInitiate);
  }

  bool _addMessage(ChatMessage message) {
    final list =
        _messages.putIfAbsent(message.contactId, () => <ChatMessage>[]);
    if (list.any((item) => item.id == message.id)) return false;
    list.add(message);
    unawaited(_persistMessages());
    notifyListeners();
    return true;
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
    list.add(
      ChatMessage(
        id: messageId,
        contactId: contactId,
        direction: MessageDirection.inbound,
        payload: const PlainPayload.text(''),
        createdAt: fallbackCreatedAt ?? DateTime.now().toUtc(),
        status: MessageStatus.delivered,
        retracted: true,
        transport: fallbackTransport,
      ),
    );
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
      payload: PlainPayload.text(normalizedText),
      editedAt: editedAt ?? DateTime.now().toUtc(),
    );
    unawaited(_persistMessages());
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
      avatarMimeType: profile.avatarMimeType,
      avatarBytesBase64: profile.avatarBytesBase64,
      profileUpdatedAt: incomingUpdatedAt ?? DateTime.now().toUtc(),
    );
    await _store.saveContacts(_contacts);
    notifyListeners();
  }

  Future<void> _persistMessages() {
    final snapshot =
        _messages.values.expand((messages) => messages).toList(growable: false);
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
    unawaited(_p2p?.dispose());
    super.dispose();
  }
}
