import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models/cloud_account.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({required this.appState, super.key});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final publicKey = appState.ownPublicKey ?? '';
        return Scaffold(
          appBar: AppBar(title: const Text('Ustawienia')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _SettingsSection(
                title: 'Konto',
                children: [
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(appState.ownDisplayName ?? 'Brak konta'),
                    subtitle: Text(appState.ownUserId ?? 'Brak UUID konta'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.vpn_key_outlined),
                    title: const Text('Klucz publiczny'),
                    subtitle: SelectableText(publicKey, maxLines: 2),
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
                  if (appState.cloudMode)
                    SwitchListTile(
                      secondary: const Icon(Icons.public_outlined),
                      title: const Text('Publiczna lista uzytkownikow'),
                      subtitle: const Text(
                        'Pozwala innym znalezc Cie bez wpisywania dokladnego loginu.',
                      ),
                      value: appState.directoryListed,
                      onChanged: (value) => _setDirectoryListed(
                        context,
                        value,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              _SettingsSection(
                title: 'Bezpieczenstwo',
                children: [
                  ListTile(
                    leading: const Icon(Icons.verified_user_outlined),
                    title: const Text('Rotuj tozsamosc'),
                    subtitle: const Text(
                      'Tworzy nowy klucz Ed25519 podpisany dotychczasowym kluczem.',
                    ),
                    onTap: appState.cloudMode
                        ? () => _confirmIdentityRotation(context)
                        : null,
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.visibility_off_outlined),
                    title: const Text('Prywatny ekran'),
                    subtitle: const Text(
                      'Blokuje zrzuty ekranu i podglad aplikacji.',
                    ),
                    value: appState.privacyScreenEnabled,
                    onChanged: (value) async {
                      await appState.setPrivacyScreenEnabled(value);
                    },
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.pin_outlined),
                    title: const Text('Blokada PIN'),
                    subtitle: const Text(
                      'Wymaga PIN-u po powrocie do aplikacji.',
                    ),
                    value: appState.appLockEnabled,
                    onChanged: (value) => value
                        ? _enableAppLock(context)
                        : _disableAppLock(context),
                  ),
                  if (appState.cloudMode) ...[
                    ListTile(
                      leading: const Icon(Icons.devices_other_outlined),
                      title: const Text('Urzadzenia konta'),
                      subtitle: Text(_deviceListLabel(appState)),
                    ),
                    ..._deviceTiles(context, appState),
                  ],
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
                      'Konto i wiadomosci sa zapisane lokalnie w szyfrowanym archiwum.',
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.delete_forever_outlined),
                    title: const Text('Wyczysc dane lokalne'),
                    subtitle: const Text(
                      'Usuwa konto, kontakty, sesje i historie z tego urzadzenia.',
                    ),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _clearProfileImage(BuildContext context) async {
    try {
      await appState.clearProfileImage();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _setDirectoryListed(BuildContext context, bool listed) async {
    try {
      await appState.setDirectoryListed(listed);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _confirmIdentityRotation(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Rotuj tozsamosc'),
          content: const Text(
            'Aplikacja utworzy nowy klucz tozsamosci i podpisze go obecnym kluczem. Kontakty z aktualna wersja zaakceptuja taka rotacje automatycznie, ale po zmianie nadal warto porownac safety number.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Rotuj'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    try {
      await appState.rotateCloudIdentity();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tozsamosc zostala zrotowana.')),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _enableAppLock(BuildContext context) async {
    final pinController = TextEditingController();
    final confirmController = TextEditingController();
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Ustaw PIN'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: pinController,
                  autofocus: true,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 12,
                  decoration: const InputDecoration(
                    labelText: 'PIN',
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: confirmController,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 12,
                  decoration: const InputDecoration(
                    labelText: 'Powtorz PIN',
                    counterText: '',
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Anuluj'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Wlacz'),
              ),
            ],
          );
        },
      );
      if (confirmed != true) return;
      await appState.enableAppLockPin(
        pinController.text,
        confirmController.text,
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      pinController.dispose();
      confirmController.dispose();
    }
  }

  Future<void> _disableAppLock(BuildContext context) async {
    final pinController = TextEditingController();
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Wylacz blokade PIN'),
            content: TextField(
              controller: pinController,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 12,
              decoration: const InputDecoration(
                labelText: 'PIN',
                counterText: '',
              ),
              onSubmitted: (_) => Navigator.of(context).pop(true),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Anuluj'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Wylacz'),
              ),
            ],
          );
        },
      );
      if (confirmed != true) return;
      await appState.disableAppLockPin(pinController.text);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      pinController.dispose();
    }
  }

  String _deviceListLabel(AppState appState) {
    final list = appState.ownCloudDeviceList;
    if (list == null) return 'Lista zostanie opublikowana po polaczeniu.';
    return 'Epoch ${list.deviceListEpoch}, aktywne: ${list.devices.length}, uniewaznione: ${list.revokedDevices.length}';
  }

  List<Widget> _deviceTiles(BuildContext context, AppState appState) {
    final list = appState.ownCloudDeviceList;
    if (list == null) return const [];
    return list.devices
        .map(
          (device) => _DeviceTile(
            device: device,
            currentDeviceId: appState.ownDeviceId,
            onRevoke: () => _confirmDeviceRevocation(context, device),
          ),
        )
        .toList(growable: false);
  }

  Future<void> _confirmDeviceRevocation(
    BuildContext context,
    CloudDeviceListEntry device,
  ) async {
    if (device.deviceId == appState.ownDeviceId) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Uniewaznij urzadzenie'),
          content: Text(
            'Urzadzenie ${device.deviceId} utraci aktywne sesje i nie bedzie moglo wysylac nowych zaakceptowanych wiadomosci. Historyczne wiadomosci pozostana widoczne.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Uniewaznij'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    try {
      await appState.revokeCloudDevice(device.deviceId);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Urzadzenie zostalo uniewaznione.')),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
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
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.currentDeviceId,
    required this.onRevoke,
  });

  final CloudDeviceListEntry device;
  final String? currentDeviceId;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final current = device.deviceId == currentDeviceId;
    return ListTile(
      leading: Icon(
        current ? Icons.laptop_mac_outlined : Icons.devices_outlined,
      ),
      title: Text(current ? 'To urzadzenie' : 'Urzadzenie'),
      subtitle: Text(
        '${device.deviceId}\nEpoch ${device.deviceEpoch}',
        maxLines: 2,
      ),
      trailing: current
          ? const Icon(Icons.check_circle_outline)
          : IconButton(
              tooltip: 'Uniewaznij',
              onPressed: onRevoke,
              icon: const Icon(Icons.block),
            ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
          ...children,
        ],
      ),
    );
  }
}
