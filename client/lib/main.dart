import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/services/desktop_notifier.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DesktopNotifier.instance.initialize();
  runApp(const SecureMessengerApp());
}
