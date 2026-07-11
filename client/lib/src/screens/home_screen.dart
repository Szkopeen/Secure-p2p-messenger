import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models/contact.dart';
import 'chat_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({required this.appState, super.key});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Secure P2P'),
            actions: [
              IconButton(
                tooltip: 'Polacz ponownie',
                onPressed: () => appState.connectRelay(),
                icon: const Icon(Icons.refresh),
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'wipe') appState.wipeLocalData();
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'wipe', child: Text('Wyczysc dane lokalne')),
                ],
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            tooltip: 'Dodaj kontakt',
            onPressed: () => _showAddContactDialog(context),
            child: const Icon(Icons.person_add_alt_1),
          ),
          body: Column(
            children: [
              _IdentityPanel(appState: appState),
              if (appState.status != null)
                Material(
                  color: appState.relayConnected
                      ? Theme.of(context).colorScheme.secondaryContainer
                      : Theme.of(context).colorScheme.errorContainer,
                  child: SizedBox(
                    width: double.infinity,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text(appState.status!, maxLines: 2, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ),
              Expanded(
                child: appState.contacts.isEmpty
                    ? const Center(child: Text('Brak kontaktow'))
                    : ListView.separated(
                        itemCount: appState.contacts.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final contact = appState.contacts[index];
                          final p2p = appState.isP2pConnected(contact.userId);
                          final messages = appState.messagesFor(contact.userId);
                          final last = messages.isEmpty ? null : messages.last;
                          final initial =
                              contact.displayName.isEmpty ? '?' : contact.displayName.substring(0, 1).toUpperCase();
                          return ListTile(
                            leading: CircleAvatar(
                              child: Text(initial),
                            ),
                            title: Text(contact.displayName),
                            subtitle: Text(
                              last?.payload.text ??
                                  '${contact.userId} • ${p2p ? 'P2P' : 'Relay'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Icon(
                              p2p ? Icons.hub_outlined : Icons.cloud_queue,
                              color: p2p ? Colors.green.shade700 : null,
                            ),
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ChatScreen(appState: appState, contact: contact),
                                ),
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showAddContactDialog(BuildContext context) async {
    final name = TextEditingController();
    final userId = TextEditingController();
    final publicKey = TextEditingController();
    String? error;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Dodaj kontakt'),
              content: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: name,
                      decoration: const InputDecoration(labelText: 'Nazwa'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: userId,
                      decoration: const InputDecoration(labelText: 'Identyfikator'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: publicKey,
                      decoration: const InputDecoration(labelText: 'Klucz publiczny Ed25519'),
                      minLines: 2,
                      maxLines: 4,
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 8),
                      Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Anuluj'),
                ),
                FilledButton(
                  onPressed: () async {
                    try {
                      await appState.addContact(
                        Contact(
                          userId: userId.text.trim(),
                          displayName: name.text.trim().isEmpty ? userId.text.trim() : name.text.trim(),
                          identityPublicKey: publicKey.text.trim(),
                        ),
                      );
                      if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                    } catch (exception) {
                      setState(() => error = exception.toString());
                    }
                  },
                  child: const Text('Dodaj'),
                ),
              ],
            );
          },
        );
      },
    );

    name.dispose();
    userId.dispose();
    publicKey.dispose();
  }
}

class _IdentityPanel extends StatelessWidget {
  const _IdentityPanel({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final publicKey = appState.ownPublicKey ?? '';
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.verified_user_outlined),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(appState.ownUserId ?? '', style: Theme.of(context).textTheme.titleMedium),
                  SelectableText(
                    publicKey,
                    maxLines: 1,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Kopiuj klucz',
              onPressed: () => Clipboard.setData(ClipboardData(text: publicKey)),
              icon: const Icon(Icons.copy),
            ),
          ],
        ),
      ),
    );
  }
}
