import 'package:supabase_flutter/supabase_flutter.dart' hide Session;
import '../../../utils/idempotency_key.dart';
import '../../session/domain/session_models.dart';
import '../domain/group_models.dart';

class GroupRepository {
  final SupabaseClient _client = Supabase.instance.client;

  String get _currentUserId => _client.auth.currentUser!.id;

  /// Get all groups the current user owns or is a member of
  Future<List<Group>> getMyGroups() async {
    // Get groups user owns
    final ownedGroups = await _client
        .from('groups')
        .select('*, group_members(user_id, status, left_at)')
        .eq('owner_id', _currentUserId);

    // Get groups user is a member of (but doesn't own)
    final memberGroups = await _client
        .from('group_members')
        .select(
          'group_id, can_manage_games, '
          'groups(*, group_members(user_id, status, left_at))',
        )
        .eq('user_id', _currentUserId)
        .eq('status', 'accepted')
        .isFilter('left_at', null);

    final List<Group> groups = [];

    // Add owned groups
    for (final g in ownedGroups) {
      final memberCount = _acceptedMemberCount(
        g['group_members'],
        g['owner_id'] as String,
      );
      groups.add(
        Group(
          id: g['id'] as int,
          name: g['name'] as String,
          ownerId: g['owner_id'] as String,
          createdAt: DateTime.parse(g['created_at'] as String),
          archivedAt: g['archived_at'] == null
              ? null
              : DateTime.parse(g['archived_at'] as String),
          isOwner: true,
          canManageGames: true,
          memberCount: memberCount + 1, // +1 for owner
        ),
      );
    }

    // Add member groups (excluding ones we own)
    for (final m in memberGroups) {
      final g = m['groups'] as Map<String, dynamic>?;
      if (g == null) continue;
      if (g['owner_id'] == _currentUserId) continue; // Already added as owned

      final memberCount = _acceptedMemberCount(
        g['group_members'],
        g['owner_id'] as String,
      );
      groups.add(
        Group(
          id: g['id'] as int,
          name: g['name'] as String,
          ownerId: g['owner_id'] as String,
          createdAt: DateTime.parse(g['created_at'] as String),
          archivedAt: g['archived_at'] == null
              ? null
              : DateTime.parse(g['archived_at'] as String),
          isOwner: false,
          canManageGames: m['can_manage_games'] == true,
          memberCount: memberCount + 1, // +1 for owner
        ),
      );
    }

    // Sort by name
    groups.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return groups;
  }

  /// Create a new group
  Future<Group> createGroup(String name) async {
    final data = await _client
        .from('groups')
        .insert({'name': name, 'owner_id': _currentUserId})
        .select()
        .single();

    return Group(
      id: data['id'] as int,
      name: data['name'] as String,
      ownerId: data['owner_id'] as String,
      createdAt: DateTime.parse(data['created_at'] as String),
      isOwner: true,
      canManageGames: true,
      memberCount: 1,
    );
  }

  /// Groups with history are archived, never detached from their games.
  Future<void> deleteGroup(int groupId) async {
    await _client.rpc(
      'archive_group',
      params: {
        'p_group_id': groupId,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  /// Update group name
  Future<void> updateGroupName(int groupId, String name) async {
    await _client.from('groups').update({'name': name}).eq('id', groupId);
  }

  /// Get a single group by ID
  Future<Group?> getGroup(int groupId) async {
    final data = await _client
        .from('groups')
        .select('*, group_members(user_id, status, left_at)')
        .eq('id', groupId)
        .maybeSingle();

    if (data == null) return null;

    final memberCount = _acceptedMemberCount(
      data['group_members'],
      data['owner_id'] as String,
    );

    return Group(
      id: data['id'] as int,
      name: data['name'] as String,
      ownerId: data['owner_id'] as String,
      createdAt: DateTime.parse(data['created_at'] as String),
      archivedAt: data['archived_at'] == null
          ? null
          : DateTime.parse(data['archived_at'] as String),
      isOwner: data['owner_id'] == _currentUserId,
      canManageGames: data['owner_id'] == _currentUserId,
      memberCount: memberCount + 1, // +1 for owner
    );
  }

  /// Get group members with profile info
  Future<List<GroupMember>> getGroupMembers(int groupId) async {
    // Get group owner info and members in parallel
    final groupFuture = _client
        .from('groups')
        .select('owner_id')
        .eq('id', groupId)
        .single();
    final membersFuture = _client
        .from('group_members')
        .select('*')
        .eq('group_id', groupId)
        .eq('status', 'accepted')
        .isFilter('left_at', null);

    final group = await groupFuture;
    final membersData = await membersFuture;
    final ownerId = group['owner_id'] as String;

    // Collect all user IDs to fetch profiles in batch
    final allUserIds = <String>{ownerId};
    for (final m in membersData) {
      allUserIds.add(m['user_id'] as String);
    }

    // Batch fetch all profiles in one query
    final profiles = await _client
        .from('profiles')
        .select('id, display_name, handle')
        .inFilter('id', allUserIds.toList());

    final profileById = <String, Map<String, dynamic>>{
      for (final p in profiles) p['id'] as String: p,
    };

    final List<GroupMember> members = [];

    // Add owner as first member
    final ownerProfile = profileById[ownerId];
    members.add(
      GroupMember(
        id: 0,
        groupId: groupId,
        oderId: ownerId,
        joinedAt: DateTime.now(),
        displayName: ownerProfile?['display_name'] as String?,
        handle: ownerProfile?['handle'] as String?,
        isOwner: true,
        canManageGames: true,
      ),
    );

    // Add other members
    for (final m in membersData) {
      final oderId = m['user_id'] as String;
      final profile = profileById[oderId];
      members.add(
        GroupMember(
          id: m['id'] as int,
          groupId: m['group_id'] as int,
          oderId: oderId,
          joinedAt: DateTime.parse(m['joined_at'] as String),
          displayName: profile?['display_name'] as String?,
          handle: profile?['handle'] as String?,
          isOwner: false,
          canManageGames: m['can_manage_games'] as bool? ?? false,
        ),
      );
    }

    return members;
  }

  /// Invite a user to a group by user ID (owner only)
  Future<bool> inviteMemberByUserId(int groupId, String userId) async {
    await _client.rpc(
      'invite_profile_to_group',
      params: {
        'p_group_id': groupId,
        'p_profile_id': userId,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
    return true;
  }

  Future<List<GroupInvitation>> getPendingInvitations() async {
    final rows = await _client
        .from('group_invitations')
        .select('id, group_id, expires_at, groups(name)')
        .eq('profile_id', _currentUserId)
        .eq('status', 'pending')
        .gt('expires_at', DateTime.now().toIso8601String())
        .order('created_at', ascending: false);
    return rows
        .map((row) => GroupInvitation.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<void> respondToInvitation(
    String invitationId, {
    required bool accept,
  }) async {
    await _client.rpc(
      'respond_to_group_invitation',
      params: {
        'p_invitation_id': invitationId,
        'p_accept': accept,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  /// Remove a member from a group (owner only)
  Future<void> removeMember(int groupId, String oderId) async {
    await _client.rpc(
      'remove_group_member',
      params: {
        'p_group_id': groupId,
        'p_profile_id': oderId,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<void> setMemberGameManager(
    int groupId,
    String profileId, {
    required bool enabled,
  }) async {
    await _client.rpc(
      'set_group_member_game_manager',
      params: {
        'p_group_id': groupId,
        'p_profile_id': profileId,
        'p_enabled': enabled,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  /// Leave a group (for non-owners)
  Future<void> leaveGroup(int groupId) async {
    await _client.rpc(
      'leave_group',
      params: {
        'p_group_id': groupId,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<void> transferOwnership(int groupId, String newOwnerId) async {
    await _client.rpc(
      'transfer_group_ownership',
      params: {
        'p_group_id': groupId,
        'p_new_owner_id': newOwnerId,
        'p_idempotency_key': IdempotencyKey.generate(),
      },
    );
  }

  Future<List<Session>> getGroupSessions(int groupId) async {
    final rows = await _client.rpc(
      'group_games',
      params: {'p_group_id': groupId},
    );
    return (rows as List)
        .map((row) => Session.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<List<Map<String, dynamic>>> getGroupStats(int groupId) async {
    final rows = await _client.rpc(
      'group_stats',
      params: {'p_group_id': groupId},
    );
    return (rows as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }
}

int _acceptedMemberCount(Object? rows, String ownerId) {
  return (rows as List? ?? const [])
      .where(
        (row) =>
            row['user_id'] != ownerId &&
            row['status'] == 'accepted' &&
            row['left_at'] == null,
      )
      .length;
}
