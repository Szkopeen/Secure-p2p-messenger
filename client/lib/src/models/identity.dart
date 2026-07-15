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
  const RelaySettings({required this.serverUrl});

  final String serverUrl;

  Map<String, dynamic> toJson() => {'serverUrl': serverUrl};

  factory RelaySettings.fromJson(Map<String, dynamic> json) {
    return RelaySettings(serverUrl: json['serverUrl'] as String);
  }
}

class AdminSettings {
  const AdminSettings({required this.serverUrl, required this.adminToken});

  final String serverUrl;
  final String adminToken;

  Map<String, dynamic> toJson() => {
        'serverUrl': serverUrl,
        'adminToken': adminToken,
      };

  factory AdminSettings.fromJson(Map<String, dynamic> json) {
    return AdminSettings(
      serverUrl: json['serverUrl'] as String,
      adminToken: json['adminToken'] as String,
    );
  }
}
