import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({required this.appState, super.key});

  final AppState appState;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _cloudFormKey = GlobalKey<FormState>();
  final _cloudServerUrl = TextEditingController(text: 'https://chat.szkpn.pl');
  final _cloudUsername = TextEditingController();
  final _cloudPassword = TextEditingController();
  final _userId = TextEditingController();
  final _serverUrl = TextEditingController(text: 'ws://127.0.0.1:8443');
  final _relayToken = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _cloudServerUrl.dispose();
    _cloudUsername.dispose();
    _cloudPassword.dispose();
    _userId.dispose();
    _serverUrl.dispose();
    _relayToken.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Konfiguracja')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: ListView(
                shrinkWrap: true,
                children: [
                  Form(
                    key: _cloudFormKey,
                    child: Column(
                      children: [
                        TextFormField(
                          controller: _cloudServerUrl,
                          decoration: const InputDecoration(
                            labelText: 'Adres serwera',
                            prefixIcon: Icon(Icons.cloud_outlined),
                          ),
                          validator: (value) {
                            final text = (value ?? '').trim();
                            if (text.isEmpty) return 'Podaj adres serwera';
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _cloudUsername,
                          decoration: const InputDecoration(
                            labelText: 'Login',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                          validator: (value) {
                            if ((value ?? '').trim().length < 3) {
                              return 'Minimum 3 znaki';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _cloudPassword,
                          decoration: const InputDecoration(
                            labelText: 'Haslo',
                            prefixIcon: Icon(Icons.password_outlined),
                          ),
                          obscureText: true,
                          validator: (value) {
                            if ((value ?? '').length < 8) {
                              return 'Minimum 8 znakow';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _saving ? null : _loginCloud,
                                icon: const Icon(Icons.login),
                                label: const Text('Zaloguj'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _saving ? null : _registerCloud,
                                icon: const Icon(Icons.person_add_alt_1),
                                label: const Text('Utworz konto'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 16),
                  ExpansionTile(
                    title: const Text('Stary tryb P2P / relay'),
                    children: [
                      TextFormField(
                        controller: _userId,
                        decoration: const InputDecoration(
                          labelText: 'Twoj identyfikator',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        validator: (value) {
                          if ((value ?? '').trim().length < 3) {
                            return 'Minimum 3 znaki';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _serverUrl,
                        decoration: const InputDecoration(
                          labelText: 'Adres relay',
                          prefixIcon: Icon(Icons.dns_outlined),
                        ),
                        validator: (value) {
                          final text = (value ?? '').trim();
                          if (!text.startsWith('ws://') &&
                              !text.startsWith('wss://')) {
                            return 'Uzyj ws:// albo wss://';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _relayToken,
                        decoration: const InputDecoration(
                          labelText: 'Token relay',
                          prefixIcon: Icon(Icons.key_outlined),
                        ),
                        obscureText: true,
                        validator: (value) {
                          if ((value ?? '').trim().length < 32) {
                            return 'Minimum 32 znaki';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _saving ? null : _save,
                        icon: const Icon(Icons.lock_outline),
                        label: const Text('Utworz tozsamosc legacy'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _saving ? null : _importAccount,
                        icon: const Icon(Icons.devices_other_outlined),
                        label: const Text('Importuj konto z pliku'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _ChatControlPanel(onCopy: _copyUrl),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.appState.createIdentityAndConnect(
        userId: _userId.text,
        serverUrl: _serverUrl.text,
        relayToken: _relayToken.text,
      );
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _loginCloud() async {
    if (!_cloudFormKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.appState.loginCloudAccount(
        serverUrl: _cloudServerUrl.text,
        username: _cloudUsername.text,
        password: _cloudPassword.text,
      );
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _registerCloud() async {
    if (!_cloudFormKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.appState.registerCloudAccount(
        serverUrl: _cloudServerUrl.text,
        username: _cloudUsername.text,
        password: _cloudPassword.text,
      );
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _importAccount() async {
    final passphrase = await _askImportPassphrase();
    if (passphrase == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.appState.importAccountPackageFromFile(passphrase);
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<String?> _askImportPassphrase() async {
    final controller = TextEditingController();
    String? error;
    final result = await showDialog<String?>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Import konta'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: controller,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Haslo do pakietu konta',
                      ),
                    ),
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
                    final value = controller.text.trim();
                    final validationError =
                        AppState.accountTransferPassphraseError(value);
                    if (validationError != null) {
                      setState(() => error = validationError);
                      return;
                    }
                    Navigator.of(context).pop(value);
                  },
                  child: const Text('Importuj'),
                ),
              ],
            );
          },
        );
      },
    );
    controller.dispose();
    return result;
  }

  Future<void> _copyUrl(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Skopiowano link.')),
    );
  }
}

class _ChatControlPanel extends StatelessWidget {
  const _ChatControlPanel({required this.onCopy});

  final ValueChanged<String> onCopy;

  static const _mullvadUrl = 'https://mullvad.net/en/chatcontrol';
  static const _breyerUrl =
      'https://www.patrick-breyer.de/en/posts/chat-control/';

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.policy_outlined,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Text(
                  'Chat Control - status prawny',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Stan na 12.07.2026: zrodla wskazuja, ze Chat Control 1.0 wygaslo 04.04.2026, a Chat Control 2.0 pozostaje tematem negocjacji UE. To nie jest porada prawna; sprawdz aktualny status w linkach.',
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => onCopy(_mullvadUrl),
                  icon: const Icon(Icons.copy),
                  label: const Text('Kopiuj Mullvad'),
                ),
                OutlinedButton.icon(
                  onPressed: () => onCopy(_breyerUrl),
                  icon: const Icon(Icons.copy),
                  label: const Text('Kopiuj Breyer'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const SelectableText('Mullvad: $_mullvadUrl'),
            const SelectableText('Patrick Breyer: $_breyerUrl'),
          ],
        ),
      ),
    );
  }
}
