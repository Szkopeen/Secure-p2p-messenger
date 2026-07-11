import 'package:flutter/material.dart';

import 'app_state.dart';
import 'screens/home_screen.dart';
import 'screens/setup_screen.dart';

class SecureMessengerApp extends StatefulWidget {
  const SecureMessengerApp({super.key});

  @override
  State<SecureMessengerApp> createState() => _SecureMessengerAppState();
}

class _SecureMessengerAppState extends State<SecureMessengerApp> {
  late final AppState appState;

  @override
  void initState() {
    super.initState();
    appState = AppState();
    appState.initialize();
  }

  @override
  void dispose() {
    appState.dispose();
    super.dispose();
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
