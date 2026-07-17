import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../crypto/codec.dart';
import '../models/cloud_account.dart';
import '../models/contact.dart';
import '../models/message.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({required this.appState, super.key});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        final totalUnread = appState.totalUnreadCount;
        final hasContent = appState.contacts.isNotEmpty;
        return Scaffold(
          appBar: AppBar(
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Secure Chat'),
                if (totalUnread > 0) ...[
                  const SizedBox(width: 12),
                  Badge.count(count: totalUnread),
                ],
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Wyszukaj kontakt',
                onPressed: () => _openCloudUsers(context),
                icon: const Icon(Icons.public),
              ),
              IconButton(
                tooltip: 'Polacz ponownie',
                onPressed: () => appState.connectCloud(),
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                tooltip: 'Ustawienia',
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SettingsScreen(appState: appState),
                    ),
                  );
                },
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            tooltip: 'Dodaj kontakt',
            onPressed: () => _openCloudUsers(context),
            child: const Icon(Icons.person_add_alt_1),
          ),
          body: Column(
            children: [
              _IdentityPanel(appState: appState),
              if (appState.status != null)
                Material(
                  color: appState.cloudConnected
                      ? Theme.of(context).colorScheme.secondaryContainer
                      : Theme.of(context).colorScheme.errorContainer,
                  child: SizedBox(
                    width: double.infinity,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text(
                        appState.status!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: !hasContent
                    ? const Center(child: Text('Brak kontaktow'))
                    : ListView(
                        children: [
                          if (appState.contacts.isNotEmpty) ...[
                            const _SectionHeader(title: 'Kontakty'),
                            for (final contact in appState.contacts)
                              _ContactTile(
                                appState: appState,
                                contact: contact,
                                subtitle: _contactSubtitle(
                                  contact,
                                  appState.messagesFor(contact.userId).isEmpty
                                      ? null
                                      : appState
                                          .messagesFor(contact.userId)
                                          .last,
                                ),
                              ),
                          ],
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openCloudUsers(BuildContext context) async {
    await appState.refreshCloudUsers();
    if (!context.mounted) return;
    final username = TextEditingController();
    Future<void> searchUsers() async {
      await appState.refreshCloudUsers(username: username.text);
    }

    try {
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) {
          return AnimatedBuilder(
            animation: appState,
            builder: (context, _) {
              final users = appState.cloudUsers;
              return ListView(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'Kontakty i wyszukiwanie',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: TextField(
                      controller: username,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: 'Dokladny login',
                        hintText: 'np. anna',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: IconButton(
                          tooltip: 'Szukaj',
                          onPressed: searchUsers,
                          icon: const Icon(Icons.arrow_forward),
                        ),
                      ),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => searchUsers(),
                    ),
                  ),
                  if (users.isEmpty)
                    const ListTile(
                      leading: Icon(Icons.info_outline),
                      title: Text('Brak wspolnych kontaktow'),
                      subtitle: Text(
                        'Aby znalezc nowa osobe, wpisz jej dokladny login.',
                      ),
                    ),
                  for (final user in users)
                    _CloudUserTile(appState: appState, user: user),
                ],
              );
            },
          );
        },
      );
    } finally {
      username.dispose();
    }
  }

  String _contactSubtitle(Contact contact, ChatMessage? last) {
    if (last == null) return '${contact.userId} / Cloud';
    if (last.retracted) return 'Wiadomosc usunieta';
    final edited = last.editedAt == null ? '' : 'Edytowano: ';
    return switch (last.payload.type) {
      PlainPayloadType.text => '$edited${last.payload.text ?? ''}',
      PlainPayloadType.file => 'Plik: ${last.payload.fileName ?? 'zalacznik'}',
      PlainPayloadType.retraction => 'Wiadomosc usunieta',
      PlainPayloadType.reaction => 'Reakcja na wiadomosc',
      PlainPayloadType.pin => 'Przypieto wiadomosc',
      PlainPayloadType.receipt => 'Potwierdzenie wiadomosci',
      PlainPayloadType.edit => 'Edytowano wiadomosc',
    };
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(title, style: Theme.of(context).textTheme.labelLarge),
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile({
    required this.appState,
    required this.contact,
    required this.subtitle,
  });

  final AppState appState;
  final Contact contact;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final online = appState.isContactOnline(contact.userId);
    final unread = appState.unreadCountFor(contact.userId);
    final initial = contact.displayName.isEmpty
        ? '?'
        : contact.displayName.substring(0, 1).toUpperCase();
    return ListTile(
      leading: _UnreadBadge(
        count: unread,
        child: _AvatarView(
          bytesBase64: contact.avatarBytesBase64,
          fallback: initial,
          online: online,
        ),
      ),
      title: Text(contact.displayName),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Wrap(
        spacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(
            online ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            color: online ? Theme.of(context).colorScheme.primary : null,
          ),
          PopupMenuButton<String>(
            tooltip: 'Opcje kontaktu',
            onSelected: (value) {
              if (value == 'safety') {
                _showSafetyNumber(context);
              } else if (value == 'remove') {
                _confirmRemoveContact(context);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'safety',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.verified_user_outlined, size: 18),
                    SizedBox(width: 10),
                    Text('Kod bezpieczenstwa'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'remove',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.person_remove_outlined, size: 18),
                    SizedBox(width: 10),
                    Text('Usun kontakt'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatScreen(appState: appState, contact: contact),
          ),
        );
      },
    );
  }

  Future<void> _showSafetyNumber(BuildContext context) async {
    final safetyNumber = appState.safetyNumberFor(contact);
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Kod: ${contact.displayName}'),
          content: SelectableText(
            safetyNumber.isEmpty
                ? 'Brak klucza do porownania.'
                : '$safetyNumber\n\nPorownaj ten kod z rozmowca poza tym serwerem. Jesli kod sie rozni, nie wysylaj poufnych wiadomosci.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Zamknij'),
            ),
            FilledButton.icon(
              onPressed: safetyNumber.isEmpty
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: safetyNumber));
                      Navigator.of(context).pop();
                    },
              icon: const Icon(Icons.copy),
              label: const Text('Kopiuj'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmRemoveContact(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Usun kontakt'),
          content: Text(
            'Usunac kontakt ${contact.displayName}? Prywatna historia z tym kontaktem zostanie usunieta lokalnie.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Usun'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    await appState.removeContact(contact);
  }
}

class _CloudUserTile extends StatelessWidget {
  const _CloudUserTile({required this.appState, required this.user});

  final AppState appState;
  final CloudPublicUser user;

  @override
  Widget build(BuildContext context) {
    final initial = user.displayName.isEmpty
        ? '?'
        : user.displayName.substring(0, 1).toUpperCase();
    return ListTile(
      leading: _AvatarView(
        bytesBase64: user.profile?.avatarBytesBase64,
        fallback: initial,
        online: true,
      ),
      title: Text(user.displayName),
      subtitle: Text(user.username),
      trailing: FilledButton.icon(
        onPressed: () async {
          try {
            await appState.startCloudConversation(user);
            if (context.mounted) Navigator.of(context).pop();
          } catch (error) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(error.toString())));
          }
        },
        icon: const Icon(Icons.chat_outlined),
        label: const Text('Czat'),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count, required this.child});

  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Badge.count(
      count: count,
      isLabelVisible: count > 0,
      offset: const Offset(2, -2),
      child: child,
    );
  }
}

class _IdentityPanel extends StatelessWidget {
  const _IdentityPanel({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final publicKey = appState.ownPublicKey ?? '';
    final displayName = appState.ownDisplayName ?? appState.ownUserId ?? '';
    final initial =
        displayName.isEmpty ? '?' : displayName.substring(0, 1).toUpperCase();
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            _AvatarView(
              bytesBase64: appState.ownProfile?.avatarBytesBase64,
              fallback: initial,
              online: appState.cloudConnected,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
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
