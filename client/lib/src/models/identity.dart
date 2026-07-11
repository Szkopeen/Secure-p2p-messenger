import 'package:cryptography/cryptography.dart';

class IdentityKeyMaterial {
  const IdentityKeyMaterial({
    required this.userId,
    required this.deviceId,
    required this.keyPair,
    required this.publicKey,
  });

  final String userId;
  final String deviceId;
  final SimpleKeyPair keyPair;
  final SimplePublicKey publicKey;
}

class RelaySettings {
  const RelaySettings({
    required this.serverUrl,
    required this.relayToken,
  });

  final String serverUrl;
  final String relayToken;

  Map<String, dynamic> toJson() => {
        'serverUrl': serverUrl,
        'relayToken': relayToken,
      };

  factory RelaySettings.fromJson(Map<String, dynamic> json) {
    return RelaySettings(
      serverUrl: json['serverUrl'] as String,
      relayToken: json['relayToken'] as String,
    );
  }
}
