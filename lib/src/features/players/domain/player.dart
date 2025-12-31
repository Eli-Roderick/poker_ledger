class Player {
  final int? id;
  final String name;
  final String? email;
  final String? phone;
  final String? notes;
  final DateTime createdAt;
  final bool active;
  final String? linkedUserId; // UUID of linked user account (null = guest)
  final String? linkedUserDisplayName; // Display name of linked user (for UI)

  const Player({
    this.id,
    required this.name,
    this.email,
    this.phone,
    this.notes,
    required this.createdAt,
    this.active = true,
    this.linkedUserId,
    this.linkedUserDisplayName,
  });

  bool get isGuest => linkedUserId == null;
  bool get isLinked => linkedUserId != null;

  Player copyWith({
    int? id,
    String? name,
    String? email,
    String? phone,
    String? notes,
    DateTime? createdAt,
    bool? active,
    String? linkedUserId,
    String? linkedUserDisplayName,
  }) {
    return Player(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      active: active ?? this.active,
      linkedUserId: linkedUserId ?? this.linkedUserId,
      linkedUserDisplayName: linkedUserDisplayName ?? this.linkedUserDisplayName,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'email': email,
        'phone': phone,
        'notes': notes,
        'created_at': createdAt.toIso8601String(),
        'active': active,
        'linked_user_id': linkedUserId,
      };

  factory Player.fromMap(Map<String, Object?> map) => Player(
        id: map['id'] is int ? map['id'] as int : int.tryParse(map['id'].toString()),
        name: map['name'] as String,
        email: map['email'] as String?,
        phone: map['phone'] as String?,
        notes: map['notes'] as String?,
        createdAt: DateTime.parse(map['created_at'] as String),
        active: map['active'] as bool? ?? true,
        linkedUserId: map['linked_user_id'] as String?,
        linkedUserDisplayName: map['linked_user_display_name'] as String?,
      );
}

class UserSearchResult {
  final String id;
  final String? displayName;
  final String? email;

  const UserSearchResult({
    required this.id,
    this.displayName,
    this.email,
  });

  factory UserSearchResult.fromMap(Map<String, dynamic> map) => UserSearchResult(
        id: map['id'] as String,
        displayName: map['display_name'] as String?,
        email: map['email'] as String?,
      );
}
