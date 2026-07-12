import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({required this.appState, super.key});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final publicKey = appState.ownPublicKey ?? '';
        final relayUrl = appState.relaySettings?.serverUrl ?? 'Brak';
        return Scaffold(
          appBar: AppBar(
            title: const Text('Ustawienia'),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _SettingsSection(
                title: 'Konto',
                children: [
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: const Text('Identyfikator'),
                    subtitle: Text(appState.ownUserId ?? 'Brak'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.vpn_key_outlined),
                    title: const Text('Klucz publiczny'),
                    subtitle: SelectableText(
                      publicKey,
                      maxLines: 2,
                    ),
                    trailing: IconButton(
                      tooltip: 'Kopiuj',
                      onPressed: publicKey.isEmpty
                          ? null
                          : () => Clipboard.setData(
                                ClipboardData(text: publicKey),
                              ),
                      icon: const Icon(Icons.copy),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _SettingsSection(
                title: 'Profil',
                children: [
                  ListTile(
                    leading: const Icon(Icons.photo_camera_outlined),
                    title: const Text('Ustaw profilowe'),
                    subtitle: const Text('Limit obrazu: 1 MB'),
                    onTap: () => _setProfileImage(context),
                  ),
                  if (appState.ownProfile?.hasAvatar == true)
                    ListTile(
                      leading: const Icon(Icons.no_photography_outlined),
                      title: const Text('Usun profilowe'),
                      onTap: () => _clearProfileImage(context),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              _SettingsSection(
                title: 'Relay',
                children: [
                  ListTile(
                    leading: Icon(
                      appState.relayConnected
                          ? Icons.cloud_done_outlined
                          : Icons.cloud_off_outlined,
                    ),
                    title: Text(
                      appState.relayConnected ? 'Polaczony' : 'Rozlaczony',
                    ),
                    subtitle: Text(relayUrl),
                    trailing: IconButton(
                      tooltip: 'Polacz ponownie',
                      onPressed: () => appState.connectRelay(),
                      icon: const Icon(Icons.refresh),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _SettingsSection(
                title: 'Prywatnosc i dane',
                children: [
                  const ListTile(
                    leading: Icon(Icons.lock_outline),
                    title: Text('Historia lokalna'),
                    subtitle: Text(
                        'Wiadomosci sa zapisane lokalnie w szyfrowanym archiwum.'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.delete_forever_outlined),
                    title: const Text('Wyczysc dane lokalne'),
                    subtitle: const Text(
                        'Usuwa konto, kontakty, sesje i historie z tego urzadzenia.'),
                    onTap: () => _confirmWipe(context),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _setProfileImage(BuildContext context) async {
    try {
      await appState.setProfileImage();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  Future<void> _clearProfileImage(BuildContext context) async {
    try {
      await appState.clearProfileImage();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  Future<void> _confirmWipe(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Wyczysc dane lokalne'),
          content: const Text(
            'To usunie lokalna tozsamosc, kontakty, sesje i historie rozmow z tego urzadzenia.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Wyczysc'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    await appState.wipeLocalData();
    if (!context.mounted) return;
    Navigator.of(context).pop();
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}
