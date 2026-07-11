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
import 'network/relay_client.dart';
import 'p2p/webrtc_transport.dart';
import 'storage/secure_store.dart';

class AppState extends ChangeNotifier {
  AppState({
    SecureStore? store,
    CryptoService? crypto,
  })  : _store = store ?? SecureStore(),
        _crypto = crypto ?? CryptoService();

  static const maxPlainFileBytes = 8 * 1024 * 1024;

  final SecureStore _store;
  final CryptoService _crypto;
  final List<Contact> _contacts = [];
  final Map<String, List<ChatMessage>> _messages = {};
  final Map<String, SessionState> _sessions = {};
  final Map<String, PendingSession> _pendingSessions = {};
  final Map<String, String> _relayEnvelopeToMessage = {};
  final Map<String, bool> _p2pConnected = {};

  IdentityKeyMaterial? _identity;
  RelaySettings? _relaySettings;
  RelayClient? _relay;
  StreamSubscription<RelayEvent>? _relaySubscription;
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
  String? get ownPublicKey => _identity == null ? null : b64(_identity!.publicKey.bytes);
  RelaySettings? get relaySettings => _relaySettings;
  List<Contact> get contacts => List.unmodifiable(_contacts);

  List<ChatMessage> messagesFor(String contactId) {
    final items = _messages[contactId] ?? const <ChatMessage>[];
    return List.unmodifiable(items);
  }

  bool isP2pConnected(String contactId) => _p2pConnected[contactId] == true;

  Future<void> initialize() async {
    try {
      _identity = await _store.loadIdentity();
      _relaySettings = await _store.loadRelaySettings();
      _contacts
        ..clear()
        ..addAll(await _store.loadContacts());
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
    _relay = RelayClient(settings: settings, identity: identity);
    _p2p = WebRtcTransport(
      localUserId: identity.userId,
      sendSignal: (to, signalType, payload) {
        _relay?.sendSignal(to: to, signalType: signalType, payload: payload);
      },
      onSecurePacket: (from, packet) => _handleEncryptedPacket(from, packet, transport: 'p2p'),
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

    _contacts.removeWhere((item) => item.userId == contact.userId);
    _contacts.add(contact);
    _contacts.sort((a, b) => a.displayName.compareTo(b.displayName));
    await _store.saveContacts(_contacts);
    notifyListeners();
  }

  Future<void> sendText(Contact contact, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _sendPlainPayload(contact, PlainPayload.text(trimmed));
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
    final relayAwareLimit = (_relayMaxPayloadBytes * 0.45).floor();
    final effectiveLimit = relayAwareLimit < maxPlainFileBytes ? relayAwareLimit : maxPlainFileBytes;
    if (bytes.length > effectiveLimit) {
      throw StateError('Plik jest za duzy. Limit: ${effectiveLimit ~/ (1024 * 1024)} MB.');
    }

    await _sendPlainPayload(
      contact,
      PlainPayload.file(
        fileName: file.name,
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
    _relaySettings = null;
    _relay = null;
    _p2p = null;
    _contacts.clear();
    _messages.clear();
    _sessions.clear();
    _pendingSessions.clear();
    _relayEnvelopeToMessage.clear();
    _p2pConnected.clear();
    _relayConnected = false;
    _setStatus('Wyczyszczono lokalne dane.');
  }

  Future<void> _sendPlainPayload(Contact contact, PlainPayload payload) async {
    final identity = _requireIdentity();
    final relay = _requireRelay();
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

    final sentP2p = await _p2p?.sendEncryptedPacket(contact.userId, packet.toJson()) ?? false;
    if (sentP2p) {
      _updateMessage(contact.userId, packet.messageId, MessageStatus.sent, transport: 'p2p');
      return;
    }

    final relayEnvelopeId = relay.sendRelay(
      to: contact.userId,
      payload: packet.toJson(),
    );
    _relayEnvelopeToMessage[relayEnvelopeId] = packet.messageId;
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
    final init = await _crypto.createHandshakeInit(identity: identity, contact: contact);
    _pendingSessions[contact.userId] = init.pendingSession;
    relay.sendSignal(
      to: contact.userId,
      signalType: 'crypto-handshake-init',
      payload: init.wirePayload,
    );
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
        _relay?.queryPresence(_contacts.map((contact) => contact.userId).toList());
        break;
      case RelayDeliver():
        if (event.kind == 'signal') {
          await _handleSignal(event);
        } else if (event.kind == 'relay') {
          await _handleEncryptedPacket(event.from, event.payload, transport: 'relay');
        }
        break;
      case RelaySent():
        final messageId = _relayEnvelopeToMessage.remove(event.id);
        if (messageId != null) {
          _updateMessage(
            event.to,
            messageId,
            event.deliveredConnections > 0 ? MessageStatus.sent : MessageStatus.failed,
            transport: 'relay',
            error: event.deliveredConnections > 0 ? null : 'Kontakt offline.',
          );
        }
        break;
      case RelayPresence():
        break;
      case RelayProblem():
        _relayConnected = false;
        _setStatus(event.message);
        break;
    }
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
        final accept = await _crypto.acceptHandshakeInit(
          identity: identity,
          contact: contact,
          wirePayload: event.payload,
        );
        _sessions[contact.userId] = accept.session;
        _requireRelay().sendSignal(
          to: contact.userId,
          signalType: 'crypto-handshake-accept',
          payload: accept.wirePayload,
        );
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
      _addMessage(
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

  void _addMessage(ChatMessage message) {
    final list = _messages.putIfAbsent(message.contactId, () => <ChatMessage>[]);
    if (list.any((item) => item.id == message.id)) return;
    list.add(message);
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    notifyListeners();
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
    list[index] = list[index].copyWith(status: status, transport: transport, error: error);
    notifyListeners();
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

  @override
  void dispose() {
    unawaited(_relaySubscription?.cancel());
    unawaited(_relay?.dispose());
    unawaited(_p2p?.dispose());
    super.dispose();
  }
}
