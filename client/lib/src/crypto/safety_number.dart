import 'package:crypto/crypto.dart' as crypto_hash;

import 'codec.dart';

class SafetyNumber {
  const SafetyNumber._();

  static String calculate({
    required String ownUserId,
    required String ownIdentityPublicKey,
    required String contactUserId,
    required String contactIdentityPublicKey,
  }) {
    if (ownUserId.isEmpty ||
        ownIdentityPublicKey.isEmpty ||
        contactUserId.isEmpty ||
        contactIdentityPublicKey.isEmpty) {
      return '';
    }

    final participants = [
      {
        'userId': ownUserId,
        'identityPublicKey': ownIdentityPublicKey,
      },
      {
        'userId': contactUserId,
        'identityPublicKey': contactIdentityPublicKey,
      },
    ]..sort((a, b) {
        final userCompare = a['userId']!.compareTo(b['userId']!);
        if (userCompare != 0) return userCompare;
        return a['identityPublicKey']!.compareTo(b['identityPublicKey']!);
      });

    final digest = crypto_hash.sha256
        .convert(canonicalJsonBytes({
          'v': 1,
          'protocol': 'secure-p2p-safety-number/v1',
          'participants': participants,
        }))
        .toString();

    return RegExp('.{1,5}')
        .allMatches(digest.substring(0, 40))
        .map((match) => match.group(0)!)
        .join(' ');
  }
}
