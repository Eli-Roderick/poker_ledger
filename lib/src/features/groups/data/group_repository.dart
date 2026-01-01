import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/group_models.dart';

class GroupRepository {
  final SupabaseClient _client = Supabase.instance.client;

  String get _currentUserId => _client.auth.currentUser!.id;

  /// Get all groups the current user owns or is a member of
  Future<List<Group>> getMyGroups() async {
    // Get groups user owns
    final ownedGroups = await _client
        .from('groups')
        .select('*, group_members(count)')
        .eq('owner_id', _currentUserId);

    // Get groups user is a member of (but doesn't own)
    final memberGroups = await _client
        .from('group_members')
        .select('group_id, groups(*, group_members(count))')
        .eq('user_id', _currentUserId);

    final List<Group> groups = [];

    // Add owned groups
    for (final g in ownedGroups) {
      final memberCount = (g['group_members'] as List?)?.isNotEmpty == true
          ? (g['group_members'][0]['count'] as int? ?? 0)
          : 0;
      groups.add(Group(
        id: g['id'] as int,
        name: g['name'] as String,
        ownerId: g['owner_id'] as String,
        createdAt: DateTime.parse(g['created_at'] as String),
        isOwner: true,
        memberCount: memberCount + 1, // +1 for owner
      ));
    }

    // Add member groups (excluding ones we own)
    for (final m in memberGroups) {
      final g = m['groups'] as Map<String, dynamic>?;
      if (g == null) continue;
      if (g['owner_id'] == _currentUserId) continue; // Already added as owned

      final memberCount = (g['group_members'] as List?)?.isNotEmpty == true
          ? (g['group_members'][0]['count'] as int? ?? 0)
          : 0;
      groups.add(Group(
        id: g['id'] as int,
        name: g['name'] as String,
        ownerId: g['owner_id'] as String,
        createdAt: DateTime.parse(g['created_at'] as String),
        isOwner: false,
        memberCount: memberCount + 1, // +1 for owner
      ));
    }

    // Sort by name
    groups.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return groups;
  }

  /// Create a new group
  Future<Group> createGroup(String name) async {
    final data = await _client.from('groups').insert({
      'name': name,
      'owner_id': _currentUserId,
    }).select().single();

    return Group(
      id: data['id'] as int,
      name: data['name'] as String,
      ownerId: data['owner_id'] as String,
      createdAt: DateTime.parse(data['created_at'] as String),
      isOwner: true,
      memberCount: 1,
    );
  }

  /// Delete a group (owner only)
  Future<void> deleteGroup(int groupId) async {
    await _client.from('groups').delete().eq('id', groupId);
  }

  /// Update group name
  Future<void> updateGroupName(int groupId, String name) async {
    await _client.from('groups').update({'name': name}).eq('id', groupId);
  }

  /// Get group members with profile info
  Future<List<GroupMember>> getGroupMembers(int groupId) async {
    // Get group owner info and members in parallel
    final groupFuture = _client.from('groups').select('owner_id').eq('id', groupId).single();
    final membersFuture = _client.from('group_members').select('*').eq('group_id', groupId);
    
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
        .select('id, display_name, email')
        .inFilter('id', allUserIds.toList());
    
    final profileById = <String, Map<String, dynamic>>{
      for (final p in profiles) p['id'] as String: p
    };

    final List<GroupMember> members = [];

    // Add owner as first member
    final ownerProfile = profileById[ownerId];
    members.add(GroupMember(
      id: 0,
      groupId: groupId,
      oderId: ownerId,
      joinedAt: DateTime.now(),
      displayName: ownerProfile?['display_name'] as String?,
      email: ownerProfile?['email'] as String?,
      isOwner: true,
    ));

    // Add other members
    for (final m in membersData) {
      final oderId = m['user_id'] as String;
      final profile = profileById[oderId];
      members.add(GroupMember(
        id: m['id'] as int,
        groupId: m['group_id'] as int,
        oderId: oderId,
        joinedAt: DateTime.parse(m['joined_at'] as String),
        displayName: profile?['display_name'] as String?,
        email: profile?['email'] as String?,
        isOwner: false,
      ));
    }

    return members;
  }

  /// Invite a user to a group by email (owner only)
  Future<bool> inviteMemberByEmail(int groupId, String email) async {
    // Find user by email in profiles
    final profiles = await _client
        .from('profiles')
        .select('id')
        .eq('email', email.toLowerCase().trim())
        .limit(1);

    if (profiles.isEmpty) {
      return false; // User not found
    }

    final userId = profiles[0]['id'] as String;

    // Check if already a member
    final existing = await _client
        .from('group_members')
        .select('id')
        .eq('group_id', groupId)
        .eq('user_id', userId)
        .maybeSingle();

    if (existing != null) {
      return true; // Already a member
    }

    // Check if user is the owner
    final group = await _client
        .from('groups')
        .select('owner_id')
        .eq('id', groupId)
        .single();

    if (group['owner_id'] == userId) {
      return true; // User is the owner
    }

    // Add member
    await _client.from('group_members').insert({
      'group_id': groupId,
      'user_id': userId,
    });

    return true;
  }

  /// Remove a member from a group (owner only)
  Future<void> removeMember(int groupId, String oderId) async {
    await _client
        .from('group_members')
        .delete()
        .eq('group_id', groupId)
        .eq('user_id', oderId);
  }

  /// Leave a group (for non-owners)
  Future<void> leaveGroup(int groupId) async {
    await _client
        .from('group_members')
        .delete()
        .eq('group_id', groupId)
        .eq('user_id', _currentUserId);
  }

  /// Transfer ownership to another member
  Future<void> transferOwnership(int groupId, String newOwnerId) async {
    // First add current owner as a member
    await _client.from('group_members').insert({
      'group_id': groupId,
      'user_id': _currentUserId,
    });

    // Remove new owner from members (they'll be owner now)
    await _client
        .from('group_members')
        .delete()
        .eq('group_id', groupId)
        .eq('user_id', newOwnerId);

    // Update group owner
    await _client
        .from('groups')
        .update({'owner_id': newOwnerId})
        .eq('id', groupId);
  }

  /// Get groups a session is shared to
  Future<List<int>> getSessionGroupIds(int sessionId) async {
    final data = await _client
        .from('session_groups')
        .select('group_id')
        .eq('session_id', sessionId);

    return (data as List).map((e) => e['group_id'] as int).toList();
  }

  /// Update which groups a session is shared to
  Future<void> updateSessionGroups(int sessionId, List<int> groupIds) async {
    // Get current groups
    final currentGroupIds = await getSessionGroupIds(sessionId);

    // Groups to add
    final toAdd = groupIds.where((id) => !currentGroupIds.contains(id)).toList();

    // Groups to remove
    final toRemove = currentGroupIds.where((id) => !groupIds.contains(id)).toList();

    // Batch insert new groups
    if (toAdd.isNotEmpty) {
      await _client.from('session_groups').insert(
        toAdd.map((groupId) => {'session_id': sessionId, 'group_id': groupId}).toList(),
      );
    }

    // Batch delete removed groups
    if (toRemove.isNotEmpty) {
      await _client
          .from('session_groups')
          .delete()
          .eq('session_id', sessionId)
          .inFilter('group_id', toRemove);
    }
  }
}
