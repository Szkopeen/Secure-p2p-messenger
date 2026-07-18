import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:local_notifier/local_notifier.dart';

import '../models/message.dart';

class DesktopNotifier {
  DesktopNotifier._();

  static final DesktopNotifier instance = DesktopNotifier._();

  final AudioPlayer _player = AudioPlayer();
  final Map<String, _PendingNotification> _pending = {};
  bool _ready = false;
  bool _appActive = true;

  Future<void> initialize() async {
    if (_ready) return;
    try {
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        await localNotifier.setup(
          appName: 'szkpn.messenger',
          shortcutPolicy: ShortcutPolicy.requireCreate,
        );
      }
    } catch (_) {
      // Brak systemowych powiadomien nie moze zatrzymac aplikacji.
    }
    _ready = true;
  }

  void setAppActive(bool active) {
    _appActive = active;
    if (active) {
      for (final pending in _pending.values) {
        pending.timer?.cancel();
      }
      _pending.clear();
    }
  }

  Future<void> notifyIncoming({
    required String senderName,
    required PlainPayload payload,
  }) async {
    if (_appActive) return;
    if (!_ready ||
        !(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }

    final pending = _pending.putIfAbsent(
      senderName,
      () => _PendingNotification(senderName: senderName),
    );
    pending.count += 1;
    pending.lastPayload = payload;
    pending.timer?.cancel();
    pending.timer = Timer(
      const Duration(milliseconds: 1400),
      () => unawaited(_flush(senderName)),
    );
  }

  Future<void> _flush(String senderName) async {
    final pending = _pending.remove(senderName);
    if (pending == null || pending.count == 0 || pending.lastPayload == null) {
      return;
    }
    if (_appActive) return;

    await _playSound();
    await _showNotification(
      senderName: pending.senderName,
      payload: pending.lastPayload!,
      count: pending.count,
    );
  }

  Future<void> _playSound() async {
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/notification.mp3'));
    } catch (_) {
      // Dzwiek jest dodatkiem, nie powinien blokowac odbioru wiadomosci.
    }
  }

  Future<void> _showNotification({
    required String senderName,
    required PlainPayload payload,
    required int count,
  }) async {
    if (!_ready ||
        !(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }

    try {
      final notification = LocalNotification(
        title: count == 1
            ? 'Nowa wiadomosc od $senderName'
            : '$count nowych wiadomosci od $senderName',
        body: count == 1 ? _preview(payload) : 'Ostatnia: ${_preview(payload)}',
      );
      notification.show();
    } catch (_) {
      // Powiadomienia zaleza od ustawien systemu. Aplikacja ma dzialac dalej.
    }
  }

  String _preview(PlainPayload payload) {
    return switch (payload.type) {
      PlainPayloadType.text => _trim(payload.text ?? ''),
      PlainPayloadType.file => 'Plik: ${payload.fileName ?? 'zalacznik'}',
      PlainPayloadType.retraction => 'Wiadomosc zostala usunieta.',
      PlainPayloadType.reaction => 'Reakcja na wiadomosc.',
      PlainPayloadType.pin => 'Przypieto wiadomosc.',
      PlainPayloadType.receipt => 'Potwierdzenie wiadomosci.',
      PlainPayloadType.edit => 'Edytowano wiadomosc.',
    };
  }

  String _trim(String value) {
    final singleLine = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (singleLine.length <= 120) return singleLine;
    return '${singleLine.substring(0, 117)}...';
  }
}

class _PendingNotification {
  _PendingNotification({required this.senderName});

  final String senderName;
  int count = 0;
  PlainPayload? lastPayload;
  Timer? timer;
}
