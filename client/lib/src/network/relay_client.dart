import 'dart:async';

import '../models/directory_entry.dart';
import '../models/identity.dart';
import '../models/user_profile.dart';

abstract class RelayEvent {
  const RelayEvent();
}

class RelayReady extends RelayEvent {
  const RelayReady({required this.connectionId, required this.maxPayloadBytes});

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
  const RelayProfile({required this.userId, required this.profile});

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
  RelayClient({required this.settings, required this.identity});

  final RelaySettings settings;
  final IdentityKeyMaterial identity;
  final StreamController<RelayEvent> _events =
      StreamController<RelayEvent>.broadcast();

  Stream<RelayEvent> get events => _events.stream;

  Future<void> connect() async {
    throw UnsupportedError(
        'Stary tryb relay zostal usuniety. Uzyj konta cloud.');
  }

  Future<void> disconnect() async {}

  Future<void> dispose() async {
    await _events.close();
  }

  String sendSignal({
    required String to,
    required String signalType,
    required Map<String, dynamic> payload,
  }) {
    throw UnsupportedError('Stary tryb relay zostal usuniety.');
  }

  String sendRelay(
      {required String to, required Map<String, dynamic> payload}) {
    throw UnsupportedError('Stary tryb relay zostal usuniety.');
  }

  String sendContactRequest({required String to, required String displayName}) {
    throw UnsupportedError('Stary tryb relay zostal usuniety.');
  }

  void queryPresence(List<String> contacts) {}

  void updateDirectory({required bool enabled, required String displayName}) {}

  void queryDirectory() {}

  void queryProfiles(List<String> contacts) {}

  void updateProfile(UserProfile profile) {}
}
