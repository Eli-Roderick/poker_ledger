/// Represents a group that can own one immutable game association.
///
/// Current accepted members see the full ledger and shared standings for every
/// game attached to the group.
///
/// Key features:
/// - Owner can invite members and manage the group
/// - A new game can be attached to this one group during setup
/// - All current members can view each attached game's full ledger
/// - Stats can be filtered by group to see group-specific leaderboards
class Group {
  final int id;
  final String name;
  final String ownerId;
  final DateTime createdAt;
  final DateTime? archivedAt;

  /// True if the current user is the owner of this group
  final bool isOwner;
  final bool canManageGames;

  /// Number of members in the group (including owner)
  final int memberCount;

  const Group({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.createdAt,
    this.archivedAt,
    this.isOwner = false,
    this.canManageGames = false,
    this.memberCount = 0,
  });

  factory Group.fromMap(Map<String, dynamic> map, {String? currentUserId}) =>
      Group(
        id: map['id'] as int,
        name: map['name'] as String,
        ownerId: map['owner_id'] as String,
        createdAt: DateTime.parse(map['created_at'] as String),
        archivedAt: map['archived_at'] == null
            ? null
            : DateTime.parse(map['archived_at'] as String),
        isOwner: currentUserId != null && map['owner_id'] == currentUserId,
        canManageGames:
            currentUserId != null && map['owner_id'] == currentUserId,
        memberCount: map['member_count'] as int? ?? 0,
      );

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'owner_id': ownerId,
    'created_at': createdAt.toIso8601String(),
    'archived_at': archivedAt?.toIso8601String(),
  };

  Group copyWith({
    int? id,
    String? name,
    String? ownerId,
    DateTime? createdAt,
    DateTime? archivedAt,
    bool? isOwner,
    bool? canManageGames,
    int? memberCount,
  }) => Group(
    id: id ?? this.id,
    name: name ?? this.name,
    ownerId: ownerId ?? this.ownerId,
    createdAt: createdAt ?? this.createdAt,
    archivedAt: archivedAt ?? this.archivedAt,
    isOwner: isOwner ?? this.isOwner,
    canManageGames: canManageGames ?? this.canManageGames,
    memberCount: memberCount ?? this.memberCount,
  );
}

class GroupMember {
  final int id;
  final int groupId;
  final String oderId;
  final DateTime joinedAt;
  final String? displayName;
  final String? email;
  final String? handle;
  final bool isOwner;
  final bool canManageGames;

  const GroupMember({
    required this.id,
    required this.groupId,
    required this.oderId,
    required this.joinedAt,
    this.displayName,
    this.email,
    this.handle,
    this.isOwner = false,
    this.canManageGames = false,
  });

  factory GroupMember.fromMap(
    Map<String, dynamic> map, {
    String? groupOwnerId,
  }) => GroupMember(
    id: map['id'] as int,
    groupId: map['group_id'] as int,
    oderId: map['user_id'] as String,
    joinedAt: DateTime.parse(map['joined_at'] as String),
    displayName: map['display_name'] as String?,
    email: map['email'] as String?,
    handle: map['handle'] as String?,
    isOwner: groupOwnerId != null && map['user_id'] == groupOwnerId,
    canManageGames: map['can_manage_games'] as bool? ?? false,
  );
}

class GroupInvitation {
  final String id;
  final int groupId;
  final String groupName;
  final DateTime expiresAt;

  const GroupInvitation({
    required this.id,
    required this.groupId,
    required this.groupName,
    required this.expiresAt,
  });

  factory GroupInvitation.fromMap(Map<String, dynamic> map) {
    final group = map['groups'] as Map<String, dynamic>?;
    return GroupInvitation(
      id: map['id'] as String,
      groupId: map['group_id'] as int,
      groupName: group?['name'] as String? ?? 'Poker group',
      expiresAt: DateTime.parse(map['expires_at'] as String),
    );
  }
}
