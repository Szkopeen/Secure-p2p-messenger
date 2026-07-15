import '../models/message.dart';
import 'secure_store.dart';

class MessageArchive {
  MessageArchive({required SecureStore secureStore});

  Future<List<ChatMessage>> load() async => [];

  Future<void> save(Iterable<ChatMessage> messages) async {}

  Future<void> delete() async {}
}
