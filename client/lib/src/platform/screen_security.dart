import 'package:flutter/services.dart';

class ScreenSecurity {
  const ScreenSecurity._();

  static const _channel = MethodChannel('szkpn.messenger/screen_security');

  static Future<void> setSecureScreen(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setSecureScreen', enabled);
    } on MissingPluginException {
      // Desktop platforms do not expose this channel.
    }
  }
}
