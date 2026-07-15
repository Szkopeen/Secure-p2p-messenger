import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/admin_user.dart';
import '../models/identity.dart';
import '../services/admin_api_client.dart';
import '../storage/secure_store.dart';

enum _AdminAction { ban, unban, deleteAndBan, deleteOnly }

class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({required this.relaySettings, super.key});

  final RelaySettings? relaySettings;

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  final _store = SecureStore();
  late final TextEditingController _serverUrl;
  late final TextEditingController _adminToken;
  late final TextEditingController _search;

  AdminUsersResult? _result;
  String? _status;
  bool _loading = false;
  bool _obscureToken = true;

  @override
  void initState() {
    super.initState();
    _serverUrl = TextEditingController(
      text: _defaultAdminUrl(widget.relaySettings),
    );
    _adminToken = TextEditingController();
    _search = TextEditingController()..addListener(() => setState(() {}));
    _loadSavedSettings();
  }

  @override
  void dispose() {
    _serverUrl.dispose();
    _adminToken.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadSavedSettings() async {
    final settings = await _store.loadAdminSettings();
    if (!mounted || settings == null) return;
    setState(() {
      _serverUrl.text = settings.serverUrl;
      _adminToken.text = settings.adminToken;
    });
    if (settings.adminToken.isNotEmpty) {
      await _loadUsers(saveSettings: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final users = _filteredUsers;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Panel administratora'),
        actions: [
          IconButton(
            tooltip: 'Odswiez',
            onPressed: _loading ? null : () => _loadUsers(),
            icon: _loading
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Section(
            title: 'Polaczenie',
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 780;
                    final fields = [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _serverUrl,
                          decoration: const InputDecoration(
                            labelText: 'Adres admin API',
                            prefixIcon: Icon(Icons.dns_outlined),
                          ),
                          textInputAction: TextInputAction.next,
                        ),
                      ),
                      const SizedBox(width: 12, height: 12),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _adminToken,
                          obscureText: _obscureToken,
                          decoration: InputDecoration(
                            labelText: 'Token administratora',
                            prefixIcon: const Icon(Icons.key_outlined),
                            suffixIcon: IconButton(
                              tooltip: _obscureToken ? 'Pokaz' : 'Ukryj',
                              onPressed: () => setState(
                                () => _obscureToken = !_obscureToken,
                              ),
                              icon: Icon(
                                _obscureToken
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                          onSubmitted: (_) => _loadUsers(),
                        ),
                      ),
                    ];
                    return wide
                        ? Row(children: fields)
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: fields,
                          );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Row(
                  children: [
                    FilledButton.icon(
                      onPressed: _loading ? null : () => _loadUsers(),
                      icon: const Icon(Icons.login),
                      label: const Text('Polacz'),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: _loading ? null : _saveSettings,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Zapisz'),
                    ),
                  ],
                ),
              ),
              if (_status != null)
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('Status'),
                  subtitle: Text(_status!),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (result != null) ...[
            _Section(
              title: 'Serwer',
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _MetricChip(
                        icon: Icons.people_outline,
                        label: 'Uzytkownicy',
                        value: result.counts.users.toString(),
                      ),
                      _MetricChip(
                        icon: Icons.circle,
                        iconColor: Colors.greenAccent,
                        label: 'Online',
                        value: result.counts.onlineUsers.toString(),
                      ),
                      _MetricChip(
                        icon: Icons.block_outlined,
                        label: 'Zablokowani',
                        value: result.counts.bannedUsers.toString(),
                      ),
                      _MetricChip(
                        icon: Icons.mark_email_unread_outlined,
                        label: 'Kolejki',
                        value: result.counts.queuedUsers.toString(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              title: 'Uzytkownicy',
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      labelText: 'Szukaj',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
                if (users.isEmpty)
                  const ListTile(
                    leading: Icon(Icons.person_off_outlined),
                    title: Text('Brak wynikow'),
                  )
                else
                  for (final user in users)
                    _AdminUserTile(
                      user: user,
                      onCopyId: () => _copyUserId(user),
                      onAction: (action) => _runAction(user, action),
                    ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  List<AdminUser> get _filteredUsers {
    final users = _result?.users ?? const <AdminUser>[];
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return users;
    return users.where((user) {
      return user.userId.toLowerCase().contains(query) ||
          (user.displayName ?? '').toLowerCase().contains(query) ||
          (user.lastDeviceId ?? '').toLowerCase().contains(query);
    }).toList(growable: false);
  }

  AdminSettings _settingsFromFields() {
    final url = _serverUrl.text.trim();
    final token = _adminToken.text.trim();
    if (url.isEmpty) {
      throw const AdminApiException('Podaj adres admin API.');
    }
    if (token.length < 32) {
      throw const AdminApiException(
        'Token administratora musi miec minimum 32 znaki.',
      );
    }
    return AdminSettings(serverUrl: url, adminToken: token);
  }

  Future<void> _saveSettings() async {
    try {
      await _store.saveAdminSettings(_settingsFromFields());
      _showStatus('Ustawienia zapisane.');
    } catch (error) {
      _showStatus(error.toString());
    }
  }

  Future<void> _loadUsers({bool saveSettings = true}) async {
    setState(() {
      _loading = true;
      _status = null;
    });
    try {
      final settings = _settingsFromFields();
      if (saveSettings) await _store.saveAdminSettings(settings);
      final result = await AdminApiClient(settings).listUsers();
      if (!mounted) return;
      setState(() {
        _result = result;
        _status =
            'Polaczono. Ostatnie odswiezenie: ${_formatDate(DateTime.now())}.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _runAction(AdminUser user, _AdminAction action) async {
    final confirmed = await _confirmAction(user, action);
    if (confirmed != true) return;

    setState(() {
      _loading = true;
      _status = null;
    });

    try {
      final client = AdminApiClient(_settingsFromFields());
      final result = switch (action) {
        _AdminAction.ban => await client.banUser(user.userId),
        _AdminAction.unban => await client.unbanUser(user.userId),
        _AdminAction.deleteAndBan => await client.deleteUser(
            user.userId,
            ban: true,
          ),
        _AdminAction.deleteOnly => await client.deleteUser(
            user.userId,
            ban: false,
          ),
      };
      final refreshed = await client.listUsers();
      if (!mounted) return;
      setState(() {
        _result = refreshed;
        _status =
            'Wykonano operacje dla ${result.userId}. Zamkniete polaczenia: ${result.closedConnections}.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<bool?> _confirmAction(AdminUser user, _AdminAction action) {
    final (title, body, actionLabel) = switch (action) {
      _AdminAction.ban => (
          'Zablokowac uzytkownika?',
          'UserId: ${user.userId}\nAktywne polaczenia zostana zamkniete.',
          'Zablokuj',
        ),
      _AdminAction.unban => (
          'Odblokowac uzytkownika?',
          'UserId: ${user.userId}',
          'Odblokuj',
        ),
      _AdminAction.deleteAndBan => (
          'Usunac i zablokowac?',
          'UserId: ${user.userId}\nTo usunie dane relay, kolejki offline, profil publiczny i dopisze userId do banlisty.',
          'Usun',
        ),
      _AdminAction.deleteOnly => (
          'Usunac dane bez blokady?',
          'UserId: ${user.userId}\nUzytkownik bedzie mogl polaczyc sie ponownie.',
          'Usun',
        ),
    };

    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: SelectableText(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(actionLabel),
            ),
          ],
        );
      },
    );
  }

  Future<void> _copyUserId(AdminUser user) async {
    await Clipboard.setData(ClipboardData(text: user.userId));
    _showStatus('Skopiowano userId.');
  }

  void _showStatus(String message) {
    if (!mounted) return;
    setState(() => _status = message);
  }

  static String _defaultAdminUrl(RelaySettings? settings) {
    final raw = settings?.serverUrl.trim();
    if (raw == null || raw.isEmpty) return 'https://chat.szkpn.pl';
    final uri = Uri.tryParse(raw);
    if (uri == null) return raw;
    final scheme = switch (uri.scheme) {
      'wss' => 'https',
      'ws' => 'http',
      _ => uri.scheme,
    };
    return uri.replace(scheme: scheme, path: '').toString();
  }

  String _formatDate(DateTime? value) {
    if (value == null) return '-';
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _AdminUserTile extends StatelessWidget {
  const _AdminUserTile({
    required this.user,
    required this.onCopyId,
    required this.onAction,
  });

  final AdminUser user;
  final VoidCallback onCopyId;
  final ValueChanged<_AdminAction> onAction;

  @override
  Widget build(BuildContext context) {
    final title = user.displayName == null || user.displayName!.isEmpty
        ? user.userId
        : user.displayName!;
    return ExpansionTile(
      leading: Icon(
        Icons.circle,
        size: 12,
        color: user.online
            ? Colors.greenAccent
            : Theme.of(context).colorScheme.outline,
      ),
      title: Text(title),
      subtitle: Text(_subtitle),
      trailing: PopupMenuButton<_AdminAction>(
        tooltip: 'Akcje',
        onSelected: onAction,
        itemBuilder: (context) => [
          if (user.banned)
            const PopupMenuItem(
              value: _AdminAction.unban,
              child: ListTile(
                leading: Icon(Icons.lock_open_outlined),
                title: Text('Odblokuj'),
              ),
            )
          else
            const PopupMenuItem(
              value: _AdminAction.ban,
              child: ListTile(
                leading: Icon(Icons.block_outlined),
                title: Text('Zablokuj'),
              ),
            ),
          const PopupMenuItem(
            value: _AdminAction.deleteAndBan,
            child: ListTile(
              leading: Icon(Icons.person_remove_outlined),
              title: Text('Usun i zablokuj'),
            ),
          ),
          const PopupMenuItem(
            value: _AdminAction.deleteOnly,
            child: ListTile(
              leading: Icon(Icons.delete_outline),
              title: Text('Usun dane'),
            ),
          ),
        ],
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _SmallChip(label: user.online ? 'online' : 'offline'),
                  if (user.banned) const _SmallChip(label: 'zablokowany'),
                  if (user.known) const _SmallChip(label: 'known'),
                  if (user.directory)
                    const _SmallChip(label: 'lista publiczna'),
                  if (user.profile) const _SmallChip(label: 'profil'),
                  _SmallChip(label: 'polaczenia: ${user.activeConnections}'),
                  _SmallChip(label: 'offline in: ${user.queuedIn}'),
                  _SmallChip(label: 'offline out: ${user.queuedOut}'),
                ],
              ),
              const SizedBox(height: 12),
              _DetailRow(label: 'UserId', value: user.userId, action: onCopyId),
              _DetailRow(
                label: 'Ostatnie urzadzenie',
                value: user.lastDeviceId ?? '-',
              ),
              _DetailRow(
                label: 'Pierwszy raz',
                value: _formatDate(user.firstSeenAt),
              ),
              _DetailRow(
                label: 'Ostatnio widziany',
                value: _formatDate(user.lastSeenAt),
              ),
              _DetailRow(
                label: 'Klucz publiczny',
                value: user.identityPublicKey ?? '-',
                mono: true,
              ),
            ],
          ),
        ),
      ],
    );
  }

  String get _subtitle {
    final parts = <String>[
      user.userId,
      user.online ? 'online' : 'offline',
      if (user.banned) 'zablokowany',
      if (user.queuedIn > 0) 'kolejka: ${user.queuedIn}',
    ];
    return parts.join(' / ');
  }

  static String _formatDate(DateTime? value) {
    if (value == null) return '-';
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.action,
    this.mono = false,
  });

  final String label;
  final String value;
  final VoidCallback? action;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final style = mono
        ? Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace')
        : Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(child: SelectableText(value, style: style)),
          if (action != null)
            IconButton(
              tooltip: 'Kopiuj',
              onPressed: action,
              icon: const Icon(Icons.copy, size: 18),
            ),
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({
    required this.icon,
    required this.label,
    required this.value,
    this.iconColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 18, color: iconColor),
      label: Text('$label: $value'),
    );
  }
}

class _SmallChip extends StatelessWidget {
  const _SmallChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(visualDensity: VisualDensity.compact, label: Text(label));
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

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
