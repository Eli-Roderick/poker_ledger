class Group {
  final int id;
  final String name;
  final String ownerId;
  final DateTime createdAt;
  final bool isOwner;
  final int memberCount;

  const Group({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.createdAt,
    this.isOwner = false,
    this.memberCount = 0,
  });

  factory Group.fromMap(Map<String, dynamic> map, {String? currentUserId}) => Group(
        id: map['id'] as int,
        name: map['name'] as String,
        ownerId: map['owner_id'] as String,
        createdAt: DateTime.parse(map['created_at'] as String),
        isOwner: currentUserId != null && map['owner_id'] == currentUserId,
        memberCount: map['member_count'] as int? ?? 0,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'owner_id': ownerId,
        'created_at': createdAt.toIso8601String(),
      };

  Group copyWith({
    int? id,
    String? name,
    String? ownerId,
    DateTime? createdAt,
    bool? isOwner,
    int? memberCount,
  }) =>
      Group(
        id: id ?? this.id,
        name: name ?? this.name,
        ownerId: ownerId ?? this.ownerId,
        createdAt: createdAt ?? this.createdAt,
        isOwner: isOwner ?? this.isOwner,
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
  final bool isOwner;

  const GroupMember({
    required this.id,
    required this.groupId,
    required this.oderId,
    required this.joinedAt,
    this.displayName,
    this.email,
    this.isOwner = false,
  });

  factory GroupMember.fromMap(Map<String, dynamic> map, {String? groupOwnerId}) => GroupMember(
        id: map['id'] as int,
        groupId: map['group_id'] as int,
        oderId: map['user_id'] as String,
        joinedAt: DateTime.parse(map['joined_at'] as String),
        displayName: map['display_name'] as String?,
        email: map['email'] as String?,
        isOwner: groupOwnerId != null && map['user_id'] == groupOwnerId,
      );
}
