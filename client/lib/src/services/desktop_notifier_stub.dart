import '../models/message.dart';

class DesktopNotifier {
  DesktopNotifier._();

  static final DesktopNotifier instance = DesktopNotifier._();

  Future<void> initialize() async {}

  void setAppActive(bool active) {}

  Future<void> notifyIncoming({
    required String senderName,
    required PlainPayload payload,
  }) async {}
}
