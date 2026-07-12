class AdminUsersResult {
  const AdminUsersResult({
    required this.users,
    required this.serverTime,
    required this.counts,
  });

  final List<AdminUser> users;
  final DateTime? serverTime;
  final AdminCounts counts;

  factory AdminUsersResult.fromJson(Map<String, dynamic> json) {
    final rawUsers = json['users'] as List<dynamic>? ?? const [];
    return AdminUsersResult(
      users: rawUsers
          .map((item) =>
              AdminUser.fromJson((item as Map).cast<String, dynamic>()))
          .toList(growable: false),
      serverTime: _parseDate(json['serverTime']),
      counts: AdminCounts.fromJson(
        (json['counts'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
    );
  }
}

class AdminCounts {
  const AdminCounts({
    required this.users,
    required this.onlineUsers,
    required this.bannedUsers,
    required this.queuedUsers,
  });

  final int users;
  final int onlineUsers;
  final int bannedUsers;
  final int queuedUsers;

  factory AdminCounts.fromJson(Map<String, dynamic> json) {
    return AdminCounts(
      users: _asInt(json['users']),
      onlineUsers: _asInt(json['onlineUsers']),
      bannedUsers: _asInt(json['bannedUsers']),
      queuedUsers: _asInt(json['queuedUsers']),
    );
  }
}

class AdminActionResult {
  const AdminActionResult({
    required this.userId,
    required this.changed,
    required this.banned,
    required this.closedConnections,
  });

  final String userId;
  final List<String> changed;
  final bool banned;
  final int closedConnections;

  factory AdminActionResult.fromJson(Map<String, dynamic> json) {
    return AdminActionResult(
      userId: json['userId'] as String? ?? '',
      changed: (json['changed'] as List<dynamic>? ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
      banned: json['banned'] == true,
      closedConnections: _asInt(json['closedConnections']),
    );
  }
}

class AdminUser {
  const AdminUser({
    required this.userId,
    required this.displayName,
    required this.known,
    required this.directory,
    required this.profile,
    required this.banned,
    required this.online,
    required this.activeConnections,
    required this.queuedIn,
    required this.queuedOut,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required this.lastDeviceId,
    required this.identityPublicKey,
  });

  final String userId;
  final String? displayName;
  final bool known;
  final bool directory;
  final bool profile;
  final bool banned;
  final bool online;
  final int activeConnections;
  final int queuedIn;
  final int queuedOut;
  final DateTime? firstSeenAt;
  final DateTime? lastSeenAt;
  final String? lastDeviceId;
  final String? identityPublicKey;

  factory AdminUser.fromJson(Map<String, dynamic> json) {
    return AdminUser(
      userId: json['userId'] as String? ?? '',
      displayName: json['displayName'] as String?,
      known: json['known'] == true,
      directory: json['directory'] == true,
      profile: json['profile'] == true,
      banned: json['banned'] == true,
      online: json['online'] == true,
      activeConnections: _asInt(json['activeConnections']),
      queuedIn: _asInt(json['queuedIn']),
      queuedOut: _asInt(json['queuedOut']),
      firstSeenAt: _parseDate(json['firstSeenAt']),
      lastSeenAt: _parseDate(json['lastSeenAt']),
      lastDeviceId: json['lastDeviceId'] as String?,
      identityPublicKey: json['identityPublicKey'] as String?,
    );
  }
}

DateTime? _parseDate(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toLocal();
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
