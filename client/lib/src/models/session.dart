import 'dart:async';

import 'package:cryptography/cryptography.dart';

class SessionState {
  const SessionState({
    required this.contactId,
    required this.sessionId,
    required this.secretKey,
    required this.createdAt,
  });

  final String contactId;
  final String sessionId;
  final SecretKey secretKey;
  final DateTime createdAt;
}

class PendingSession {
  PendingSession({
    required this.contactId,
    required this.sessionId,
    required this.ephemeralKeyPair,
    required this.ephemeralPublicKey,
    required this.createdAt,
  });

  final String contactId;
  final String sessionId;
  final SimpleKeyPair ephemeralKeyPair;
  final String ephemeralPublicKey;
  final DateTime createdAt;
  final completer = Completer<SessionState>();
}
