import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../crypto/codec.dart';
import '../models/directory_entry.dart';
import '../models/identity.dart';
import '../models/user_profile.dart';

abstract class RelayEvent {
  const RelayEvent();
}

class RelayReady extends RelayEvent {
  const RelayReady({
    required this.connectionId,
    required this.maxPayloadBytes,
  });

  final String connectionId;
  final int maxPayloadBytes;
}

class RelayDeliver extends RelayEvent {
  const RelayDeliver({
    required this.id,
    required this.kind,
    required this.from,
    required this.to,
    required this.payload,
    required this.sentAt,
    this.signalType,
  });

  final String id;
  final String kind;
  final String from;
  final String to;
  final String? signalType;
  final Map<String, dynamic> payload;
  final DateTime sentAt;
}

class RelaySent extends RelayEvent {
  const RelaySent({
    required this.id,
    required this.to,
    required this.transport,
    required this.deliveredConnections,
    this.queued = false,
  });

  final String id;
  final String to;
  final String transport;
  final int deliveredConnections;
  final bool queued;
}

class RelayPresence extends RelayEvent {
  const RelayPresence(this.contacts);

  final Map<String, bool> contacts;
}

class RelayProblem extends RelayEvent {
  const RelayProblem(this.message, {this.code});

  final String message;
  final String? code;
}

class RelayProfile extends RelayEvent {
  const RelayProfile({
    required this.userId,
    required this.profile,
  });

  final String userId;
  final UserProfile profile;
}

class RelayDirectory extends RelayEvent {
  const RelayDirectory(this.entries);

  final List<DirectoryEntry> entries;
}

class RelayContactRequest extends RelayEvent {
  const RelayContactRequest({
    required this.id,
    required this.from,
    required this.displayName,
    required this.identityPublicKey,
    required this.sentAt,
  });

  final String id;
  final String from;
  final String displayName;
  final String identityPublicKey;
  final DateTime sentAt;
}

class RelayClient {
  RelayClient({
    required this.settings,
    required this.identity,
  });

  final RelaySettings settings;
  final IdentityKeyMaterial identity;
  final Uuid _uuid = const Uuid();
  final StreamController<RelayEvent> _events =
      StreamController<RelayEvent>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _pingTimer;

  Stream<RelayEvent> get events => _events.stream;

  Future<void> connect() async {
    final uri = Uri.parse(settings.serverUrl);
    if (uri.scheme != 'ws' && uri.scheme != 'wss') {
      throw ArgumentError(
          'Adres relay musi zaczynac sie od ws:// albo wss://.');
    }

    _channel = WebSocketChannel.connect(uri);
    _subscription = _channel!.stream.listen(
      _handleRawMessage,
      onError: (Object error) =>
          _events.add(RelayProblem('Blad polaczenia: $error')),
      onDone: () => _events
          .add(const RelayProblem('Polaczenie z relay zostalo zamkniete.')),
    );

    _send({
      'v': 1,
      'type': 'hello',
      'userId': identity.userId,
      'deviceId': identity.deviceId,
      'identityPublicKey': b64(identity.publicKey.bytes),
      'relayToken': settings.relayToken,
    });

    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      _send({'v': 1, 'type': 'ping'});
    });
  }

  Future<void> disconnect() async {
    _pingTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
  }

  Future<void> dispose() async {
    await disconnect();
    await _events.close();
  }

  String sendSignal({
    required String to,
    required String signalType,
    required Map<String, dynamic> payload,
  }) {
    final id = _uuid.v4();
    _send({
      'v': 1,
      'type': 'signal',
      'id': id,
      'to': to,
      'signalType': signalType,
      'payload': payload,
    });
    return id;
  }

  String sendRelay({
    required String to,
    required Map<String, dynamic> payload,
  }) {
    final id = _uuid.v4();
    _send({
      'v': 1,
      'type': 'relay',
      'id': id,
      'to': to,
      'payload': payload,
    });
    return id;
  }

  String sendContactRequest({
    required String to,
    required String displayName,
  }) {
    final id = _uuid.v4();
    _send({
      'v': 1,
      'type': 'contact_request',
      'id': id,
      'to': to,
      'displayName': displayName,
    });
    return id;
  }

  void queryPresence(List<String> contacts) {
    _send({
      'v': 1,
      'type': 'presence_query',
      'contacts': contacts,
    });
  }

  void updateDirectory({
    required bool enabled,
    required String displayName,
  }) {
    _send({
      'v': 1,
      'type': 'directory_update',
      'enabled': enabled,
      'displayName': displayName,
      'identityPublicKey': b64(identity.publicKey.bytes),
    });
  }

  void queryDirectory() {
    _send({
      'v': 1,
      'type': 'directory_query',
    });
  }

  void queryProfiles(List<String> contacts) {
    _send({
      'v': 1,
      'type': 'profile_query',
      'contacts': contacts,
    });
  }

  void updateProfile(UserProfile profile) {
    _send({
      'v': 1,
      'type': 'profile_update',
      'profile': profile.toJson(),
    });
  }

  void _send(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null) {
      throw StateError('Relay nie jest polaczony.');
    }
    channel.sink.add(jsonEncode(message));
  }

  void _handleRawMessage(dynamic raw) {
    try {
      final decoded = jsonDecode(raw as String);
      final message = asStringKeyMap(decoded, 'relayMessage');
      switch (message['type']) {
        case 'hello_ok':
          _events.add(
            RelayReady(
              connectionId: requiredString(message, 'connectionId'),
              maxPayloadBytes: requiredInt(message, 'maxPayloadBytes'),
            ),
          );
          break;
        case 'deliver':
          final kind = requiredString(message, 'kind');
          if (kind == 'contact_request') {
            final payload = asStringKeyMap(message['payload'], 'payload');
            _events.add(
              RelayContactRequest(
                id: requiredString(message, 'id'),
                from: requiredString(message, 'from'),
                displayName: payload['displayName'] as String? ??
                    requiredString(message, 'from'),
                identityPublicKey: requiredString(payload, 'identityPublicKey'),
                sentAt: DateTime.parse(requiredString(message, 'sentAt')),
              ),
            );
            break;
          }
          _events.add(
            RelayDeliver(
              id: requiredString(message, 'id'),
              kind: kind,
              from: requiredString(message, 'from'),
              to: requiredString(message, 'to'),
              signalType: message['signalType'] as String?,
              payload: asStringKeyMap(message['payload'], 'payload'),
              sentAt: DateTime.parse(requiredString(message, 'sentAt')),
            ),
          );
          break;
        case 'directory':
          final entries = (message['entries'] as List? ?? const [])
              .map((item) =>
                  DirectoryEntry.fromJson((item as Map).cast<String, dynamic>()))
              .toList(growable: false);
          _events.add(RelayDirectory(entries));
          break;
        case 'directory_updated':
          break;
        case 'sent':
          _events.add(
            RelaySent(
              id: requiredString(message, 'id'),
              to: requiredString(message, 'to'),
              transport: requiredString(message, 'transport'),
              deliveredConnections:
                  requiredInt(message, 'deliveredConnections'),
              queued: message['queued'] == true,
            ),
          );
          break;
        case 'presence':
          final contacts = asStringKeyMap(message['contacts'], 'contacts');
          _events.add(
            RelayPresence(
              contacts.map((key, value) => MapEntry(key, value == true)),
            ),
          );
          break;
        case 'profile':
          _events.add(
            RelayProfile(
              userId: requiredString(message, 'userId'),
              profile: UserProfile.fromJson(
                asStringKeyMap(message['profile'], 'profile'),
              ),
            ),
          );
          break;
        case 'profiles':
          final profiles = asStringKeyMap(message['profiles'], 'profiles');
          for (final entry in profiles.entries) {
            _events.add(
              RelayProfile(
                userId: entry.key,
                profile: UserProfile.fromJson(
                  asStringKeyMap(entry.value, 'profile'),
                ),
              ),
            );
          }
          break;
        case 'pong':
          break;
        case 'error':
          _events.add(
            RelayProblem(
              message['reason'] as String? ?? 'Blad relay.',
              code: message['code'] as String?,
            ),
          );
          break;
        default:
          _events.add(const RelayProblem('Nieznany pakiet relay.'));
      }
    } catch (error) {
      _events.add(RelayProblem('Nie mozna przetworzyc pakietu relay: $error'));
    }
  }
}
