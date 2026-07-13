import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../crypto/codec.dart';
import '../models/cloud_account.dart';
import '../models/contact.dart';
import '../models/contact_invite.dart';
import '../models/group.dart';
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
        final pendingGroupInvites = appState.groups
            .where((group) => group.pendingInvite)
            .toList(growable: false);
        final contactInvites = appState.contactInvites;
        final activeGroups = appState.groups
            .where((group) => !group.pendingInvite)
            .toList(growable: false);
        final hasContent = appState.contacts.isNotEmpty ||
            contactInvites.isNotEmpty ||
            pendingGroupInvites.isNotEmpty ||
            activeGroups.isNotEmpty;
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
                tooltip: 'Utworz grupe',
                onPressed: () => _showCreateGroupDialog(context),
                icon: const Icon(Icons.group_add_outlined),
              ),
              IconButton(
                tooltip: 'Globalna lista',
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
                child: !hasContent
                    ? const Center(child: Text('Brak kontaktow'))
                    : ListView(
                        children: [
                          if (pendingGroupInvites.isNotEmpty) ...[
                            const _SectionHeader(title: 'Zaproszenia do grup'),
                            for (final group in pendingGroupInvites)
                              _GroupInviteTile(
                                appState: appState,
                                group: group,
                                subtitle: _groupSubtitle(group),
                              ),
                          ],
                          if (contactInvites.isNotEmpty) ...[
                            const _SectionHeader(
                                title: 'Zaproszenia do kontaktow'),
                            for (final invite in contactInvites)
                              _ContactInviteTile(
                                appState: appState,
                                invite: invite,
                              ),
                          ],
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
                          if (activeGroups.isNotEmpty) ...[
                            const _SectionHeader(title: 'Grupy'),
                            for (final group in activeGroups)
                              _GroupTile(
                                appState: appState,
                                group: group,
                                subtitle: _groupSubtitle(group),
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
                    'Uzytkownicy',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (users.isEmpty)
                  const ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('Brak innych kont na serwerze'),
                  ),
                for (final user in users)
                  _CloudUserTile(appState: appState, user: user),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showCreateGroupDialog(BuildContext context) async {
    final name = TextEditingController();
    final selected = <String>{};
    String? error;

    final selectableContacts = appState.contacts;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Utworz grupe'),
              content: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: name,
                      decoration:
                          const InputDecoration(labelText: 'Nazwa grupy'),
                    ),
                    const SizedBox(height: 12),
                    if (selectableContacts.isEmpty)
                      const Text('Brak kontaktow do zaproszenia.')
                    else
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 320),
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            for (final contact in selectableContacts)
                              CheckboxListTile(
                                value: selected.contains(contact.userId),
                                onChanged: (value) {
                                  setState(() {
                                    if (value == true) {
                                      selected.add(contact.userId);
                                    } else {
                                      selected.remove(contact.userId);
                                    }
                                  });
                                },
                                title: Text(contact.displayName),
                                subtitle: Text(
                                  appState.isContactOnline(contact.userId)
                                      ? '${contact.userId} / online'
                                      : '${contact.userId} / offline, zaproszenie poczeka',
                                ),
                              ),
                          ],
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
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Anuluj'),
                ),
                FilledButton(
                  onPressed: selectableContacts.isEmpty
                      ? null
                      : () async {
                          try {
                            final members = selectableContacts
                                .where((contact) =>
                                    selected.contains(contact.userId))
                                .toList(growable: false);
                            await appState.createGroup(
                              name: name.text,
                              members: members,
                            );
                            if (dialogContext.mounted) {
                              Navigator.of(dialogContext).pop();
                            }
                          } catch (exception) {
                            setState(() => error = exception.toString());
                          }
                        },
                  child: const Text('Utworz'),
                ),
              ],
            );
          },
        );
      },
    );
    name.dispose();
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
      PlainPayloadType.groupInvite => 'Zaproszenie do grupy',
      PlainPayloadType.groupInviteResponse => 'Odpowiedz na zaproszenie',
      PlainPayloadType.groupText => last.payload.text ?? '',
      PlainPayloadType.groupLeave => 'Uzytkownik wyszedl z grupy',
    };
  }

  String _groupSubtitle(GroupConversation group) {
    final messages = appState.messagesFor(group.groupId);
    if (group.pendingInvite) {
      return 'Zaproszenie od ${appState.displayNameForUser(group.invitedBy ?? '')}';
    }
    if (messages.isNotEmpty) {
      final last = messages.last;
      if (last.direction == MessageDirection.system) {
        return last.payload.text ?? '';
      }
      final prefix = last.direction == MessageDirection.inbound
          ? '${appState.displayNameForUser(last.senderId ?? '')}: '
          : '';
      final preview = switch (last.payload.type) {
        PlainPayloadType.text => last.payload.text ?? '',
        PlainPayloadType.file =>
          'Plik: ${last.payload.fileName ?? 'zalacznik'}',
        PlainPayloadType.retraction => 'Wiadomosc usunieta',
        PlainPayloadType.reaction => 'Reakcja na wiadomosc',
        PlainPayloadType.pin => 'Przypieto wiadomosc',
        PlainPayloadType.receipt => 'Potwierdzenie wiadomosci',
        PlainPayloadType.edit => 'Edytowano wiadomosc',
        PlainPayloadType.groupInvite => 'Zaproszenie do grupy',
        PlainPayloadType.groupInviteResponse => 'Odpowiedz na zaproszenie',
        PlainPayloadType.groupText => last.payload.text ?? '',
        PlainPayloadType.groupLeave => 'Uzytkownik wyszedl z grupy',
      };
      return '$prefix$preview';
    }
    return 'Zaakceptowalo ${group.acceptedMemberIds.length} z ${group.memberIds.length}';
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge,
      ),
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
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
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
              if (value == 'remove') {
                _confirmRemoveContact(context);
              }
            },
            itemBuilder: (context) => const [
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
  const _CloudUserTile({
    required this.appState,
    required this.user,
  });

  final AppState appState;
  final CloudPublicUser user;

  @override
  Widget build(BuildContext context) {
    final initial = user.displayName.isEmpty
        ? '?'
        : user.displayName.substring(0, 1).toUpperCase();
    return ListTile(
      leading: _AvatarView(
        bytesBase64: null,
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
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(error.toString())),
            );
          }
        },
        icon: const Icon(Icons.chat_outlined),
        label: const Text('Czat'),
      ),
    );
  }
}

class _ContactInviteTile extends StatelessWidget {
  const _ContactInviteTile({
    required this.appState,
    required this.invite,
  });

  final AppState appState;
  final ContactInvite invite;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.person_add_alt_1)),
      title: Text(invite.displayName),
      subtitle: Text('${invite.userId} chce dodac Cie do kontaktow.'),
      trailing: Wrap(
        spacing: 4,
        children: [
          IconButton(
            tooltip: 'Odrzuc',
            onPressed: () => appState.rejectContactInvite(invite),
            icon: const Icon(Icons.close),
          ),
          IconButton.filled(
            tooltip: 'Akceptuj',
            onPressed: () => appState.acceptContactInvite(invite),
            icon: const Icon(Icons.check),
          ),
        ],
      ),
    );
  }
}

class _GroupInviteTile extends StatelessWidget {
  const _GroupInviteTile({
    required this.appState,
    required this.group,
    required this.subtitle,
  });

  final AppState appState;
  final GroupConversation group;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.primaryContainer,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.primary),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.mark_email_unread_outlined,
                      color: colors.onPrimaryContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.name,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(color: colors.onPrimaryContainer),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.onPrimaryContainer),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () =>
                        appState.respondToGroupInvite(group, false),
                    icon: const Icon(Icons.close),
                    label: const Text('Odrzuc'),
                  ),
                  FilledButton.icon(
                    onPressed: () => appState.respondToGroupInvite(group, true),
                    icon: const Icon(Icons.check),
                    label: const Text('Akceptuj'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({
    required this.appState,
    required this.group,
    required this.subtitle,
  });

  final AppState appState;
  final GroupConversation group;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final unread = appState.unreadCountFor(group.groupId);
    return ListTile(
      leading: Badge.count(
        count: unread,
        isLabelVisible: unread > 0,
        child: const CircleAvatar(
          child: Icon(Icons.groups_outlined),
        ),
      ),
      title: Text(group.name),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: group.pendingInvite
          ? Wrap(
              spacing: 4,
              children: [
                IconButton(
                  tooltip: 'Odrzuc',
                  onPressed: () => appState.respondToGroupInvite(group, false),
                  icon: const Icon(Icons.close),
                ),
                IconButton.filled(
                  tooltip: 'Akceptuj',
                  onPressed: () => appState.respondToGroupInvite(group, true),
                  icon: const Icon(Icons.check),
                ),
              ],
            )
          : const Icon(Icons.chevron_right),
      onTap: group.pendingInvite
          ? null
          : () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ChatScreen(appState: appState, group: group),
                ),
              );
            },
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({
    required this.count,
    required this.child,
  });

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
