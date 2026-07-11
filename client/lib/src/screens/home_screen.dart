import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../crypto/codec.dart';
import '../models/contact.dart';
import '../models/message.dart';
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
                  PopupMenuItem(
                      value: 'wipe', child: Text('Wyczysc dane lokalne')),
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: Text(appState.status!,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
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
                          final online =
                              appState.isContactOnline(contact.userId);
                          final messages = appState.messagesFor(contact.userId);
                          final last = messages.isEmpty ? null : messages.last;
                          final initial = contact.displayName.isEmpty
                              ? '?'
                              : contact.displayName
                                  .substring(0, 1)
                                  .toUpperCase();
                          return ListTile(
                            leading: _AvatarView(
                              bytesBase64: contact.avatarBytesBase64,
                              fallback: initial,
                              online: online,
                            ),
                            title: Text(contact.displayName),
                            subtitle: Text(
                              _contactSubtitle(contact, last, p2p),
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
                                  builder: (_) => ChatScreen(
                                      appState: appState, contact: contact),
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
                      decoration:
                          const InputDecoration(labelText: 'Identyfikator'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: publicKey,
                      decoration: const InputDecoration(
                          labelText: 'Klucz publiczny Ed25519'),
                      minLines: 2,
                      maxLines: 4,
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 8),
                      Text(error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
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
                          displayName: name.text.trim().isEmpty
                              ? userId.text.trim()
                              : name.text.trim(),
                          identityPublicKey: publicKey.text.trim(),
                        ),
                      );
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
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

  String _contactSubtitle(Contact contact, ChatMessage? last, bool p2p) {
    if (last == null) return '${contact.userId} / ${p2p ? 'P2P' : 'Relay'}';
    if (last.retracted) return 'Wiadomosc usunieta';
    return switch (last.payload.type) {
      PlainPayloadType.text => last.payload.text ?? '',
      PlainPayloadType.file => 'Plik: ${last.payload.fileName ?? 'zalacznik'}',
      PlainPayloadType.retraction => 'Wiadomosc usunieta',
      PlainPayloadType.reaction => 'Reakcja na wiadomosc',
      PlainPayloadType.pin => 'Przypieto wiadomosc',
    };
  }
}

class _IdentityPanel extends StatelessWidget {
  const _IdentityPanel({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final publicKey = appState.ownPublicKey ?? '';
    final initial = (appState.ownUserId ?? '?').isEmpty
        ? '?'
        : (appState.ownUserId ?? '?').substring(0, 1).toUpperCase();
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            _AvatarView(
              bytesBase64: appState.ownProfile?.avatarBytesBase64,
              fallback: initial,
              online: appState.relayConnected,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(appState.ownUserId ?? '',
                      style: Theme.of(context).textTheme.titleMedium),
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
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: publicKey)),
              icon: const Icon(Icons.copy),
            ),
            IconButton(
              tooltip: 'Ustaw profilowe',
              onPressed: () => _setProfileImage(context),
              icon: const Icon(Icons.photo_camera_outlined),
            ),
            if (appState.ownProfile?.hasAvatar == true)
              IconButton(
                tooltip: 'Usun profilowe',
                onPressed: () => _clearProfileImage(context),
                icon: const Icon(Icons.no_photography_outlined),
              ),
          ],
        ),
      ),
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
}

class _AvatarView extends StatelessWidget {
  const _AvatarView({
    required this.bytesBase64,
    required this.fallback,
    required this.online,
  });

  final String? bytesBase64;
  final String fallback;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final bytes = _decodeAvatar();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: 22,
          backgroundImage: bytes == null ? null : MemoryImage(bytes),
          child: bytes == null ? Text(fallback) : null,
        ),
        if (online)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: Colors.green.shade500,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 2,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Uint8List? _decodeAvatar() {
    final raw = bytesBase64;
    if (raw == null || raw.isEmpty) return null;
    try {
      return Uint8List.fromList(unb64(raw));
    } catch (_) {
      return null;
    }
  }
}
