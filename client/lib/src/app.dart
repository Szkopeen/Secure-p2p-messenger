import 'package:flutter/material.dart';

import 'app_state.dart';
import 'screens/home_screen.dart';
import 'screens/setup_screen.dart';
import 'services/desktop_notifier.dart';

class SecureMessengerApp extends StatefulWidget {
  const SecureMessengerApp({super.key});

  @override
  State<SecureMessengerApp> createState() => _SecureMessengerAppState();
}

class _SecureMessengerAppState extends State<SecureMessengerApp> with WidgetsBindingObserver {
  late final AppState appState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    DesktopNotifier.instance.setAppActive(true);
    appState = AppState();
    appState.initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appState.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    DesktopNotifier.instance.setAppActive(active);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Secure P2P',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff1f7a5a),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
        visualDensity: VisualDensity.standard,
      ),
      home: AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          if (appState.initializing) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (!appState.hasIdentity || appState.relaySettings == null) {
            return SetupScreen(appState: appState);
          }
          return HomeScreen(appState: appState);
        },
      ),
    );
  }
}
