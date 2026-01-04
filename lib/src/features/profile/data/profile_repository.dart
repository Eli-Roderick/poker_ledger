import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/profile_models.dart';

class ProfileRepository {
  final SupabaseClient _client = Supabase.instance.client;

  String get _currentUserId => _client.auth.currentUser!.id;

  /// Get user profile info by user ID
  Future<Map<String, dynamic>?> getUserProfile(String oderId) async {
    final data = await _client
        .from('profiles')
        .select('id, display_name, email')
        .eq('id', oderId)
        .maybeSingle();
    return data;
  }

  /// Get stats for a user from sessions accessible to the current user
  /// This includes:
  /// 1. Sessions owned by current user where target user participated
  /// 2. Sessions shared to groups current user is in where target user participated
  /// 3. If following is accepted, all sessions where target user participated
  Future<UserProfileStats> getUserStats(String targetUserId, {int? groupId, bool includeFollowedStats = false}) async {
    // First check if we're following this user (accepted)
    bool isFollowing = false;
    if (includeFollowedStats) {
      final follow = await _client
          .from('follows')
          .select('status')
          .eq('follower_id', _currentUserId)
          .eq('following_id', targetUserId)
          .eq('status', 'accepted')
          .maybeSingle();
      isFollowing = follow != null;
    }

    // Get accessible session IDs for this user
    final accessibleSessionIds = await _getAccessibleSessionIds(targetUserId, groupId: groupId, isFollowing: isFollowing);
    
    if (accessibleSessionIds.isEmpty) {
      final profile = await getUserProfile(targetUserId);
      return UserProfileStats(
        userId: targetUserId,
        displayName: profile?['display_name'] as String?,
        email: profile?['email'] as String?,
        totalSessions: 0,
        totalBuyInsCents: 0,
        totalCashOutsCents: 0,
        netProfitCents: 0,
        winRate: 0,
        biggestWinCents: 0,
        biggestLossCents: 0,
      );
    }

    // Get session_players data for the target user in accessible sessions
    final sessionPlayersData = await _client
        .from('session_players')
        .select('''
          session_id,
          buy_ins_cents,
          cash_outs_cents,
          players!inner(linked_user_id)
        ''')
        .inFilter('session_id', accessibleSessionIds)
        .eq('players.linked_user_id', targetUserId);

    int totalSessions = 0;
    int totalBuyIns = 0;
    int totalCashOuts = 0;
    int wins = 0;
    int biggestWin = 0;
    int biggestLoss = 0;
    Set<int> sessionIds = {};

    for (final sp in sessionPlayersData) {
      final sessionId = sp['session_id'] as int;
      if (sessionIds.contains(sessionId)) continue;
      sessionIds.add(sessionId);
      
      final buyIns = sp['buy_ins_cents'] as int? ?? 0;
      final cashOuts = sp['cash_outs_cents'] as int? ?? 0;
      final net = cashOuts - buyIns;
      
      totalSessions++;
      totalBuyIns += buyIns;
      totalCashOuts += cashOuts;
      
      if (net > 0) {
        wins++;
        if (net > biggestWin) biggestWin = net;
      } else if (net < 0) {
        if (net < biggestLoss) biggestLoss = net;
      }
    }

    final profile = await getUserProfile(targetUserId);
    
    return UserProfileStats(
      userId: targetUserId,
      displayName: profile?['display_name'] as String?,
      email: profile?['email'] as String?,
      totalSessions: totalSessions,
      totalBuyInsCents: totalBuyIns,
      totalCashOutsCents: totalCashOuts,
      netProfitCents: totalCashOuts - totalBuyIns,
      winRate: totalSessions > 0 ? (wins / totalSessions) * 100 : 0,
      biggestWinCents: biggestWin,
      biggestLossCents: biggestLoss,
    );
  }

  /// Get session IDs accessible to current user where target user participated
  Future<List<int>> _getAccessibleSessionIds(String targetUserId, {int? groupId, bool isFollowing = false}) async {
    Set<int> sessionIds = {};

    // 1. Sessions owned by current user where target participated
    final ownedSessions = await _client
        .from('sessions')
        .select('id')
        .eq('user_id', _currentUserId);
    
    for (final s in ownedSessions) {
      sessionIds.add(s['id'] as int);
    }

    // 2. Sessions shared to groups current user is in
    // Get groups current user is in
    final userGroups = await _client
        .from('groups')
        .select('id')
        .eq('owner_id', _currentUserId);
    
    final memberGroups = await _client
        .from('group_members')
        .select('group_id')
        .eq('user_id', _currentUserId);
    
    final groupIds = <int>{
      ...userGroups.map((g) => g['id'] as int),
      ...memberGroups.map((g) => g['group_id'] as int),
    };

    if (groupId != null) {
      // Filter to specific group
      groupIds.retainWhere((id) => id == groupId);
    }

    if (groupIds.isNotEmpty) {
      final sharedSessions = await _client
          .from('session_groups')
          .select('session_id')
          .inFilter('group_id', groupIds.toList());
      
      for (final sg in sharedSessions) {
        sessionIds.add(sg['session_id'] as int);
      }
    }

    // 3. If following, include all sessions where target user owns or participated
    if (isFollowing) {
      // Sessions owned by target user
      final targetOwnedSessions = await _client
          .from('sessions')
          .select('id')
          .eq('user_id', targetUserId);
      
      for (final s in targetOwnedSessions) {
        sessionIds.add(s['id'] as int);
      }

      // Sessions where target user participated (via linked player)
      final targetParticipatedSessions = await _client
          .from('session_players')
          .select('session_id, players!inner(linked_user_id)')
          .eq('players.linked_user_id', targetUserId);
      
      for (final sp in targetParticipatedSessions) {
        sessionIds.add(sp['session_id'] as int);
      }
    }

    // Now filter to only sessions where target user actually participated
    if (sessionIds.isEmpty) return [];

    final participatedSessions = await _client
        .from('session_players')
        .select('session_id, players!inner(linked_user_id)')
        .inFilter('session_id', sessionIds.toList())
        .eq('players.linked_user_id', targetUserId);

    return participatedSessions.map((sp) => sp['session_id'] as int).toSet().toList();
  }

  /// Get list of sessions for a user that are accessible to current user
  Future<List<UserSessionSummary>> getUserSessions(String targetUserId, {int? groupId}) async {
    // Check if following
    final follow = await _client
        .from('follows')
        .select('status')
        .eq('follower_id', _currentUserId)
        .eq('following_id', targetUserId)
        .eq('status', 'accepted')
        .maybeSingle();
    final isFollowing = follow != null;

    final accessibleSessionIds = await _getAccessibleSessionIds(targetUserId, groupId: groupId, isFollowing: isFollowing);
    
    if (accessibleSessionIds.isEmpty) return [];

    // Get session details with player stats
    final sessions = await _client
        .from('sessions')
        .select('id, name, started_at, finalized, user_id')
        .inFilter('id', accessibleSessionIds)
        .order('started_at', ascending: false);

    // Get owner names
    final ownerIds = sessions.map((s) => s['user_id'] as String).toSet().toList();
    final owners = await _client
        .from('profiles')
        .select('id, display_name')
        .inFilter('id', ownerIds);
    final ownerMap = {for (final o in owners) o['id'] as String: o['display_name'] as String? ?? 'Unknown'};

    // Get session_players data for target user
    final sessionPlayersData = await _client
        .from('session_players')
        .select('session_id, buy_ins_cents, cash_outs_cents, players!inner(linked_user_id)')
        .inFilter('session_id', accessibleSessionIds)
        .eq('players.linked_user_id', targetUserId);

    final spMap = <int, Map<String, dynamic>>{};
    for (final sp in sessionPlayersData) {
      spMap[sp['session_id'] as int] = sp;
    }

    // Get group info for sessions
    final sessionGroups = await _client
        .from('session_groups')
        .select('session_id, group_id, groups(name)')
        .inFilter('session_id', accessibleSessionIds);
    
    final groupMap = <int, Map<String, dynamic>>{};
    for (final sg in sessionGroups) {
      groupMap[sg['session_id'] as int] = sg;
    }

    return sessions.map((s) {
      final sessionId = s['id'] as int;
      final sp = spMap[sessionId];
      final buyIns = sp?['buy_ins_cents'] as int? ?? 0;
      final cashOuts = sp?['cash_outs_cents'] as int? ?? 0;
      final sg = groupMap[sessionId];
      
      return UserSessionSummary(
        sessionId: sessionId,
        sessionName: s['name'] as String?,
        startedAt: DateTime.parse(s['started_at'] as String),
        finalized: s['finalized'] as bool,
        buyInsCents: buyIns,
        cashOutsCents: cashOuts,
        netCents: cashOuts - buyIns,
        ownerName: ownerMap[s['user_id'] as String] ?? 'Unknown',
        isOwner: s['user_id'] == _currentUserId,
        groupId: sg?['group_id'] as int?,
        groupName: (sg?['groups'] as Map?)?['name'] as String?,
      );
    }).toList();
  }

  // ============ FOLLOW MANAGEMENT ============

  /// Send a follow request to a user
  Future<Follow> sendFollowRequest(String targetUserId) async {
    final data = await _client.from('follows').insert({
      'follower_id': _currentUserId,
      'following_id': targetUserId,
      'status': 'pending',
    }).select().single();
    return Follow.fromMap(data);
  }

  /// Accept a follow request
  Future<void> acceptFollowRequest(int followId) async {
    await _client.from('follows').update({
      'status': 'accepted',
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', followId).eq('following_id', _currentUserId);
  }

  /// Reject a follow request
  Future<void> rejectFollowRequest(int followId) async {
    await _client.from('follows').update({
      'status': 'rejected',
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', followId).eq('following_id', _currentUserId);
  }

  /// Cancel a follow request or unfollow
  Future<void> cancelFollow(String targetUserId) async {
    await _client.from('follows')
        .delete()
        .eq('follower_id', _currentUserId)
        .eq('following_id', targetUserId);
  }

  /// Get follow status between current user and target user
  Future<Follow?> getFollowStatus(String targetUserId) async {
    final data = await _client
        .from('follows')
        .select()
        .eq('follower_id', _currentUserId)
        .eq('following_id', targetUserId)
        .maybeSingle();
    return data != null ? Follow.fromMap(data) : null;
  }

  /// Get pending follow requests received by current user
  Future<List<Follow>> getPendingFollowRequests() async {
    final data = await _client
        .from('follows')
        .select()
        .eq('following_id', _currentUserId)
        .eq('status', 'pending')
        .order('created_at', ascending: false);

    // Get follower names
    final followerIds = data.map((f) => f['follower_id'] as String).toSet().toList();
    final profiles = await _client
        .from('profiles')
        .select('id, display_name')
        .inFilter('id', followerIds);
    final nameMap = {for (final p in profiles) p['id'] as String: p['display_name'] as String?};

    return data.map((f) {
      f['follower_name'] = nameMap[f['follower_id']];
      return Follow.fromMap(f);
    }).toList();
  }

  /// Get users current user is following
  Future<List<Follow>> getFollowing() async {
    final data = await _client
        .from('follows')
        .select()
        .eq('follower_id', _currentUserId)
        .eq('status', 'accepted')
        .order('created_at', ascending: false);

    // Get following names
    final followingIds = data.map((f) => f['following_id'] as String).toSet().toList();
    final profiles = await _client
        .from('profiles')
        .select('id, display_name')
        .inFilter('id', followingIds);
    final nameMap = {for (final p in profiles) p['id'] as String: p['display_name'] as String?};

    return data.map((f) {
      f['following_name'] = nameMap[f['following_id']];
      return Follow.fromMap(f);
    }).toList();
  }

  /// Get users following current user
  Future<List<Follow>> getFollowers() async {
    final data = await _client
        .from('follows')
        .select()
        .eq('following_id', _currentUserId)
        .eq('status', 'accepted')
        .order('created_at', ascending: false);

    // Get follower names
    final followerIds = data.map((f) => f['follower_id'] as String).toSet().toList();
    final profiles = await _client
        .from('profiles')
        .select('id, display_name')
        .inFilter('id', followerIds);
    final nameMap = {for (final p in profiles) p['id'] as String: p['display_name'] as String?};

    return data.map((f) {
      f['follower_name'] = nameMap[f['follower_id']];
      return Follow.fromMap(f);
    }).toList();
  }

  // ============ NICKNAME MANAGEMENT ============

  /// Get nickname for a player
  Future<String?> getNickname(int playerId) async {
    final data = await _client
        .from('player_nicknames')
        .select('nickname')
        .eq('user_id', _currentUserId)
        .eq('player_id', playerId)
        .maybeSingle();
    return data?['nickname'] as String?;
  }

  /// Set or update nickname for a player
  Future<void> setNickname(int playerId, String nickname) async {
    await _client.from('player_nicknames').upsert({
      'user_id': _currentUserId,
      'player_id': playerId,
      'nickname': nickname,
      'updated_at': DateTime.now().toIso8601String(),
    }, onConflict: 'user_id,player_id');
  }

  /// Remove nickname for a player
  Future<void> removeNickname(int playerId) async {
    await _client
        .from('player_nicknames')
        .delete()
        .eq('user_id', _currentUserId)
        .eq('player_id', playerId);
  }

  /// Get all nicknames for current user
  Future<Map<int, String>> getAllNicknames() async {
    final data = await _client
        .from('player_nicknames')
        .select('player_id, nickname')
        .eq('user_id', _currentUserId);
    return {for (final n in data) n['player_id'] as int: n['nickname'] as String};
  }

  /// Get groups that current user has access to (for filtering)
  Future<List<Map<String, dynamic>>> getAccessibleGroups() async {
    final ownedGroups = await _client
        .from('groups')
        .select('id, name')
        .eq('owner_id', _currentUserId);
    
    final memberGroupIds = await _client
        .from('group_members')
        .select('group_id')
        .eq('user_id', _currentUserId);
    
    final memberIds = memberGroupIds.map((g) => g['group_id'] as int).toList();
    
    List<Map<String, dynamic>> memberGroups = [];
    if (memberIds.isNotEmpty) {
      memberGroups = await _client
          .from('groups')
          .select('id, name')
          .inFilter('id', memberIds);
    }

    return [...ownedGroups, ...memberGroups];
  }
}
