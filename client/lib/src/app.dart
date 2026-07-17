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
    appState = AppState();
    WidgetsBinding.instance.addObserver(this);
    DesktopNotifier.instance.setAppActive(true);
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
    appState.handleLifecycleState(state.name);
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
          late final Widget screen;
          if (appState.initializing) {
            screen = const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          } else if (!appState.hasAccount) {
            screen = SetupScreen(appState: appState);
          } else {
            screen = HomeScreen(appState: appState);
          }
          return Stack(
            children: [
              screen,
              if (appState.privacyLocked)
                _PrivacyLockScreen(appState: appState),
            ],
          );
        },
      ),
    );
  }
}

class _PrivacyLockScreen extends StatefulWidget {
  const _PrivacyLockScreen({required this.appState});

  final AppState appState;

  @override
  State<_PrivacyLockScreen> createState() => _PrivacyLockScreenState();
}

class _PrivacyLockScreenState extends State<_PrivacyLockScreen> {
  final TextEditingController _pinController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    try {
      await widget.appState.unlockPrivacy(_pinController.text);
      if (!mounted) return;
      _pinController.clear();
      setState(() => _error = null);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final requiresPin = widget.appState.appLockEnabled;
    return Positioned.fill(
      child: ColoredBox(
        color: colorScheme.surface,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 48,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Aplikacja zablokowana',
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    if (requiresPin) ...[
                      TextField(
                        controller: _pinController,
                        autofocus: true,
                        obscureText: true,
                        keyboardType: TextInputType.number,
                        maxLength: 12,
                        decoration: InputDecoration(
                          labelText: 'PIN',
                          errorText: _error,
                          counterText: '',
                        ),
                        onSubmitted: (_) => _unlock(),
                      ),
                      const SizedBox(height: 12),
                    ] else if (_error != null) ...[
                      Text(
                        _error!,
                        style: TextStyle(color: colorScheme.error),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                    ],
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _unlock,
                        icon: const Icon(Icons.lock_open_outlined),
                        label: const Text('Odblokuj'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
