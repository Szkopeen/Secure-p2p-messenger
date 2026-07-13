import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';

import '../crypto/codec.dart';
import '../models/message.dart';
import 'secure_store.dart';

class MessageArchive {
  MessageArchive({
    required SecureStore secureStore,
  }) : _secureStore = secureStore;

  static const _aad = 'secure-p2p-local-message-archive/v1';

  final SecureStore _secureStore;
  final AesGcm _aead = AesGcm.with256bits();

  Future<List<ChatMessage>> load() async {
    final file = await _archiveFile();
    if (!await file.exists()) return [];

    try {
      final encrypted =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final key = await _archiveSecretKey();
      final box = SecretBox(
        unb64(encrypted['ciphertext'] as String),
        nonce: unb64(encrypted['nonce'] as String),
        mac: Mac(unb64(encrypted['mac'] as String)),
      );
      final clearBytes = await _aead.decrypt(
        box,
        secretKey: key,
        aad: utf8Bytes(_aad),
      );
      final decoded =
          jsonDecode(utf8.decode(clearBytes)) as Map<String, dynamic>;
      final items = decoded['messages'] as List<dynamic>? ?? const [];
      return items
          .map((item) =>
              ChatMessage.fromJson((item as Map).cast<String, dynamic>()))
          .toList(growable: false);
    } catch (_) {
      // Przy zmianie klucza albo uszkodzeniu pliku nie pokazujemy plaintextu ani stack trace.
      return [];
    }
  }

  Future<void> save(Iterable<ChatMessage> messages) async {
    final file = await _archiveFile();
    await file.parent.create(recursive: true);

    final clearJson = jsonEncode({
      'v': 1,
      'savedAt': DateTime.now().toUtc().toIso8601String(),
      'messages': messages.map((message) => message.toJson()).toList(),
    });
    final nonce = secureRandomBytes(12);
    final box = await _aead.encrypt(
      utf8Bytes(clearJson),
      secretKey: await _archiveSecretKey(),
      nonce: nonce,
      aad: utf8Bytes(_aad),
    );

    await file.writeAsString(
      jsonEncode({
        'v': 1,
        'algorithm': 'AES-256-GCM',
        'nonce': b64(box.nonce),
        'ciphertext': b64(box.cipherText),
        'mac': b64(box.mac.bytes),
      }),
      flush: true,
    );
  }

  Future<void> delete() async {
    final file = await _archiveFile();
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<SecretKey> _archiveSecretKey() async {
    final existing = await _secureStore.loadLocalArchiveKey();
    if (existing != null && existing.isNotEmpty) {
      return SecretKey(unb64(existing));
    }

    final keyBytes = secureRandomBytes(32);
    await _secureStore.saveLocalArchiveKey(b64(keyBytes));
    return SecretKey(keyBytes);
  }

  Future<File> _archiveFile() async {
    final directory = await getApplicationSupportDirectory();
    return File(
        '${directory.path}${Platform.pathSeparator}message_archive.enc.json');
  }
}
