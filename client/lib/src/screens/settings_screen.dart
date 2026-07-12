import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import 'admin_panel_screen.dart';

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
                title: 'Administracja',
                children: [
                  ListTile(
                    leading: const Icon(Icons.admin_panel_settings_outlined),
                    title: const Text('Panel administratora'),
                    subtitle: const Text(
                        'Lista uzytkownikow, blokady i usuwanie danych relay'),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => AdminPanelScreen(
                          relaySettings: appState.relaySettings,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _SettingsSection(
                title: 'Aktualizacje',
                children: [
                  ListTile(
                    leading: const Icon(Icons.system_update_outlined),
                    title: const Text('Aktualna wersja'),
                    subtitle: Text(
                      appState.currentVersionLabel.isEmpty
                          ? 'Wczytywanie...'
                          : appState.currentVersionLabel,
                    ),
                    trailing: IconButton(
                      tooltip: 'Sprawdz aktualizacje',
                      onPressed:
                          appState.checkingForUpdate ? null : _checkForUpdate,
                      icon: appState.checkingForUpdate
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                    ),
                  ),
                  if (appState.availableUpdate != null) ...[
                    ListTile(
                      leading: const Icon(Icons.download_outlined),
                      title: Text(
                        'Dostepna wersja ${appState.availableUpdate!.label}',
                      ),
                      subtitle: Text(
                        '${appState.availableUpdate!.artifact.fileName}'
                        ' (${_formatBytes(appState.availableUpdate!.artifact.size)})\n'
                        '${appState.availableUpdate!.notesText}',
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: appState.downloadingUpdate
                              ? null
                              : () => _downloadUpdate(context),
                          icon: const Icon(Icons.download),
                          label: Text(
                            appState.downloadingUpdate
                                ? 'Pobieram...'
                                : 'Pobierz aktualizacje',
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (appState.downloadingUpdate) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: LinearProgressIndicator(
                        value: appState.updateDownloadProgress,
                      ),
                    ),
                  ],
                  if (appState.updateStatus != null)
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: const Text('Status'),
                      subtitle: Text(appState.updateStatus!),
                    ),
                  if (appState.downloadedUpdatePath != null)
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: const Text('Pobrany plik'),
                      subtitle: SelectableText(appState.downloadedUpdatePath!),
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
                    leading: const Icon(Icons.devices_other_outlined),
                    title: const Text('Eksportuj konto na drugie urzadzenie'),
                    subtitle: const Text(
                        'Tworzy zaszyfrowany plik z tozsamoscia, relay i kontaktami.'),
                    onTap: () => _exportAccount(context),
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

  Future<void> _checkForUpdate() async {
    await appState.checkForUpdate();
  }

  Future<void> _downloadUpdate(BuildContext context) async {
    try {
      await appState.downloadAvailableUpdate();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Aktualizacja zostala pobrana.')),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  String _formatBytes(int? bytes) {
    if (bytes == null || bytes <= 0) return 'rozmiar nieznany';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unitIndex]}';
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

  Future<void> _exportAccount(BuildContext context) async {
    final passphrase = await _askPassphrase(
      context,
      title: 'Haslo do eksportu',
      action: 'Eksportuj',
      repeat: true,
    );
    if (passphrase == null) return;
    try {
      await appState.exportAccountPackage(passphrase);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Zapisano zaszyfrowany pakiet konta.')),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  Future<String?> _askPassphrase(
    BuildContext context, {
    required String title,
    required String action,
    bool repeat = false,
  }) async {
    final first = TextEditingController();
    final second = TextEditingController();
    String? error;
    final result = await showDialog<String?>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text(title),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: first,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Haslo',
                      ),
                    ),
                    if (repeat) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: second,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Powtorz haslo',
                        ),
                      ),
                    ],
                    if (error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Anuluj'),
                ),
                FilledButton(
                  onPressed: () {
                    final value = first.text.trim();
                    final validationError =
                        AppState.accountTransferPassphraseError(value);
                    if (validationError != null) {
                      setState(() => error = validationError);
                      return;
                    }
                    if (repeat && value != second.text.trim()) {
                      setState(() => error = 'Hasla nie sa identyczne.');
                      return;
                    }
                    Navigator.of(context).pop(value);
                  },
                  child: Text(action),
                ),
              ],
            );
          },
        );
      },
    );
    first.dispose();
    second.dispose();
    return result;
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
