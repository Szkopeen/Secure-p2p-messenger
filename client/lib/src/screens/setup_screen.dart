import 'package:flutter/material.dart';

import '../app_state.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({required this.appState, super.key});

  final AppState appState;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _userId = TextEditingController();
  final _serverUrl = TextEditingController(text: 'ws://127.0.0.1:8443');
  final _relayToken = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
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
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.lock_outline),
                    label: const Text('Utworz tozsamosc'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _importAccount,
                    icon: const Icon(Icons.devices_other_outlined),
                    label: const Text('Importuj konto z pliku'),
                  ),
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
}
