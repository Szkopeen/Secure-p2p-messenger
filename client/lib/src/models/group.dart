class GroupConversation {
  const GroupConversation({
    required this.groupId,
    required this.name,
    required this.memberIds,
    required this.acceptedMemberIds,
    this.invitedMemberIds = const [],
    required this.createdAt,
    this.invitedBy,
    this.pendingInvite = false,
  });

  final String groupId;
  final String name;
  final List<String> memberIds;
  final List<String> acceptedMemberIds;
  final List<String> invitedMemberIds;
  final DateTime createdAt;
  final String? invitedBy;
  final bool pendingInvite;

  bool isAcceptedBy(String userId) {
    return acceptedMemberIds.contains(userId) && !pendingInvite;
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'groupId': groupId,
        'name': name,
        'memberIds': memberIds,
        'acceptedMemberIds': acceptedMemberIds,
        'invitedMemberIds': invitedMemberIds,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'invitedBy': invitedBy,
        'pendingInvite': pendingInvite,
      };

  factory GroupConversation.fromJson(Map<String, dynamic> json) {
    return GroupConversation(
      groupId: json['groupId'] as String,
      name: json['name'] as String,
      memberIds: ((json['memberIds'] as List?) ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
      acceptedMemberIds: ((json['acceptedMemberIds'] as List?) ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
      invitedMemberIds: ((json['invitedMemberIds'] as List?) ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
      createdAt: DateTime.parse(json['createdAt'] as String),
      invitedBy: json['invitedBy'] as String?,
      pendingInvite: json['pendingInvite'] == true,
    );
  }

  GroupConversation copyWith({
    String? name,
    List<String>? memberIds,
    List<String>? acceptedMemberIds,
    List<String>? invitedMemberIds,
    DateTime? createdAt,
    String? invitedBy,
    bool? pendingInvite,
  }) {
    return GroupConversation(
      groupId: groupId,
      name: name ?? this.name,
      memberIds: memberIds ?? this.memberIds,
      acceptedMemberIds: acceptedMemberIds ?? this.acceptedMemberIds,
      invitedMemberIds: invitedMemberIds ?? this.invitedMemberIds,
      createdAt: createdAt ?? this.createdAt,
      invitedBy: invitedBy ?? this.invitedBy,
      pendingInvite: pendingInvite ?? this.pendingInvite,
    );
  }
}
