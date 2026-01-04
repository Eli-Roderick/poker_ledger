/// Represents a player in the poker ledger.
/// 
/// Players can be either:
/// - **Linked**: Connected to a user account via [linkedUserId], allowing
///   cross-user stat tracking and profile viewing
/// - **Guest**: Not linked to any account (legacy players or unregistered friends)
/// 
/// Each user maintains their own player list. The same real person may exist
/// as different Player records for different users, but linking them to the
/// same user account allows stats to be aggregated correctly.
class Player {
  final int? id;
  final String name;
  final String? email;
  final String? phone;
  final String? notes;
  final DateTime createdAt;
  final bool active;
  
  /// UUID of the linked user account, or null for guest players
  final String? linkedUserId;
  
  /// Display name of the linked user (cached for UI display)
  final String? linkedUserDisplayName;

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

  /// True if this player is not linked to a user account
  bool get isGuest => linkedUserId == null;
  
  /// True if this player is linked to a user account
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
  
  /// If this user was previously added as a player but deactivated,
  /// this contains the player ID for reactivation
  final int? deactivatedPlayerId;
  
  /// True if this user has a deactivated player entry
  bool get isDeactivated => deactivatedPlayerId != null;

  const UserSearchResult({
    required this.id,
    this.displayName,
    this.email,
    this.deactivatedPlayerId,
  });

  factory UserSearchResult.fromMap(Map<String, dynamic> map, {int? deactivatedPlayerId}) => UserSearchResult(
        id: map['id'] as String,
        displayName: map['display_name'] as String?,
        email: map['email'] as String?,
        deactivatedPlayerId: deactivatedPlayerId,
      );
}
