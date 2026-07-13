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

class _SecureMessengerAppState extends State<SecureMessengerApp>
    with WidgetsBindingObserver {
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
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff38bdf8),
      brightness: Brightness.dark,
      surface: const Color(0xff0b1016),
      surfaceContainerLowest: const Color(0xff070b10),
      surfaceContainerLow: const Color(0xff101820),
      surfaceContainer: const Color(0xff141d26),
      surfaceContainerHigh: const Color(0xff1a2530),
      surfaceContainerHighest: const Color(0xff22303c),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Secure Chat',
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        colorScheme: darkScheme,
        scaffoldBackgroundColor: darkScheme.surface,
        canvasColor: darkScheme.surface,
        useMaterial3: true,
        appBarTheme: AppBarTheme(
          backgroundColor: darkScheme.surfaceContainerLow,
          foregroundColor: darkScheme.onSurface,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: darkScheme.surfaceContainerHigh,
          surfaceTintColor: Colors.transparent,
        ),
        bottomSheetTheme: BottomSheetThemeData(
          backgroundColor: darkScheme.surfaceContainerHigh,
          surfaceTintColor: Colors.transparent,
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: const OutlineInputBorder(),
          filled: true,
          fillColor: darkScheme.surfaceContainerLow,
        ),
        listTileTheme: ListTileThemeData(
          iconColor: darkScheme.onSurfaceVariant,
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: darkScheme.inverseSurface,
          contentTextStyle: TextStyle(color: darkScheme.onInverseSurface),
        ),
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
          if (!appState.hasAccount) {
            return SetupScreen(appState: appState);
          }
          return HomeScreen(appState: appState);
        },
      ),
    );
  }
}
